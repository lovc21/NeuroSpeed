const types = @import("types.zig");
const nnue = @import("nnue.zig");
const evaluation = @import("evaluation.zig");

const Board = types.Board;
const Color = types.Color;
const Evaluator = evaluation.Evaluator;

pub var small_thresh: i32 = 475;
pub var hce_thresh: i32 = 895;
pub var phase_floor_pct: i32 = 100;

pub const options = [_]types.Option{
    .{ .name = "small_thresh", .ptr = &small_thresh, .min = -1, .max = 30000 },
    .{ .name = "hce_thresh", .ptr = &hce_thresh, .min = -1, .max = 30000 },
    .{ .name = "phase_floor_pct", .ptr = &phase_floor_pct, .min = 30, .max = 100 },
};

pub fn eval(ev: Evaluator, board: *const Board, comptime color: Color, alpha: i32, beta: i32) i32 {
    // if nnue is disabled, use the HCE evaluator
    if (!nnue.use_nnue) return ev.hce_eval(board, color, alpha, beta);

    const amat = @abs(ev.material[0]);
    var small_t = small_thresh;
    var hce_t = hce_thresh;
    if (phase_floor_pct < 100) {
        // thresholds shrink linearly toward phase_floor_pct as material comes off
        const ph: i32 = @min(@as(i32, ev.phase[0]) + @as(i32, ev.phase[1]), 32);
        const scale: i32 = phase_floor_pct + @divTrunc((100 - phase_floor_pct) * ph, 32);
        // -1 is the force-mode sentinel and must stay -1
        if (small_t >= 0) small_t = @divTrunc(small_t * scale, 100);
        if (hce_t >= 0) hce_t = @divTrunc(hce_t * scale, 100);
    }
    if (amat > hce_t) return ev.hce_eval(board, color, alpha, beta);
    nnue.want_small = amat > small_t;
    return nnue.evaluate_search(board);
}
