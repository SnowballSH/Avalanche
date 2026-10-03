const std = @import("std");

const Translator = @import("translate_c").Translator;

fn buildTimestamp(b: *std.Build) []const u8 {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    const now: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.Io.Clock.real.now(io_threaded.io()).toSeconds()) };
    const year_day = now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = now.getDaySeconds();
    return b.fmt("Compiled at {:0>4}-{:0>2}-{:0>2}-{:0>2}:{:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
}

const Pyrrhic = struct {
    bindings: *std.Build.Module,
    include_path: std.Build.LazyPath,
    source: std.Build.LazyPath,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) Pyrrhic {
        const translator: Translator = .init(b.dependency("translate_c", .{}), .{
            .c_source_file = b.path("src/pyrrhic/tbprobe.h"),
            .target = target,
            .optimize = optimize,
        });
        return .{
            .bindings = translator.mod,
            .include_path = b.path("src/pyrrhic"),
            .source = b.path("src/pyrrhic/tbprobe.c"),
        };
    }

    fn addTo(pyrrhic: Pyrrhic, module: *std.Build.Module) void {
        module.addImport("pyrrhic", pyrrhic.bindings);
        module.addIncludePath(pyrrhic.include_path);
        module.addCSourceFile(.{ .file = pyrrhic.source, .flags = &.{ "-O3", "-std=gnu11" } });
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const targetName = b.option([]const u8, "target-name", "Change the out name of the binary") orelse "Avalanche";
    // The embedded NNUE is selectable via -Dnet=<path> without editing this file.
    // It is imported under the name "nnue", which weights.zig @embedFile's.
    const netPath = b.option([]const u8, "net", "Path to the .nnue file to embed") orelse "nets/dianguang-3.nnue";
    const net: std.Build.LazyPath = if (std.fs.path.isAbsolute(netPath))
        .{ .cwd_relative = netPath }
    else
        b.path(netPath);
    const inputBuckets = b.option(usize, "buckets", "King input buckets (1=Chess768, 16=buckets+HM)") orelse 16;
    if (inputBuckets != 1 and inputBuckets != 16) {
        @panic("-Dbuckets must be 1 (Chess768) or 16 (ChessBucketsMirrored)");
    }

    // The layers after the feature transformer; see docs/NNUE.md. `auto` reads
    // it off the embedded network's header.
    const HeadOption = enum { auto, single, multi };
    const head = b.option(HeadOption, "head", "NNUE head: auto (from the -Dnet file, default), single or multi") orelse .auto;

    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    // Dev builds identify themselves by build time; releases pass -Dversion=X.Y.Z.
    const version = b.option([]const u8, "version", "Release version reported by `uci` (default: build timestamp)") orelse version: {
        b.graph.poisonCache();
        break :version buildTimestamp(b);
    };
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(usize, "input_buckets", inputBuckets);
    build_options.addOption(HeadOption, "head", head);
    build_options.addOption([]const u8, "net_name", std.fs.path.stem(netPath));

    const exe = b.addExecutable(.{
        .name = targetName,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addAnonymousImport("nnue", .{
        .root_source_file = net,
    });

    const pyrrhic: Pyrrhic = .init(b, target, optimize);
    pyrrhic.addTo(exe.root_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filter = b.option([]const u8, "test-filter", "Run only the unit tests whose name contains this text");
    const exe_tests = b.addTest(.{
        .filters = if (test_filter) |filter| b.dupeStrings(&.{filter}) else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe_tests.root_module.addOptions("build_options", build_options);
    exe_tests.root_module.addAnonymousImport("nnue", .{
        .root_source_file = net,
    });

    pyrrhic.addTo(exe_tests.root_module);

    const wasm = b.addExecutable(.{
        .name = "avalanche",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic },
                .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
            }),
            .optimize = optimize,
            .single_threaded = true,
            .strip = optimize != .debug,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 16 * 1024 * 1024;
    wasm.root_module.addOptions("build_options", build_options);
    wasm.root_module.addAnonymousImport("nnue", .{
        .root_source_file = net,
    });

    const install_wasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    const wasm_step = b.step("wasm", "Build the WebAssembly engine into zig-out/web");
    wasm_step.dependOn(&install_wasm.step);

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // For running the unit tests on another machine, e.g. `-Dtarget=aarch64-linux-gnu`.
    const install_tests = b.addInstallArtifact(exe_tests, .{ .dest_sub_path = "avalanche-tests" });
    const test_exe_step = b.step("test-exe", "Install the unit-test binary as zig-out/bin/avalanche-tests");
    test_exe_step.dependOn(&install_tests.step);
}
