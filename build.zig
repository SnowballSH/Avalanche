const std = @import("std");

// Simple DateTime lib
// https://gist.github.com/WoodyAtHome/3ef50b17f0fa2860ac52b97af12f8d15
// Translated from German to English
pub const DateTime = struct { day: u8, month: u8, year: u16, hour: u8, minute: u8, second: u8 };

pub fn timestamp2DateTime(timestamp: i64) DateTime {
    const unixtime: u64 = @intCast(timestamp);
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
    var year: u16 = @intCast(100 * temp);
    dayN -= DAYS_IN_100_YEARS * temp + temp / 4;

    temp = 4 * (dayN + DAYS_IN_COMMON_YEAR + 1) / DAYS_IN_4_YEARS - 1;
    year += @intCast(temp);
    dayN -= DAYS_IN_COMMON_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * dayN + 2) / 153);
    const day: u8 = @intCast(dayN - (@as(u64, month) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    const hour: u8 = @intCast(seconds_since_midnight / 3600);
    const minute: u8 = @intCast(seconds_since_midnight % 3600 / 60);
    const second: u8 = @intCast(seconds_since_midnight % 60);

    return DateTime{ .day = day, .month = month, .year = year, .hour = hour, .minute = minute, .second = second };
}
// End of Simple DateTime lib

fn dtToString(dt: DateTime, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Compiled at {:0>4}-{:0>2}-{:0>2}-{:0>2}:{:0>2}", .{ dt.year, dt.month, dt.day, dt.hour, dt.minute }) catch unreachable;
}

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const targetName = b.option([]const u8, "target-name", "Change the out name of the binary") orelse "Avalanche";

    const net_module = b.createModule(
        .{
            .root_source_file = b.path("nets/bingshan.nnue"),
        },
    );
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimise = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = targetName,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimise,
    });

    exe.root_module.addImport("net", net_module);

    const build_options = b.addOptions();
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    var buf: [64]u8 = undefined;
    build_options.addOption([]const u8, "version", dtToString(timestamp2DateTime(std.time.timestamp()), &buf));
    // build_options.addOption([]const u8, "version", "2.2.0");

    exe.linkLibC();

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimise,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
