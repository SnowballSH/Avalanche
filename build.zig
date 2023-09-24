const std = @import("std");

// Simple DateTime lib
// https://gist.github.com/WoodyAtHome/3ef50b17f0fa2860ac52b97af12f8d15
// Translated from German to English
pub const DateTime = struct { day: u8, month: u8, year: u16, hour: u8, minute: u8, second: u8 };

pub fn timestamp2DateTime(timestamp: i64) DateTime {
    const unixtime = @intCast(u64, timestamp);
    const SECONDS_PER_DAY = 86400;
    const DAYS_IN_COMMON_YEAR = 365;
    const DAYS_IN_4_YEARS = 1461;
    const DAYS_IN_100_YEARS = 36524;
    const DAYS_IN_400_YEARS = 146097;
    const DAYS_ON_1970_01_01 = 719468;

    var dayN: u64 = DAYS_ON_1970_01_01 + unixtime / SECONDS_PER_DAY;
    var seconds_since_midnight: u64 = unixtime % SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (dayN + DAYS_IN_100_YEARS + 1) / DAYS_IN_400_YEARS - 1;
    var year = @intCast(u16, 100 * temp);
    dayN -= DAYS_IN_100_YEARS * temp + temp / 4;

    temp = 4 * (dayN + DAYS_IN_COMMON_YEAR + 1) / DAYS_IN_4_YEARS - 1;
    year += @intCast(u16, temp);
    dayN -= DAYS_IN_COMMON_YEAR * temp + temp / 4;

    var month = @intCast(u8, (5 * dayN + 2) / 153);
    var day = @intCast(u8, dayN - (@intCast(u64, month) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    var hour = @intCast(u8, seconds_since_midnight / 3600);
    var minute = @intCast(u8, seconds_since_midnight % 3600 / 60);
    var second = @intCast(u8, seconds_since_midnight % 60);

    return DateTime{ .day = day, .month = month, .year = year, .hour = hour, .minute = minute, .second = second };
}
// End of Simple DateTime lib

fn dtToString(dt: DateTime, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Compiled at {:0>4}-{:0>2}-{:0>2}-{:0>2}:{:0>2}", .{ dt.year, dt.month, dt.day, dt.hour, dt.minute }) catch unreachable;
}

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const targetName = b.option([]const u8, "target-name", "Change the out name of the binary") orelse "Avalanche";

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable(targetName, "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    const build_options = b.addOptions();
    exe.addOptions("build_options", build_options);

    // var buf: [64]u8 = undefined;
    // build_options.addOption([]const u8, "version", dtToString(timestamp2DateTime(std.time.timestamp()), &buf));
    build_options.addOption([]const u8, "version", "2.0.0");

    exe.use_stage1 = true;

    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/tests.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
