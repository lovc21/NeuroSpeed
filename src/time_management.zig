const types = @import("types.zig");
const util = @import("util.zig");
const search = @import("search.zig");

/// The `go` fields that affect the clock (ms).
pub const Go = struct {
    depth: ?u8 = null,
    movetime: ?u64 = null,
    wtime: ?u64 = null,
    btime: ?u64 = null,
    winc: ?u64 = null,
    binc: ?u64 = null,
    movestogo: ?u64 = null,
    infinite: bool = false,
};

/// Per-move budget (ms): `soft` = target checked between iterations, `hard` = abort limit polled in search; 0 = unlimited.
pub const Budget = struct {
    soft: u64 = 0,
    hard: u64 = 0,
};

/// Budget for the side to move from the `go` fields and the move overhead.
pub fn budget(go: Go, side: types.Color, overhead: u64) Budget {
    if (go.movetime) |mt| return .{ .soft = mt, .hard = mt };
    if (go.infinite or go.depth != null) return .{};
    const white = side == types.Color.White;
    const time = (if (white) go.wtime else go.btime) orelse return .{};
    const inc = (if (white) go.winc else go.binc) orelse 0;
    return time_management(time, inc, go.movestogo, overhead);
}

/// Budget from a live clock: remaining `time`, `inc` per move, optional `movestogo` (ms).
pub fn time_management(time: u64, inc: u64, movestogo: ?u64, overhead: u64) Budget {
    var soft: u64 = 0;
    var hard: u64 = 0;
    // movestogo 0 would divide by zero; treat it as 1.
    const mtg: u64 = if (movestogo) |m| @max(1, @min(m, 50)) else 50;

    // Count future increments as time on the clock.
    const adj_time = time + mtg * inc;

    if (movestogo != null) {
        // Fixed number of moves to the next control: share the time evenly, capped at 80%.
        soft = @min(7 * adj_time / (10 * mtg), 4 * time / 5);
    } else {
        // Sudden death: plan for ~30 more moves; near the flag the horizon shrinks with the clock.
        var horizon: u64 = 30;
        if (time < @as(u64, @intCast(@max(0, search.params.tm_collapse_ms)))) {
            const div: u64 = @intCast(@max(1, search.params.tm_collapse_div));
            horizon = @min(30, @max(2, time / div));
        }
        // Reserve the overhead for every planned move.
        const reserve: u64 = overhead * (2 + horizon);
        const banked: u64 = if (adj_time > reserve) adj_time - reserve else 1;
        soft = @min(banked / horizon, time / 5);
    }

    // Hard limit: tm_hard_pct% of the usable clock.
    const usable: u64 = if (time > overhead) time - overhead else 1;
    // Clamp the percentage to [1, 100]; SPSA can set it out of range.
    hard = util.pct(usable, @min(100, @max(1, search.params.tm_hard_pct)));

    // Always keep the overhead itself in reserve.
    if (time > overhead) {
        hard = @min(hard, time - overhead);
        soft = @min(soft, time - overhead);
    } else {
        hard = 1;
        soft = 1;
    }

    // Floor of 5 ms, but never more than a quarter of what is left.
    const floor: u64 = @min(5, @max(time / 4, 1));
    return .{ .soft = @max(soft, floor), .hard = @max(hard, floor) };
}
