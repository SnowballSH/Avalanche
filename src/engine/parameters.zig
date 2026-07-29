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
    // -- Aspiration windows --
    .{ .name = "AspirationWindow", .value = 16, .min_value = 5, .max_value = 30, .c_end = 1.25, .worth_tuning = true },
    .{ .name = "AspirationDepth", .value = 6, .min_value = 4, .max_value = 9, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "AspirationDeltaPercent", .value = 25, .min_value = 10, .max_value = 60, .c_end = 2.5, .worth_tuning = true },

    // -- Time management --
    .{ .name = "TmSoftFactor", .value = 37, .min_value = 18, .max_value = 70, .c_end = 2.5, .worth_tuning = true },
    .{ .name = "TmHardFactor", .value = 64, .min_value = 32, .max_value = 140, .c_end = 5, .worth_tuning = true },
    .{ .name = "TmStabilityBase", .value = 110, .min_value = 95, .max_value = 135, .c_end = 2, .worth_tuning = true },
    .{ .name = "TmStabilityMultiplier", .value = 3, .min_value = 1, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "TmStabilityMin", .value = 50, .min_value = 30, .max_value = 70, .c_end = 2, .worth_tuning = true },
    .{ .name = "TmScoreJumpMultiplier", .value = 110, .min_value = 100, .max_value = 150, .c_end = 2.5, .worth_tuning = true },
    .{ .name = "NodeTmDepth", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NodeTmBase", .value = 144, .min_value = 100, .max_value = 250, .c_end = 8, .worth_tuning = true },
    .{ .name = "NodeTmMultiplier", .value = 174, .min_value = 80, .max_value = 260, .c_end = 10, .worth_tuning = true },
    .{ .name = "NodeTmMin", .value = 50, .min_value = 20, .max_value = 90, .c_end = 3.5, .worth_tuning = true },
    .{ .name = "NodeTmMax", .value = 200, .min_value = 110, .max_value = 350, .c_end = 12, .worth_tuning = true },

    // -- Reverse futility pruning --
    .{ .name = "RFPDepth", .value = 8, .min_value = 5, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "RFPMultiplier", .value = 80, .min_value = 30, .max_value = 130, .c_end = 5, .worth_tuning = true },
    .{ .name = "RFPImprovingDeduction", .value = 88, .min_value = 20, .max_value = 150, .c_end = 6.5, .worth_tuning = true },

    // -- Null move pruning --
    .{ .name = "NMPDepth", .value = 3, .min_value = 2, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPBase", .value = 4, .min_value = 2, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPDepthFactor", .value = 69, .min_value = 32, .max_value = 128, .c_end = 5, .worth_tuning = true },
    .{ .name = "NMPImprovingMargin", .value = 95, .min_value = 20, .max_value = 160, .c_end = 7, .worth_tuning = true },
    .{ .name = "NMPBetaDivisor", .value = 174, .min_value = 90, .max_value = 320, .c_end = 11, .worth_tuning = true },
    .{ .name = "NMPBetaMax", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPVerifyDepth", .value = 12, .min_value = 8, .max_value = 18, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "NMPVerifyPlyFactor", .value = 74, .min_value = 40, .max_value = 100, .c_end = 3, .worth_tuning = true },

    // -- Razoring --
    .{ .name = "RazoringDepth", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "RazoringBase", .value = 106, .min_value = 20, .max_value = 180, .c_end = 8, .worth_tuning = true },
    .{ .name = "RazoringMargin", .value = 249, .min_value = 120, .max_value = 450, .c_end = 16, .worth_tuning = true },

    // -- ProbCut --
    .{ .name = "ProbCutDepth", .value = 5, .min_value = 3, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutReduction", .value = 4, .min_value = 3, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutTTDepthMargin", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "ProbCutMargin", .value = 230, .min_value = 100, .max_value = 400, .c_end = 15, .worth_tuning = true },

    // -- Internal iterative reduction --
    .{ .name = "IIRDepth", .value = 3, .min_value = 2, .max_value = 5, .c_end = 0.5, .worth_tuning = false },

    // -- Late move pruning --
    .{ .name = "LMPDepth", .value = 5, .min_value = 3, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPBase", .value = 4, .min_value = 1, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPMultiplier", .value = 86, .min_value = 50, .max_value = 180, .c_end = 6.5, .worth_tuning = true },
    .{ .name = "LMPImprovingBase", .value = 1, .min_value = 0, .max_value = 4, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMPImprovingPercent", .value = 51, .min_value = 20, .max_value = 100, .c_end = 4, .worth_tuning = true },

    // -- History pruning --
    .{ .name = "HistPruningDepth", .value = 4, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "HistPruningMargin", .value = 1724, .min_value = 600, .max_value = 4000, .c_end = 170, .worth_tuning = true },

    // -- Futility pruning --
    .{ .name = "FPDepth", .value = 8, .min_value = 4, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "FPBase", .value = 54, .min_value = 20, .max_value = 200, .c_end = 9, .worth_tuning = true },
    .{ .name = "FPMargin", .value = 45, .min_value = 20, .max_value = 160, .c_end = 7, .worth_tuning = true },

    // -- SEE pruning --
    .{ .name = "SEEPruningDepth", .value = 8, .min_value = 4, .max_value = 12, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SEEQuietMargin", .value = 47, .min_value = 15, .max_value = 110, .c_end = 5, .worth_tuning = true },
    .{ .name = "SEENoisyMargin", .value = 37, .min_value = 10, .max_value = 90, .c_end = 4, .worth_tuning = true },

    // -- Singular extensions --
    .{ .name = "SEDepth", .value = 7, .min_value = 5, .max_value = 10, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SETTDepthMargin", .value = 3, .min_value = 1, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SEBetaMultiplier", .value = 102, .min_value = 30, .max_value = 220, .c_end = 9.5, .worth_tuning = true },
    .{ .name = "SEDoubleMargin", .value = 34, .min_value = 10, .max_value = 90, .c_end = 4, .worth_tuning = true },
    .{ .name = "SETripleMargin", .value = 92, .min_value = 30, .max_value = 200, .c_end = 8, .worth_tuning = true },
    .{ .name = "SEFailHighReduction", .value = 2, .min_value = 0, .max_value = 4, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "SECutnodeReduction", .value = 1, .min_value = 0, .max_value = 3, .c_end = 0.5, .worth_tuning = false },

    // -- Late move reductions --
    .{ .name = "LMRWeight", .value = 504, .min_value = 250, .max_value = 700, .c_end = 22, .worth_tuning = true, .reinit_lmr = true },
    .{ .name = "LMRBias", .value = 603, .min_value = 300, .max_value = 900, .c_end = 30, .worth_tuning = true, .reinit_lmr = true },
    .{ .name = "LMRDepth", .value = 3, .min_value = 2, .max_value = 5, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRMinMovePV", .value = 5, .min_value = 2, .max_value = 8, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRMinMoveNonPV", .value = 3, .min_value = 1, .max_value = 6, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRCutnode", .value = 2, .min_value = 0, .max_value = 3, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRImproving", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRNonPV", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRTTDepth", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRCheck", .value = 1, .min_value = 0, .max_value = 2, .c_end = 0.5, .worth_tuning = false },
    .{ .name = "LMRHistoryDivisor", .value = 5698, .min_value = 3072, .max_value = 12288, .c_end = 460, .worth_tuning = true },

    // -- History updates --
    .{ .name = "HistoryBonusMultiplier", .value = 388, .min_value = 160, .max_value = 700, .c_end = 27, .worth_tuning = true },
    .{ .name = "HistoryBonusOffset", .value = 389, .min_value = 0, .max_value = 768, .c_end = 38, .worth_tuning = true },
    .{ .name = "HistoryBonusMax", .value = 1651, .min_value = 768, .max_value = 3072, .c_end = 115, .worth_tuning = true },
    .{ .name = "HistoryGravityMax", .value = 16849, .min_value = 8192, .max_value = 32768, .c_end = 1200, .worth_tuning = true },

    // -- Move ordering and quiescence --
    .{ .name = "MovepickSEEMargin", .value = 99, .min_value = 0, .max_value = 220, .c_end = 11, .worth_tuning = true },
    .{ .name = "QSSEEMargin", .value = 32, .min_value = 0, .max_value = 120, .c_end = 6, .worth_tuning = true },
    .{ .name = "ContHistWeight1", .value = 141, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
    .{ .name = "ContHistWeight2", .value = 134, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
    .{ .name = "ContHistWeight4", .value = 132, .min_value = 32, .max_value = 256, .c_end = 11, .worth_tuning = true },
};

fn intDefault(comptime name: []const u8) comptime_int {
    @setEvalBranchQuota(1 << 20);
    for (TunableParams) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.value;
    }
    @compileError("no tunable named " ++ name);
}

fn floatDefault(comptime name: []const u8) f64 {
    return @as(f64, intDefault(name)) / 1000.0;
}

// -- Aspiration windows --
pub var AspirationWindow: i32 = intDefault("AspirationWindow");
pub var AspirationDepth: i32 = intDefault("AspirationDepth");
pub var AspirationDeltaPercent: i32 = intDefault("AspirationDeltaPercent");

// -- Time management --
pub var TmSoftFactor: u64 = intDefault("TmSoftFactor");
pub var TmHardFactor: u64 = intDefault("TmHardFactor");
pub var TmStabilityBase: i32 = intDefault("TmStabilityBase");
pub var TmStabilityMultiplier: i32 = intDefault("TmStabilityMultiplier");
pub var TmStabilityMin: i32 = intDefault("TmStabilityMin");
pub var TmScoreJumpMultiplier: i32 = intDefault("TmScoreJumpMultiplier");
pub var NodeTmDepth: usize = intDefault("NodeTmDepth");
pub var NodeTmBase: i32 = intDefault("NodeTmBase");
pub var NodeTmMultiplier: i32 = intDefault("NodeTmMultiplier");
pub var NodeTmMin: i32 = intDefault("NodeTmMin");
pub var NodeTmMax: i32 = intDefault("NodeTmMax");

// -- Reverse futility pruning --
pub var RFPDepth: i32 = intDefault("RFPDepth");
pub var RFPMultiplier: i32 = intDefault("RFPMultiplier");
pub var RFPImprovingDeduction: i32 = intDefault("RFPImprovingDeduction");

// -- Null move pruning --
pub var NMPDepth: i32 = intDefault("NMPDepth");
pub var NMPBase: usize = intDefault("NMPBase");
pub var NMPDepthFactor: usize = intDefault("NMPDepthFactor");
pub var NMPImprovingMargin: i32 = intDefault("NMPImprovingMargin");
pub var NMPBetaDivisor: i32 = intDefault("NMPBetaDivisor");
pub var NMPBetaMax: i32 = intDefault("NMPBetaMax");
pub var NMPVerifyDepth: i32 = intDefault("NMPVerifyDepth");
pub var NMPVerifyPlyFactor: usize = intDefault("NMPVerifyPlyFactor");

// -- Razoring --
pub var RazoringDepth: i32 = intDefault("RazoringDepth");
pub var RazoringBase: i32 = intDefault("RazoringBase");
pub var RazoringMargin: i32 = intDefault("RazoringMargin");

// -- ProbCut --
pub var ProbCutDepth: usize = intDefault("ProbCutDepth");
pub var ProbCutReduction: usize = intDefault("ProbCutReduction");
pub var ProbCutTTDepthMargin: usize = intDefault("ProbCutTTDepthMargin");
pub var ProbCutMargin: i32 = intDefault("ProbCutMargin");

// -- Internal iterative reduction --
pub var IIRDepth: i32 = intDefault("IIRDepth");

// -- Late move pruning --
pub var LMPDepth: i32 = intDefault("LMPDepth");
pub var LMPBase: usize = intDefault("LMPBase");
pub var LMPMultiplier: usize = intDefault("LMPMultiplier");
pub var LMPImprovingBase: usize = intDefault("LMPImprovingBase");
pub var LMPImprovingPercent: usize = intDefault("LMPImprovingPercent");

// -- History pruning --
pub var HistPruningDepth: i32 = intDefault("HistPruningDepth");
pub var HistPruningMargin: i32 = intDefault("HistPruningMargin");

// -- Futility pruning --
pub var FPDepth: i32 = intDefault("FPDepth");
pub var FPBase: i32 = intDefault("FPBase");
pub var FPMargin: i32 = intDefault("FPMargin");

// -- SEE pruning --
pub var SEEPruningDepth: i32 = intDefault("SEEPruningDepth");
pub var SEEQuietMargin: i32 = intDefault("SEEQuietMargin");
pub var SEENoisyMargin: i32 = intDefault("SEENoisyMargin");

// -- Singular extensions --
pub var SEDepth: i32 = intDefault("SEDepth");
pub var SETTDepthMargin: usize = intDefault("SETTDepthMargin");
pub var SEBetaMultiplier: usize = intDefault("SEBetaMultiplier");
pub var SEDoubleMargin: i32 = intDefault("SEDoubleMargin");
pub var SETripleMargin: i32 = intDefault("SETripleMargin");
pub var SEFailHighReduction: i32 = intDefault("SEFailHighReduction");
pub var SECutnodeReduction: i32 = intDefault("SECutnodeReduction");

// -- Late move reductions --
pub var LMRWeight: f64 = floatDefault("LMRWeight");
pub var LMRBias: f64 = floatDefault("LMRBias");
pub var LMRDepth: i32 = intDefault("LMRDepth");
pub var LMRMinMovePV: usize = intDefault("LMRMinMovePV");
pub var LMRMinMoveNonPV: usize = intDefault("LMRMinMoveNonPV");
pub var LMRCutnode: i32 = intDefault("LMRCutnode");
pub var LMRImproving: i32 = intDefault("LMRImproving");
pub var LMRNonPV: i32 = intDefault("LMRNonPV");
pub var LMRTTDepth: i32 = intDefault("LMRTTDepth");
pub var LMRCheck: i32 = intDefault("LMRCheck");
pub var LMRHistoryDivisor: i32 = intDefault("LMRHistoryDivisor");

// -- History updates --
pub var HistoryBonusMultiplier: i32 = intDefault("HistoryBonusMultiplier");
pub var HistoryBonusOffset: i32 = intDefault("HistoryBonusOffset");
pub var HistoryBonusMax: i32 = intDefault("HistoryBonusMax");
pub var HistoryGravityMax: i32 = intDefault("HistoryGravityMax");

// -- Move ordering and quiescence --
pub var MovepickSEEMargin: i32 = intDefault("MovepickSEEMargin");
pub var QSSEEMargin: i32 = intDefault("QSSEEMargin");
pub var ContHistWeight1: i32 = intDefault("ContHistWeight1");
pub var ContHistWeight2: i32 = intDefault("ContHistWeight2");
pub var ContHistWeight4: i32 = intDefault("ContHistWeight4");

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
