const std = @import("std");
const Build = std.Build;

// Simple DateTime lib
// https://gist.github.com/WoodyAtHome/3ef50b17f0fa2860ac52b97af12f8d15
// Translated from German to English
pub const DateTime = struct {
    day: u8,
    month: u8,
    year: u16,
    hour: u8,
    minute: u8,
    second: u8,
};

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

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});
    const install_step = b.getInstallStep();

    const exe = b.addExecutable(.{
        .name = b.option(
            []const u8,
            "target-name",
            "Change the out name of the binary",
        ) orelse "Avalanche",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });

    const build_options = b.addOptions();

    var buf: [64]u8 = undefined;
    build_options.addOption(
        []const u8,
        "version",
        dtToString(
            timestamp2DateTime(std.time.timestamp()),
            &buf,
        ),
    );

    exe.root_module.addImport(
        "build_options",
        build_options.createModule(),
    );

    exe.linkLibC();
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(install_step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    b.step("run", "Run the app").dependOn(&run_exe.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = mode,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
