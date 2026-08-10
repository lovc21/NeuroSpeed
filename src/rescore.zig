// Gen-3 lever: re-label bulletformat positions with the embedded (gen2) NNUE
// via a shallow fixed-depth search. Replaces the score field of each 32-byte
// record; keeps occ/pcs/result/ksq/opp_ksq. Range-based (--start/--count) so a
// launcher can run one process per CPU core over disjoint record ranges.
//
// bulletformat 1.8.0 ChessBoard (32B, #[repr(C)]):
//   occ:u64@0  pcs:[u8;16]@8  score:i16@24  result:u8@26  ksq@27 opp_ksq@28 extra[3]@29
// The stored board is STM-RELATIVE; piece nibble = (opp<<3)|piecetype with
// piecetype 0..5 = P,N,B,R,Q,K -> nibble 0-5 = stm pieces, 8-13 = opp pieces,
// which is EXACTLY our Piece enum. Reconstruct as White-to-move: the search's
// stm-relative best_score then equals the stm-relative stored-score convention,
// so it is written back with no sign flip.
const std = @import("std");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const attacks = @import("attacks.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const globals = @import("globals.zig");

pub const Config = struct {
    in_path: []const u8 = "",
    out_path: []const u8 = "",
    depth: u8 = 6,
    start: u64 = 0,
    count: u64 = 0, // 0 = to end of file
    verbose: bool = false,
};

const REC = 32;

fn nibble_to_fen_char(nib: u8) u8 {
    const chars = "PNBRQK";
    const c = chars[nib & 7];
    return if (nib & 8 != 0) std.ascii.toLower(c) else c;
}

/// Build a White-to-move FEN from the packed mailbox (sq 0=a1..63=h8, 255=empty).
/// Inverse of bitboard.parse_fen's `sq = (7-fen_rank)*8 + file` mapping.
fn build_fen(sqpiece: *const [64]u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    var rank: i32 = 7;
    while (rank >= 0) : (rank -= 1) {
        var empties: u8 = 0;
        for (0..8) |file| {
            const sq: usize = @as(usize, @intCast(rank)) * 8 + file;
            const nib = sqpiece[sq];
            if (nib == 255) {
                empties += 1;
            } else {
                if (empties > 0) {
                    buf[pos] = '0' + empties;
                    pos += 1;
                    empties = 0;
                }
                buf[pos] = nibble_to_fen_char(nib);
                pos += 1;
            }
        }
        if (empties > 0) {
            buf[pos] = '0' + empties;
            pos += 1;
        }
        if (rank > 0) {
            buf[pos] = '/';
            pos += 1;
        }
    }
    const suffix = " w - - 0 1";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}

pub fn run(allocator: std.mem.Allocator, cfg: Config) !void {
    attacks.init_attacks();
    search.init_search();
    search.init_tt(allocator, 16);
    defer search.deinit_tt();
    try nnue.load_embedded();
    nnue.use_nnue = true;
    search.silent = true;

    var in = try std.Io.Dir.cwd().openFile(globals.io, cfg.in_path, .{});
    defer in.close(globals.io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_fr = in.reader(globals.io, &in_buf);
    const total = (try in_fr.getSize()) / REC;
    if (cfg.start >= total) return error.StartBeyondEnd;
    const count = if (cfg.count == 0) total - cfg.start else @min(cfg.count, total - cfg.start);
    try in_fr.seekTo(cfg.start * REC);
    const reader = &in_fr.interface;

    var out = try std.Io.Dir.cwd().createFile(globals.io, cfg.out_path, .{});
    defer out.close(globals.io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_fw = out.writer(globals.io, &out_buf);
    const writer = &out_fw.interface;

    var rec: [REC]u8 = undefined;
    var fenbuf: [96]u8 = undefined;
    var changed: u64 = 0;
    var kept: u64 = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        reader.readSliceAll(&rec) catch break;

        const occ = std.mem.readInt(u64, rec[0..8], .little);
        var sqpiece: [64]u8 = .{255} ** 64;
        var occ2 = occ;
        var idx: usize = 0;
        while (occ2 != 0) : (idx += 1) {
            const sq: u6 = @intCast(@ctz(occ2));
            occ2 &= occ2 - 1;
            const nib: u8 = (rec[8 + idx / 2] >> @as(u3, @intCast(4 * (idx & 1)))) & 0xF;
            sqpiece[sq] = nib;
        }

        const fen = build_fen(&sqpiece, fenbuf[0..]);
        const old_score = std.mem.readInt(i16, rec[24..26], .little);

        var board = types.Board.new();
        if (bitboard.parse_fen(fen, &board)) |_| {
            search.search_position(&board, cfg.depth, 0, 0, .White);
            const s = search.global_search.best_score; // stm(=white)-relative cp
            const s16: i16 = @intCast(std.math.clamp(s, -30000, 30000));
            std.mem.writeInt(i16, rec[24..26], s16, .little);
            changed += 1;
            if (cfg.verbose and i < 8) {
                std.debug.print("[{d}] {s} | old {d} -> new {d}\n", .{ cfg.start + i, fen, old_score, s16 });
            }
        } else |_| {
            // Unparseable reconstruction: keep the original label untouched.
            kept += 1;
        }

        try writer.writeAll(&rec);
    }
    try writer.flush();
    std.debug.print("rescore done: range [{d},{d}) rescored={d} kept_original={d} -> {s}\n", .{ cfg.start, cfg.start + i, changed, kept, cfg.out_path });
}

/// Sample every `stride`-th record from a bulletformat file and emit its
/// reconstructed White-to-move FEN (one per line) to out_path, up to `limit`
/// FENs. Used to build a decided-position opening book from gen23_decided.data
/// (records already filtered to |score| >= 300), so an SPRT started from these
/// measures a net's IN-BAND conversion strength. Reuses build_fen (tested).
pub fn dump_fens(in_path: []const u8, out_path: []const u8, stride: u64, limit: u64) !void {
    attacks.init_attacks();
    var in = try std.Io.Dir.cwd().openFile(globals.io, in_path, .{});
    defer in.close(globals.io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_fr = in.reader(globals.io, &in_buf);
    const total = (try in_fr.getSize()) / REC;
    const reader = &in_fr.interface;

    var out = try std.Io.Dir.cwd().createFile(globals.io, out_path, .{});
    defer out.close(globals.io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_fw = out.writer(globals.io, &out_buf);
    const writer = &out_fw.interface;

    var rec: [REC]u8 = undefined;
    var fenbuf: [96]u8 = undefined;
    var emitted: u64 = 0;
    var i: u64 = 0;
    // stride == 0 would never advance `i`: an infinite loop on a skipped
    // record, or `limit` copies of one FEN — reject it up front.
    if (stride == 0) return error.InvalidStride;
    while (i < total and emitted < limit) : (i += stride) {
        try in_fr.seekTo(i * REC);
        reader.readSliceAll(&rec) catch break;

        const occ = std.mem.readInt(u64, rec[0..8], .little);
        var sqpiece: [64]u8 = .{255} ** 64;
        var occ2 = occ;
        var idx: usize = 0;
        while (occ2 != 0) : (idx += 1) {
            const sq: u6 = @intCast(@ctz(occ2));
            occ2 &= occ2 - 1;
            const nib: u8 = (rec[8 + idx / 2] >> @as(u3, @intCast(4 * (idx & 1)))) & 0xF;
            sqpiece[sq] = nib;
        }

        // Sanity: exactly one king per side, else skip (corrupt/edge record).
        var wk: u8 = 0;
        var bk: u8 = 0;
        for (sqpiece) |nb| {
            if (nb == 5) wk += 1;
            if (nb == 13) bk += 1;
        }
        if (wk != 1 or bk != 1) continue;

        const fen = build_fen(&sqpiece, fenbuf[0..]);
        try writer.writeAll(fen);
        try writer.writeAll("\n");
        emitted += 1;
    }
    try writer.flush();
    std.debug.print("dump_fens: {d} FENs (stride {d}) -> {s}\n", .{ emitted, stride, out_path });
}

pub fn parse_args(args: []const [:0]const u8) !Config {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            cfg.verbose = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--in")) {
            cfg.in_path = v;
        } else if (std.mem.eql(u8, a, "--out")) {
            cfg.out_path = v;
        } else if (std.mem.eql(u8, a, "--depth")) {
            cfg.depth = try std.fmt.parseUnsigned(u8, v, 10);
        } else if (std.mem.eql(u8, a, "--start")) {
            cfg.start = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--count")) {
            cfg.count = try std.fmt.parseUnsigned(u64, v, 10);
        } else {
            std.debug.print("rescore: unknown arg '{s}'\n", .{a});
            return error.UnknownArg;
        }
    }
    if (cfg.in_path.len == 0 or cfg.out_path.len == 0) return error.MissingValue;
    return cfg;
}
