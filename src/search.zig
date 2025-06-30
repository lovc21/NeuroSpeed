const std = @import("std");
const types = @import("types.zig");
const print = std.debug.print;

pub fn search_position(uci_ref: anytype, depth: ?u8, time_ms: u64) void {
    _ = depth;
    _ = time_ms;

    uci_ref.is_searching = true;
    print("bestmove {s}\n", .{"e2e4"});

    uci_ref.is_searching = false;
}
