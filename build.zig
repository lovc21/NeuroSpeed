const std = @import("std");
const manifest = @import("build.zig.zon");

const nets = [_][]const u8{ "big_nnuev3", "small_nnuev3" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Engine version comes from build.zig.zon
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const memops_mod = b.createModule(.{
        .root_source_file = b.path("src/memops.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .no_builtin = true,
    });

    for ([_]*std.Build.Module{ engine_mod, test_mod }) |module| {
        module.addOptions("build_options", options);
        module.addImport("memops", memops_mod);
        for (nets) |name| {
            module.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("nets/{s}.bin", .{name})) });
        }
    }

    const exe = b.addExecutable(.{ .name = "NeuroSpeed", .root_module = engine_mod });
    // Keep relocations so llvm-bolt can re-lay-out hot code (`just build-bolt`).
    exe.link_emit_relocs = true;
    b.installArtifact(exe);

    // zig build check (run compiler diagnostics, nothing installed)
    const exe_check = b.addExecutable(.{ .name = "NeuroSpeed", .root_module = engine_mod });
    const test_check = b.addTest(.{ .root_module = test_mod });
    const check = b.step("check", "Compile engine and tests (editor diagnostics, nothing installed)");
    check.dependOn(&exe_check.step);
    check.dependOn(&test_check.step);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{
            .path = .{ .cwd_relative = b.graph.zig_lib_directory.join(b.allocator, &.{ "compiler", "test_runner.zig" }) catch @panic("OOM") },
            .mode = .simple,
        },
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    // zig build run [-- args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the engine").dependOn(&run_cmd.step);

    // zig build bench: UCI `bench` node-count fingerprint
    const bench_run = b.addRunArtifact(exe);
    bench_run.setStdIn(.{ .bytes = "bench\nquit\n" });
    b.step("bench", "Node-count fingerprint (UCI bench: 5 positions, depth 11)").dependOn(&bench_run.step);

    // zig build speedbench [-- depth] (movegen / eval / search speeds)
    const speed_depth: []const u8 = if (b.args) |args| (if (args.len > 0) args[0] else "6") else "6";
    const speed_run = b.addRunArtifact(exe);
    speed_run.setStdIn(.{ .bytes = b.fmt("speedbench {s}\nquit\n", .{speed_depth}) });
    b.step("speedbench", "Thesis component speeds: movegen / eval / search (optional: -- <depth>)").dependOn(&speed_run.step);

    // zig build datagen -- [options] (generate self-play training data)
    const datagen_args: []const u8 = if (b.args) |args| std.mem.join(b.allocator, " ", args) catch @panic("OOM") else "--help";
    const datagen_run = b.addRunArtifact(exe);
    datagen_run.setStdIn(.{ .bytes = b.fmt("datagen {s}\nquit\n", .{datagen_args}) });
    b.step("datagen", "Generate self-play training data: zig build datagen -- --games N --out FILE ...").dependOn(&datagen_run.step);
}
