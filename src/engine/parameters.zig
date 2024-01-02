pub var LMRWeight: f64 = 0.423;
pub var LMRBias: f64 = 0.77;

pub var RFPDepth: i32 = 8;
pub var RFPMultiplier: i32 = 55;
pub var RFPImprovingDeduction: i32 = 68;

pub var NMPImprovingMargin: i32 = 73;
pub var NMPBase: usize = 3;
pub var NMPDepthDivisor: usize = 3;
pub var NMPBetaDivisor: i32 = 206;

pub var RazoringBase: i32 = 67;
pub var RazoringMargin: i32 = 190;

pub var AspirationWindow: i32 = 11;

pub const Tunable = struct {
    name: []const u8,
    value: []const u8,
    min_value: []const u8,
    max_value: []const u8,
    id: usize,
};

pub const TunableParams = [_]Tunable{
    Tunable{ .name = "LMRWeight", .value = "423", .min_value = "1", .max_value = "999", .id = 0 },
    Tunable{ .name = "LMRBias", .value = "770", .min_value = "1", .max_value = "9999", .id = 1 },
    Tunable{ .name = "RFPDepth", .value = "8", .min_value = "1", .max_value = "16", .id = 2 },
    Tunable{ .name = "RFPMultiplier", .value = "55", .min_value = "1", .max_value = "999", .id = 3 },
    Tunable{ .name = "RFPImprovingDeduction", .value = "68", .min_value = "1", .max_value = "999", .id = 4 },
    Tunable{ .name = "NMPImprovingMargin", .value = "73", .min_value = "1", .max_value = "999", .id = 5 },
    Tunable{ .name = "NMPBase", .value = "3", .min_value = "1", .max_value = "16", .id = 6 },
    Tunable{ .name = "NMPDepthDivisor", .value = "3", .min_value = "1", .max_value = "16", .id = 7 },
    Tunable{ .name = "NMPBetaDivisor", .value = "206", .min_value = "1", .max_value = "999", .id = 8 },
    Tunable{ .name = "RazoringBase", .value = "67", .min_value = "1", .max_value = "999", .id = 9 },
    Tunable{ .name = "RazoringMargin", .value = "190", .min_value = "1", .max_value = "999", .id = 10 },
    Tunable{ .name = "AspirationWindow", .value = "11", .min_value = "1", .max_value = "999", .id = 11 },
};
