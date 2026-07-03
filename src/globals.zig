//! Process-wide Io instance + tiny shims for std APIs removed in Zig 0.16
//! (std.time.Timer, std.time.milliTimestamp). The engine is single-threaded,
//! so a single global Io keeps the migration diff minimal.
const std = @import("std");

/// Statically usable (tests, any pre-main path) via the stdlib's
/// statically-initialized single-threaded Threaded instance; main()
/// overwrites this with the process Init's Io (which has signal handlers
/// installed). Clock reads ignore userdata, so either is fine for timing.
pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Drop-in replacement for the removed std.time.Timer (monotonic).
pub const Timer = struct {
    start_ts: std.Io.Timestamp,

    pub fn start() Timer {
        return .{ .start_ts = .now(io, .awake) };
    }

    /// Elapsed nanoseconds, saturating at 0.
    pub fn read(t: *const Timer) u64 {
        const now_ts: std.Io.Timestamp = .now(io, .awake);
        const ns = t.start_ts.durationTo(now_ts).toNanoseconds();
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

/// Replacement for std.time.milliTimestamp() where only differences matter
/// (datagen progress). Monotonic, milliseconds.
pub fn nowMs() i64 {
    const ts: std.Io.Timestamp = .now(io, .awake);
    return ts.toMilliseconds();
}
