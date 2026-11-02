const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// ns = (ticks * tsc_mult) >> tsc_shift; 0 means Timer uses the OS clock.
const tsc_shift = 24;
var tsc_mult: u64 = 0;
/// Counter ticks per millisecond, for building Deadlines.
var tsc_ticks_per_ms: u64 = 0;

/// Fixed-frequency CPU counter readable from userspace, or 0 if the arch has none.
inline fn readCounter() u64 {
    switch (comptime builtin.target.cpu.arch) {
        .x86_64 => {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            return (@as(u64, hi) << 32) | lo;
        },
        // Virtual counter; cntpct_el0 can trap on some kernels.
        .aarch64, .aarch64_be => {
            return asm volatile ("mrs %[ret], cntvct_el0"
                : [ret] "=r" (-> u64),
            );
        },
        else => return 0,
    }
}

fn hasInvariantCounter() bool {
    switch (comptime builtin.target.cpu.arch) {
        .x86_64 => {
            // Invariant TSC is CPUID.80000007H:EDX[8], check that the leaf exists first.
            var max_leaf: u32 = undefined;
            asm volatile ("cpuid"
                : [eax] "={eax}" (max_leaf),
                : [leaf] "{eax}" (@as(u32, 0x8000_0000)),
                : .{ .ebx = true, .ecx = true, .edx = true });
            if (max_leaf < 0x8000_0007) return false;
            var edx: u32 = undefined;
            asm volatile ("cpuid"
                : [edx] "={edx}" (edx),
                : [leaf] "{eax}" (@as(u32, 0x8000_0007)),
                : .{ .eax = true, .ebx = true, .ecx = true });
            return (edx >> 8) & 1 == 1;
        },
        // The armv8 generic timer is fixed-frequency by architecture.
        .aarch64, .aarch64_be => return true,
        else => return false,
    }
}

fn osNowNs() i96 {
    const ts: std.Io.Timestamp = .now(io, .awake);
    return ts.toNanoseconds();
}

/// Measure counter ticks against the OS clock over a sleep; null if the result looks wrong.
fn calibrateOnce(window_ms: i64) ?u64 {
    const t0 = readCounter();
    const ns0 = osNowNs();
    io.sleep(.fromMilliseconds(window_ms), .awake) catch return null;
    const t1 = readCounter();
    const ns1 = osNowNs();
    if (t1 <= t0 or ns1 <= ns0) return null;
    const ticks: u128 = t1 - t0;
    const ns: u128 = @intCast(ns1 - ns0);
    const mult = (ns << tsc_shift) / ticks;
    // Accept counters from 1 MHz to 100 GHz.
    const min_mult: u128 = (1 << tsc_shift) / 100; // 100 GHz
    const max_mult: u128 = 1000 << tsc_shift; // 1 MHz
    if (mult < min_mult or mult > max_mult) return null;
    return @intCast(mult);
}

/// Calibrate the counter against the OS clock, keeping the OS clock if that fails.
pub fn init() void {
    if (tsc_mult != 0) return;
    if (!hasInvariantCounter()) return;
    for (0..3) |_| {
        const mult = calibrateOnce(20) orelse continue;
        // A second 5 ms window must agree with the OS clock within 1%.
        const t0 = readCounter();
        const ns0 = osNowNs();
        io.sleep(.fromMilliseconds(5), .awake) catch return;
        const ticks: u128 = readCounter() -% t0;
        const os_ns: i96 = osNowNs() - ns0;
        if (os_ns <= 0) continue;
        const counter_ns: i96 = @intCast((ticks * mult) >> tsc_shift);
        const diff = @abs(counter_ns - os_ns);
        if (diff * 100 > @as(u96, @intCast(os_ns))) continue;
        tsc_ticks_per_ms = @intCast((@as(u128, std.time.ns_per_ms) << tsc_shift) / mult);
        tsc_mult = mult;
        return;
    }
}

/// Absolute time limit; on the counter backend expired() is one read and a compare.
pub const Deadline = struct {
    ticks: u64, // absolute counter value (counter path)
    ns: i96, // absolute OS-clock value (fallback path)
    use_counter: bool,

    /// Never expires; expired() stays cheap (counter compare against maxInt).
    pub const never: Deadline = .{
        .ticks = std.math.maxInt(u64),
        .ns = std.math.maxInt(i96),
        .use_counter = true,
    };

    pub fn afterMs(ms: u64) Deadline {
        if (tsc_mult != 0) {
            return .{
                .ticks = readCounter() + ms * tsc_ticks_per_ms,
                .ns = 0,
                .use_counter = true,
            };
        }
        return .{
            .ticks = 0,
            .ns = osNowNs() + @as(i96, @intCast(ms)) * std.time.ns_per_ms,
            .use_counter = false,
        };
    }

    pub fn expired(d: *const Deadline) bool {
        if (d.use_counter) return readCounter() >= d.ticks;
        return osNowNs() >= d.ns;
    }
};

/// True when Timer is on the CPU-counter fast path (init() succeeded).
pub fn usingCycleCounter() bool {
    return tsc_mult != 0;
}

/// Monotonic timer.
pub const Timer = struct {
    start_tsc: u64,
    start_ts: std.Io.Timestamp,

    pub fn start() Timer {
        // Capture both clocks so read() works even if init() runs in between.
        return .{ .start_tsc = readCounter(), .start_ts = .now(io, .awake) };
    }

    /// Elapsed nanoseconds, saturating at 0.
    pub fn read(t: *const Timer) u64 {
        const mult = tsc_mult;
        if (mult != 0) {
            const ticks = readCounter() -% t.start_tsc;
            return @intCast((@as(u128, ticks) * mult) >> tsc_shift);
        }
        const now_ts: std.Io.Timestamp = .now(io, .awake);
        const ns = t.start_ts.durationTo(now_ts).toNanoseconds();
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

/// Monotonic milliseconds from the OS clock, for datagen progress.
pub fn nowMs() i64 {
    const ts: std.Io.Timestamp = .now(io, .awake);
    return ts.toMilliseconds();
}
