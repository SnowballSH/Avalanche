const std = @import("std");
const platform = @import("../../platform.zig");
const search = @import("../search.zig");
const tt = @import("../tt.zig");
const syzygy = @import("../syzygy.zig");
const wdl = @import("../wdl.zig");
const parameters = @import("../parameters.zig");
const strength = @import("../strength.zig");
const weights = @import("../weights.zig");
const position = @import("../../chess/position.zig");
const numa = @import("../numa.zig");

/// Option values that shape each `go` rather than engine-global state.
pub const Settings = struct {
    multi_pv: usize = 1,
    ponder: bool = false,
    limit_strength: bool = false,
    elo: u32 = strength.DEFAULT_ELO,
    skill_level: u8 = strength.MAX_LEVEL,

    pub fn playing_strength(self: *const Settings) strength.Strength {
        return if (self.limit_strength)
            strength.Strength.from_elo(self.elo)
        else
            strength.Strength.from_skill_level(self.skill_level);
    }
};

const Spin = struct { default: i64, min: i64, max: i64 };

const Combo = struct { default: []const u8, values: []const []const u8 };

const Kind = union(enum) {
    check: bool,
    spin: Spin,
    combo: Combo,
    string: []const u8,
    button,
};

pub const Context = struct {
    settings: *Settings,
    position: *position.Position,
    out: *std.Io.Writer,
};

const Option = struct {
    name: []const u8,
    // Former or common alternative names still accepted by setoption.
    aliases: []const []const u8 = &.{},
    kind: Kind,
    apply: *const fn (ctx: Context, value: Value) anyerror!void,
    // Options the current build target cannot honour are neither advertised nor accepted.
    available: bool = true,

    fn matches(self: *const Option, name: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(self.name, name)) return true;
        for (self.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(alias, name)) return true;
        }
        return false;
    }
};

const Value = union(enum) {
    check: bool,
    spin: i64,
    string: []const u8,
    button,
};

const OPTIONS = [_]Option{
    .{ .name = "Hash", .kind = .{ .spin = .{ .default = 16, .min = 1, .max = tt.MAX_HASH_MB } }, .apply = set_hash },
    .{ .name = "Threads", .kind = .{ .spin = .{ .default = 1, .min = 1, .max = search.MAX_SEARCH_THREADS } }, .apply = set_threads },
    .{ .name = "Move Overhead", .aliases = &.{"MoveOverhead"}, .kind = .{ .spin = .{ .default = search.DEFAULT_MOVE_OVERHEAD, .min = 0, .max = search.MAX_MOVE_OVERHEAD } }, .apply = set_move_overhead },
    .{ .name = "NumaPolicy", .kind = .{ .combo = .{ .default = @tagName(numa.Policy.auto), .values = std.meta.fieldNames(numa.Policy) } }, .apply = set_numa_policy, .available = platform.has_threads },
    .{ .name = "MultiPV", .kind = .{ .spin = .{ .default = 1, .min = 1, .max = search.MAX_MULTI_PV } }, .apply = set_multi_pv },
    .{ .name = "Ponder", .kind = .{ .check = false }, .apply = set_ponder },
    .{ .name = "Clear Hash", .kind = .button, .apply = clear_hash },
    .{ .name = "UCI_Chess960", .kind = .{ .check = false }, .apply = set_chess960 },
    .{ .name = "UCI_LimitStrength", .kind = .{ .check = false }, .apply = set_limit_strength },
    .{ .name = "UCI_Elo", .kind = .{ .spin = .{ .default = strength.DEFAULT_ELO, .min = strength.MIN_ELO, .max = strength.MAX_ELO } }, .apply = set_elo },
    .{ .name = "Skill Level", .kind = .{ .spin = .{ .default = strength.MAX_LEVEL, .min = 0, .max = strength.MAX_LEVEL } }, .apply = set_skill_level },
    .{ .name = "SyzygyPath", .kind = .{ .string = "<empty>" }, .apply = set_syzygy_path, .available = syzygy.supported },
    .{ .name = "SyzygyProbeDepth", .kind = .{ .spin = .{ .default = 1, .min = 1, .max = 100 } }, .apply = set_syzygy_probe_depth, .available = syzygy.supported },
    .{ .name = "SyzygyProbeLimit", .kind = .{ .spin = .{ .default = 7, .min = 1, .max = 7 } }, .apply = set_syzygy_probe_limit, .available = syzygy.supported },
    .{ .name = "Syzygy50MoveRule", .kind = .{ .check = true }, .apply = set_syzygy_rule50, .available = syzygy.supported },
    .{ .name = "EvalFile", .kind = .{ .string = weights.EMBEDDED_NAME }, .apply = set_eval_file, .available = weights.supports_eval_file },
    .{ .name = "UCI_ShowWDL", .kind = .{ .check = false }, .apply = set_show_wdl },
    .{ .name = "Contempt", .kind = .{ .spin = .{ .default = 0, .min = -search.MAX_CONTEMPT, .max = search.MAX_CONTEMPT } }, .apply = set_contempt },
};

pub fn print_all(out: *std.Io.Writer) !void {
    for (OPTIONS) |option| {
        if (!option.available) continue;
        try out.print("option name {s} type ", .{option.name});
        switch (option.kind) {
            .check => |default| try out.print("check default {}", .{default}),
            .spin => |spin| try out.print("spin default {} min {} max {}", .{ spin.default, spin.min, spin.max }),
            .combo => |combo| {
                try out.print("combo default {s}", .{combo.default});
                for (combo.values) |value| try out.print(" var {s}", .{value});
            },
            .string => |default| try out.print("string default {s}", .{default}),
            .button => try out.writeAll("button"),
        }
        try out.writeAll(search.line_ending);
    }
    for (parameters.TunableParams) |tunable| {
        try out.print("option name {s} type spin default {d} min {d} max {d}" ++ search.line_ending, .{ tunable.name, tunable.value, tunable.min_value, tunable.max_value });
    }
}

pub const SetOptionError = error{ UnknownOption, InvalidValue };

/// Handles the text after `setoption `: `name <name...> [value <value...>]`.
pub fn set_option(args: []const u8, ctx: Context) !void {
    const request = parse_request(args) orelse return SetOptionError.UnknownOption;

    for (OPTIONS) |option| {
        if (!option.available or !option.matches(request.name)) continue;
        const value: Value = switch (option.kind) {
            .check => .{ .check = parse_bool(request.value) orelse return SetOptionError.InvalidValue },
            .spin => |spin| .{ .spin = std.math.clamp(
                std.fmt.parseInt(i64, request.value, 10) catch return SetOptionError.InvalidValue,
                spin.min,
                spin.max,
            ) },
            .combo => |combo| .{ .string = for (combo.values) |allowed| {
                if (std.ascii.eqlIgnoreCase(allowed, request.value)) break allowed;
            } else return SetOptionError.InvalidValue },
            .string => .{ .string = request.value },
            .button => .button,
        };
        return option.apply(ctx, value);
    }

    const raw = std.fmt.parseInt(i64, request.value, 10) catch return SetOptionError.UnknownOption;
    const tunable = parameters.set(request.name, raw) orelse return SetOptionError.UnknownOption;
    if (tunable.reinit_lmr) search.init_lmr();
}

const Request = struct { name: []const u8, value: []const u8 };

fn parse_request(args: []const u8) ?Request {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (!std.mem.startsWith(u8, trimmed, "name ")) return null;
    const rest = trimmed["name ".len..];
    if (std.mem.indexOf(u8, rest, " value ")) |split| {
        return .{
            .name = std.mem.trim(u8, rest[0..split], " \t"),
            .value = std.mem.trim(u8, rest[split + " value ".len ..], " \t"),
        };
    }
    return .{ .name = std.mem.trim(u8, rest, " \t"), .value = "" };
}

fn parse_bool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn set_hash(ctx: Context, value: Value) !void {
    const requested: usize = @intCast(value.spin);
    tt.GlobalTT.reset(requested);
    const installed_mb = tt.GlobalTT.size * @sizeOf(tt.Item) / tt.MB;
    if (installed_mb < requested) {
        try ctx.out.print("info string Hash: failed to allocate {} MB, still using {} MB" ++ search.line_ending, .{ requested, installed_mb });
    }
    try ctx.out.print("info string Hash: {} MB, {} MB on huge pages" ++ search.line_ending, .{ installed_mb, tt.GlobalTT.huge_page_bytes / tt.MB });
}

fn set_threads(ctx: Context, value: Value) !void {
    const total: usize = @intCast(value.spin);
    search.THREADS_CONFIGURED = true;
    search.set_helper_count(total - 1);
    if (search.helper_count() < total - 1) {
        try ctx.out.print("info string Threads: failed to allocate {} helpers, using {}" ++ search.line_ending, .{ total - 1, search.helper_count() + 1 });
    }
}

fn set_numa_policy(_: Context, value: Value) !void {
    const chosen = std.meta.stringToEnum(numa.Policy, value.string).?;
    if (chosen == numa.policy) return;
    numa.policy = chosen;
    numa.init();
    if (!numa.topology().is_numa()) return;
    // Helpers are placed when they start, so restart them under the new policy.
    const helpers = search.helper_count();
    search.set_helper_count(0);
    search.set_helper_count(helpers);
}

fn set_move_overhead(_: Context, value: Value) !void {
    search.MOVE_OVERHEAD = @intCast(value.spin);
}

fn set_multi_pv(ctx: Context, value: Value) !void {
    ctx.settings.multi_pv = @intCast(value.spin);
}

fn set_ponder(ctx: Context, value: Value) !void {
    ctx.settings.ponder = value.check;
}

fn clear_hash(_: Context, _: Value) !void {
    tt.GlobalTT.clear();
}

fn set_chess960(ctx: Context, value: Value) !void {
    ctx.position.uci_chess960 = value.check;
}

fn set_limit_strength(ctx: Context, value: Value) !void {
    ctx.settings.limit_strength = value.check;
}

fn set_elo(ctx: Context, value: Value) !void {
    ctx.settings.elo = @intCast(value.spin);
}

fn set_skill_level(ctx: Context, value: Value) !void {
    ctx.settings.skill_level = @intCast(value.spin);
}

fn set_syzygy_path(ctx: Context, value: Value) !void {
    const path = value.string;
    if (path.len == 0 or std.mem.eql(u8, path, "<empty>")) {
        syzygy.deinit();
        return;
    }
    const cpath = try platform.allocator.dupeZ(u8, path);
    defer platform.allocator.free(cpath);
    if (syzygy.init(cpath.ptr)) {
        try ctx.out.print("info string Syzygy: loaded tablebases up to {}-men from '{s}'" ++ search.line_ending, .{ syzygy.max_pieces(), path });
    } else {
        try ctx.out.print("info string Syzygy: failed to load tablebases from '{s}'" ++ search.line_ending, .{path});
    }
}

fn set_syzygy_probe_depth(_: Context, value: Value) !void {
    syzygy.probe_depth = @intCast(value.spin);
}

fn set_syzygy_probe_limit(_: Context, value: Value) !void {
    syzygy.probe_limit = @intCast(value.spin);
}

fn set_syzygy_rule50(_: Context, value: Value) !void {
    syzygy.use_rule50 = value.check;
}

fn set_eval_file(ctx: Context, value: Value) !void {
    const path = if (value.string.len == 0) weights.EMBEDDED_NAME else value.string;
    weights.load(path) catch |err| {
        try ctx.out.print("info string EvalFile: failed to load '{s}' ({s}), keeping the current network" ++ search.line_ending, .{ path, @errorName(err) });
        return;
    };
    ctx.position.refresh_evaluation();
    try ctx.out.print("info string EvalFile: using {s}" ++ search.line_ending, .{path});
}

fn set_show_wdl(_: Context, value: Value) !void {
    wdl.show_wdl = value.check;
}

fn set_contempt(_: Context, value: Value) !void {
    const contempt: i32 = @intCast(value.spin);
    if (contempt != search.CONTEMPT) {
        search.CONTEMPT = contempt;
        tt.GlobalTT.clear();
    }
}
