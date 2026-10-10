const std = @import("std");

pub const Tunable = struct {
    name: []const u8,
    value: i32,
    min_value: i32,
    max_value: i32,
    c_end: f64,
    r_end: f64 = 0.002,
    worth_tuning: bool,
    reinit_lmr: bool = false,
};

pub const TunableParams = [_]Tunable{
    .{ .name = "AspirationWindow", .value = 12, .min_value = 5, .max_value = 30, .c_end = 1.25, .worth_tuning = true },
    .{ .name = "AspirationDepth", .value = 6, .min_value = 4, .max_value = 9, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "AspirationDeltaPercent", .value = 29, .min_value = 10, .max_value = 60, .c_end = 2.5, .worth_tuning = true },

    .{ .name = "TmSoftFactor", .value = 37, .min_value = 18, .max_value = 70, .c_end = 2.5, .worth_tuning = true },
    .{ .name = "TmHardFactor", .value = 64, .min_value = 32, .max_value = 140, .c_end = 5, .worth_tuning = true },
    .{ .name = "TmStabilityBase", .value = 110, .min_value = 95, .max_value = 135, .c_end = 2, .worth_tuning = true },
    .{ .name = "TmStabilityMultiplier", .value = 3, .min_value = 1, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "TmStabilityMin", .value = 50, .min_value = 30, .max_value = 70, .c_end = 2, .worth_tuning = true },
    .{ .name = "TmScoreJumpMultiplier", .value = 110, .min_value = 100, .max_value = 150, .c_end = 2.5, .worth_tuning = true },
    .{ .name = "TmScoreJumpThreshold", .value = 14, .min_value = 5, .max_value = 40, .c_end = 1.75, .r_end = 0.002, .worth_tuning = true },
    .{ .name = "NodeTmDepth", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NodeTmBase", .value = 144, .min_value = 100, .max_value = 250, .c_end = 8, .worth_tuning = true },
    .{ .name = "NodeTmMultiplier", .value = 174, .min_value = 80, .max_value = 260, .c_end = 10, .worth_tuning = true },
    .{ .name = "NodeTmMin", .value = 50, .min_value = 20, .max_value = 90, .c_end = 3.5, .worth_tuning = false },
    .{ .name = "NodeTmMax", .value = 200, .min_value = 110, .max_value = 350, .c_end = 12, .worth_tuning = true },

    .{ .name = "RFPDepth", .value = 8, .min_value = 5, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "RFPMultiplier", .value = 85, .min_value = 30, .max_value = 130, .c_end = 5, .worth_tuning = true },
    .{ .name = "RFPImprovingDeduction", .value = 102, .min_value = 20, .max_value = 150, .c_end = 6.5, .worth_tuning = true },

    .{ .name = "NMPDepth", .value = 3, .min_value = 2, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPBase", .value = 4, .min_value = 2, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPDepthFactor", .value = 76, .min_value = 32, .max_value = 128, .c_end = 5, .worth_tuning = true },
    .{ .name = "NMPImprovingMargin", .value = 98, .min_value = 20, .max_value = 160, .c_end = 7, .worth_tuning = true },
    .{ .name = "NMPBetaDivisor", .value = 171, .min_value = 90, .max_value = 320, .c_end = 11, .worth_tuning = true },
    .{ .name = "NMPBetaMax", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPVerifyDepth", .value = 12, .min_value = 8, .max_value = 18, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPVerifyPlyFactor", .value = 70, .min_value = 40, .max_value = 100, .c_end = 3, .worth_tuning = true },

    .{ .name = "RazoringDepth", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "RazoringBase", .value = 126, .min_value = 20, .max_value = 180, .c_end = 8, .worth_tuning = true },
    .{ .name = "RazoringMargin", .value = 212, .min_value = 120, .max_value = 450, .c_end = 16, .worth_tuning = true },

    .{ .name = "ProbCutDepth", .value = 5, .min_value = 3, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutReduction", .value = 4, .min_value = 3, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutTTDepthMargin", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutMargin", .value = 237, .min_value = 100, .max_value = 400, .c_end = 15, .worth_tuning = true },

    .{ .name = "IIRDepth", .value = 3, .min_value = 2, .max_value = 5, .c_end = 0.5, .worth_tuning = false },

    .{ .name = "LMPDepth", .value = 5, .min_value = 3, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPBase", .value = 4, .min_value = 1, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPMultiplier", .value = 73, .min_value = 50, .max_value = 180, .c_end = 6.5, .worth_tuning = true },
    .{ .name = "LMPImprovingBase", .value = 1, .min_value = 0, .max_value = 4, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPImprovingPercent", .value = 47, .min_value = 20, .max_value = 100, .c_end = 4, .worth_tuning = true },

    .{ .name = "HistPruningDepth", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "HistPruningMargin", .value = 1713, .min_value = 600, .max_value = 4000, .c_end = 170, .worth_tuning = true },

    .{ .name = "FPDepth", .value = 8, .min_value = 4, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "FPBase", .value = 51, .min_value = 20, .max_value = 200, .c_end = 9, .worth_tuning = true },
    .{ .name = "FPMargin", .value = 50, .min_value = 20, .max_value = 160, .c_end = 7, .worth_tuning = true },

    .{ .name = "SEEPruningDepth", .value = 8, .min_value = 4, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SEEQuietMargin", .value = 45, .min_value = 15, .max_value = 110, .c_end = 5, .worth_tuning = true },
    .{ .name = "SEENoisyMargin", .value = 34, .min_value = 10, .max_value = 90, .c_end = 4, .worth_tuning = true },

    .{ .name = "SEDepth", .value = 7, .min_value = 5, .max_value = 10, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SETTDepthMargin", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SEBetaMultiplier", .value = 87, .min_value = 30, .max_value = 220, .c_end = 9.5, .worth_tuning = true },
    .{ .name = "SEDoubleMargin", .value = 32, .min_value = 10, .max_value = 90, .c_end = 4, .worth_tuning = true },
    .{ .name = "SETripleMargin", .value = 89, .min_value = 30, .max_value = 200, .c_end = 8, .worth_tuning = true },
    .{ .name = "SEFailHighReduction", .value = 2, .min_value = 0, .max_value = 4, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SECutnodeReduction", .value = 1, .min_value = 0, .max_value = 3, .c_end = 0.5, .worth_tuning = false },

    .{ .name = "LMRWeight", .value = 457, .min_value = 250, .max_value = 700, .c_end = 22, .worth_tuning = true, .reinit_lmr = true },
    .{ .name = "LMRBias", .value = 644, .min_value = 300, .max_value = 900, .c_end = 30, .worth_tuning = true, .reinit_lmr = true },
    .{ .name = "LMRDepth", .value = 3, .min_value = 2, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRMinMovePV", .value = 5, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRMinMoveNonPV", .value = 3, .min_value = 1, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRCutnode", .value = 2, .min_value = 0, .max_value = 3, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRImproving", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRNonPV", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRTTDepth", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRCheck", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRHistoryDivisor", .value = 8020, .min_value = 3072, .max_value = 16384, .c_end = 460, .worth_tuning = true },

    .{ .name = "HistoryBonusMultiplier", .value = 404, .min_value = 160, .max_value = 700, .c_end = 27, .worth_tuning = true },
    .{ .name = "HistoryBonusOffset", .value = 329, .min_value = 0, .max_value = 768, .c_end = 38, .worth_tuning = true },
    .{ .name = "HistoryBonusMax", .value = 1997, .min_value = 768, .max_value = 3072, .c_end = 115, .worth_tuning = true },
    .{ .name = "HistoryGravityMax", .value = 15649, .min_value = 8192, .max_value = 29000, .c_end = 1200, .worth_tuning = true },

    .{ .name = "MovepickSEEMargin", .value = 91, .min_value = 0, .max_value = 220, .c_end = 11, .worth_tuning = true },
    .{ .name = "QSSEEMargin", .value = 28, .min_value = 0, .max_value = 120, .c_end = 6, .worth_tuning = true },
    .{ .name = "ContHistWeight1", .value = 194, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
    .{ .name = "ContHistWeight2", .value = 133, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
    .{ .name = "ContHistWeight4", .value = 128, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
};

fn int_default(comptime name: []const u8) comptime_int {
    @setEvalBranchQuota(1 << 20);
    for (TunableParams) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.value;
    }
    @compileError("no tunable named " ++ name);
}

fn float_default(comptime name: []const u8) f64 {
    return @as(f64, int_default(name)) / 1000.0;
}

pub var AspirationWindow: i32 = int_default("AspirationWindow");
pub var AspirationDepth: i32 = int_default("AspirationDepth");
pub var AspirationDeltaPercent: i32 = int_default("AspirationDeltaPercent");

pub var TmSoftFactor: u64 = int_default("TmSoftFactor");
pub var TmHardFactor: u64 = int_default("TmHardFactor");
pub var TmStabilityBase: i32 = int_default("TmStabilityBase");
pub var TmStabilityMultiplier: i32 = int_default("TmStabilityMultiplier");
pub var TmStabilityMin: i32 = int_default("TmStabilityMin");
pub var TmScoreJumpMultiplier: i32 = int_default("TmScoreJumpMultiplier");
pub var TmScoreJumpThreshold: i32 = int_default("TmScoreJumpThreshold");
pub var NodeTmDepth: usize = int_default("NodeTmDepth");
pub var NodeTmBase: i32 = int_default("NodeTmBase");
pub var NodeTmMultiplier: i32 = int_default("NodeTmMultiplier");
pub var NodeTmMin: i32 = int_default("NodeTmMin");
pub var NodeTmMax: i32 = int_default("NodeTmMax");

pub var RFPDepth: i32 = int_default("RFPDepth");
pub var RFPMultiplier: i32 = int_default("RFPMultiplier");
pub var RFPImprovingDeduction: i32 = int_default("RFPImprovingDeduction");

pub var NMPDepth: i32 = int_default("NMPDepth");
pub var NMPBase: usize = int_default("NMPBase");
pub var NMPDepthFactor: usize = int_default("NMPDepthFactor");
pub var NMPImprovingMargin: i32 = int_default("NMPImprovingMargin");
pub var NMPBetaDivisor: i32 = int_default("NMPBetaDivisor");
pub var NMPBetaMax: i32 = int_default("NMPBetaMax");
pub var NMPVerifyDepth: i32 = int_default("NMPVerifyDepth");
pub var NMPVerifyPlyFactor: usize = int_default("NMPVerifyPlyFactor");

pub var RazoringDepth: i32 = int_default("RazoringDepth");
pub var RazoringBase: i32 = int_default("RazoringBase");
pub var RazoringMargin: i32 = int_default("RazoringMargin");

pub var ProbCutDepth: usize = int_default("ProbCutDepth");
pub var ProbCutReduction: usize = int_default("ProbCutReduction");
pub var ProbCutTTDepthMargin: usize = int_default("ProbCutTTDepthMargin");
pub var ProbCutMargin: i32 = int_default("ProbCutMargin");

pub var IIRDepth: i32 = int_default("IIRDepth");

pub var LMPDepth: i32 = int_default("LMPDepth");
pub var LMPBase: usize = int_default("LMPBase");
pub var LMPMultiplier: usize = int_default("LMPMultiplier");
pub var LMPImprovingBase: usize = int_default("LMPImprovingBase");
pub var LMPImprovingPercent: usize = int_default("LMPImprovingPercent");

pub var HistPruningDepth: i32 = int_default("HistPruningDepth");
pub var HistPruningMargin: i32 = int_default("HistPruningMargin");

pub var FPDepth: i32 = int_default("FPDepth");
pub var FPBase: i32 = int_default("FPBase");
pub var FPMargin: i32 = int_default("FPMargin");

pub var SEEPruningDepth: i32 = int_default("SEEPruningDepth");
pub var SEEQuietMargin: i32 = int_default("SEEQuietMargin");
pub var SEENoisyMargin: i32 = int_default("SEENoisyMargin");

pub var SEDepth: i32 = int_default("SEDepth");
pub var SETTDepthMargin: usize = int_default("SETTDepthMargin");
pub var SEBetaMultiplier: usize = int_default("SEBetaMultiplier");
pub var SEDoubleMargin: i32 = int_default("SEDoubleMargin");
pub var SETripleMargin: i32 = int_default("SETripleMargin");
pub var SEFailHighReduction: i32 = int_default("SEFailHighReduction");
pub var SECutnodeReduction: i32 = int_default("SECutnodeReduction");

pub var LMRWeight: f64 = float_default("LMRWeight");
pub var LMRBias: f64 = float_default("LMRBias");
pub var LMRDepth: i32 = int_default("LMRDepth");
pub var LMRMinMovePV: usize = int_default("LMRMinMovePV");
pub var LMRMinMoveNonPV: usize = int_default("LMRMinMoveNonPV");
pub var LMRCutnode: i32 = int_default("LMRCutnode");
pub var LMRImproving: i32 = int_default("LMRImproving");
pub var LMRNonPV: i32 = int_default("LMRNonPV");
pub var LMRTTDepth: i32 = int_default("LMRTTDepth");
pub var LMRCheck: i32 = int_default("LMRCheck");
pub var LMRHistoryDivisor: i32 = int_default("LMRHistoryDivisor");

pub var HistoryBonusMultiplier: i32 = int_default("HistoryBonusMultiplier");
pub var HistoryBonusOffset: i32 = int_default("HistoryBonusOffset");
pub var HistoryBonusMax: i32 = int_default("HistoryBonusMax");
pub var HistoryGravityMax: i32 = int_default("HistoryGravityMax");

pub var MovepickSEEMargin: i32 = int_default("MovepickSEEMargin");
pub var QSSEEMargin: i32 = int_default("QSSEEMargin");
pub var ContHistWeight1: i32 = int_default("ContHistWeight1");
pub var ContHistWeight2: i32 = int_default("ContHistWeight2");
pub var ContHistWeight4: i32 = int_default("ContHistWeight4");

pub fn set(name: []const u8, raw: i64) ?Tunable {
    @setEvalBranchQuota(1 << 20);
    inline for (TunableParams) |t| {
        if (std.mem.eql(u8, name, t.name)) {
            const clamped = std.math.clamp(raw, @as(i64, t.min_value), @as(i64, t.max_value));
            const T = @TypeOf(@field(@This(), t.name));
            @field(@This(), t.name) = if (@typeInfo(T) == .float)
                @as(T, @floatFromInt(clamped)) / 1000.0
            else
                @as(T, @intCast(clamped));
            return t;
        }
    }
    return null;
}

pub fn live_uci_value(name: []const u8) ?i64 {
    @setEvalBranchQuota(1 << 20);
    inline for (TunableParams) |t| {
        if (std.mem.eql(u8, name, t.name)) {
            const T = @TypeOf(@field(@This(), t.name));
            if (@typeInfo(T) == .float) {
                return @as(i64, @intFromFloat(@round(@field(@This(), t.name) * 1000.0)));
            }
            return @as(i64, @intCast(@field(@This(), t.name)));
        }
    }
    return null;
}

comptime {
    for (TunableParams) |t| {
        if (!@hasDecl(@This(), t.name)) {
            @compileError("tunable '" ++ t.name ++ "' has no matching variable");
        }
        if (t.min_value > t.value or t.value > t.max_value) {
            @compileError("tunable '" ++ t.name ++ "' has a default outside [min, max]");
        }
        if (t.min_value < 0) {
            @compileError("tunable '" ++ t.name ++ "' must stay non-negative for UCI spin options");
        }
    }
}
