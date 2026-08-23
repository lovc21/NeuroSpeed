const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// ns = (ticks * tsc_mult) >> tsc_shift — same fixed-point scheme the kernel
/// uses. 0 means "no calibrated invariant counter": Timer uses the OS clock.
const tsc_shift = 24;
var tsc_mult: u64 = 0;
/// Counter ticks per millisecond, set alongside tsc_mult; used to build
/// Deadlines without any per-check conversion.
var tsc_ticks_per_ms: u64 = 0;

/// Fixed-frequency, userspace-readable CPU counter. Only arches where such a
/// counter architecturally exists are wired up; the rest return 0 and stay on
/// the OS clock. riscv rdcycle is deliberately absent: it counts real cycles
/// (varies with frequency scaling), so it can't back a wall clock.
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
        // Generic-timer virtual counter: the one sanctioned for EL0 reads
        // (cntpct_el0 can trap on some kernels/hypervisors).
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
            // CPUID.80000007H:EDX[8] = invariant TSC (constant rate across
            // frequency scaling and C-states). Guard the leaf's existence.
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

/// One calibration window: counter ticks vs OS-clock ns across a sleep.
/// Returns the fixed-point multiplier, or null on any anomaly.
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
    // Plausible counter frequencies: 1 MHz (old ARM SoC timers run at
    // 24 MHz; leave margin) up to 100 GHz.
    const min_mult: u128 = (1 << tsc_shift) / 100; // 100 GHz
    const max_mult: u128 = 1000 << tsc_shift; // 1 MHz
    if (mult < min_mult or mult > max_mult) return null;
    return @intCast(mult);
}

/// Calibrate the CPU counter against the OS clock: measure, then verify the
/// result over an independent window; retry a few times before giving up and
/// leaving the (always correct) OS-clock fallback active. Idempotent.
/// Called from main(); costs ~25ms at startup on the happy path.
pub fn init() void {
    if (tsc_mult != 0) return;
    if (!hasInvariantCounter()) return;
    for (0..3) |_| {
        const mult = calibrateOnce(20) orelse continue;
        // Verify: over a 5ms window the counter-derived elapsed must agree
        // with the OS clock within 1%.
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

/// Absolute time limit with zero conversion on the hot path: on the counter
/// backend expired() is one counter read + compare (~7.5ns on x86_64), vs
/// ~11ns for Timer.read() and ~18ns for the OS-clock fallback.
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

/// Drop-in replacement for the removed std.time.Timer (monotonic).
pub const Timer = struct {
    start_tsc: u64,
    start_ts: std.Io.Timestamp,

    pub fn start() Timer {
        // Capture both clocks so read() stays correct even if init() runs
        // between start() and read().
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

/// Replacement for std.time.milliTimestamp() where only differences matter
/// (datagen progress). Monotonic, milliseconds. Deliberately stays on the
/// OS clock: it is cold (a few reads per minute) and datagen runs for hours
/// on a laptop, where raw counter behavior across suspend is undefined.
pub fn nowMs() i64 {
    const ts: std.Io.Timestamp = .now(io, .awake);
    return ts.toMilliseconds();
}
