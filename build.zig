const std = @import("std");

// Simple DateTime lib
// https://gist.github.com/WoodyAtHome/3ef50b17f0fa2860ac52b97af12f8d15
// Translated from German to English
pub const DateTime = struct { day: u8, month: u8, year: u16, hour: u8, minute: u8, second: u8 };

pub fn timestamp2DateTime(timestamp: i64) DateTime {
    const unixtime = @as(u64, @intCast(timestamp));
    const SECONDS_PER_DAY = 86400;
    const DAYS_IN_COMMON_YEAR = 365;
    const DAYS_IN_4_YEARS = 1461;
    const DAYS_IN_100_YEARS = 36524;
    const DAYS_IN_400_YEARS = 146097;
    const DAYS_ON_1970_01_01 = 719468;

    var dayN: u64 = DAYS_ON_1970_01_01 + unixtime / SECONDS_PER_DAY;
    const seconds_since_midnight: u64 = unixtime % SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (dayN + DAYS_IN_100_YEARS + 1) / DAYS_IN_400_YEARS - 1;
    var year = @as(u16, @intCast(100 * temp));
    dayN -= DAYS_IN_100_YEARS * temp + temp / 4;

    temp = 4 * (dayN + DAYS_IN_COMMON_YEAR + 1) / DAYS_IN_4_YEARS - 1;
    year += @as(u16, @intCast(temp));
    dayN -= DAYS_IN_COMMON_YEAR * temp + temp / 4;

    var month = @as(u8, @intCast((5 * dayN + 2) / 153));
    const day = @as(u8, @intCast(dayN - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1));

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    const hour = @as(u8, @intCast(seconds_since_midnight / 3600));
    const minute = @as(u8, @intCast(seconds_since_midnight % 3600 / 60));
    const second = @as(u8, @intCast(seconds_since_midnight % 60));

    return DateTime{ .day = day, .month = month, .year = year, .hour = hour, .minute = minute, .second = second };
}
// End of Simple DateTime lib

fn dtToString(dt: DateTime, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Compiled at {:0>4}-{:0>2}-{:0>2}-{:0>2}:{:0>2}", .{ dt.year, dt.month, dt.day, dt.hour, dt.minute }) catch unreachable;
}

fn addPyrrhic(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/pyrrhic/tbprobe.c"),
        .flags = &.{ "-O3", "-std=c11" },
    });
    compile.root_module.addIncludePath(b.path("src/pyrrhic"));
}

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const targetName = b.option([]const u8, "target-name", "Change the out name of the binary") orelse "Avalanche";
    // The embedded NNUE is selectable via -Dnet=<path> without editing this file.
    // It is imported under the name "nnue", which weights.zig @embedFile's.
    const netPath = b.option([]const u8, "net", "Path to the .nnue file to embed") orelse "nets/molihua.nnue";

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    var buf: [64]u8 = undefined;
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    const now_seconds = std.Io.Clock.real.now(io_threaded.io()).toSeconds();
    build_options.addOption([]const u8, "version", dtToString(timestamp2DateTime(now_seconds), &buf));

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
        .root_source_file = b.path(netPath),
    });

    addPyrrhic(b, exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Build tests optimized: Position is passed by value into inline helpers,
    // and a Debug build's un-elided copies overflow the test thread's stack.
    const test_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
        }),
    });

    exe_tests.root_module.addAnonymousImport("nnue", .{
        .root_source_file = b.path(netPath),
    });

    addPyrrhic(b, exe_tests);

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
