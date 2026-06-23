pub var LMRWeight: f64 = 0.461;
pub var LMRBias: f64 = 0.873;

pub var RFPDepth: i32 = 9;
pub var RFPMultiplier: i32 = 65;
pub var RFPImprovingDeduction: i32 = 80;

pub var NMPImprovingMargin: i32 = 63;
pub var NMPBase: usize = 3;
pub var NMPDepthDivisor: usize = 3;
pub var NMPBetaDivisor: i32 = 196;

pub var RazoringBase: i32 = 68;
pub var RazoringMargin: i32 = 227;

pub var AspirationWindow: i32 = 13;

pub var NodeTmBase: i32 = 150;
pub var NodeTmMultiplier: i32 = 174;

pub const Tunable = struct {
    name: []const u8,
    value: []const u8,
    min_value: []const u8,
    max_value: []const u8,
    c_end: []const u8,
    r_end: []const u8,
    id: usize,
};

pub const TunableParams = [_]Tunable{
    Tunable{ .name = "LMRWeight", .value = "461", .min_value = "250", .max_value = "650", .c_end = "20", .r_end = "0.002", .id = 0 },
    Tunable{ .name = "LMRBias", .value = "873", .min_value = "300", .max_value = "1300", .c_end = "50", .r_end = "0.002", .id = 1 },
    Tunable{ .name = "RFPDepth", .value = "9", .min_value = "5", .max_value = "12", .c_end = "0.5", .r_end = "0.002", .id = 2 },
    Tunable{ .name = "RFPMultiplier", .value = "65", .min_value = "30", .max_value = "110", .c_end = "4", .r_end = "0.002", .id = 3 },
    Tunable{ .name = "RFPImprovingDeduction", .value = "80", .min_value = "20", .max_value = "120", .c_end = "5", .r_end = "0.002", .id = 4 },
    Tunable{ .name = "NMPImprovingMargin", .value = "63", .min_value = "20", .max_value = "140", .c_end = "6", .r_end = "0.002", .id = 5 },
    Tunable{ .name = "NMPBase", .value = "3", .min_value = "2", .max_value = "5", .c_end = "0.5", .r_end = "0.002", .id = 6 },
    Tunable{ .name = "NMPDepthDivisor", .value = "3", .min_value = "2", .max_value = "5", .c_end = "0.5", .r_end = "0.002", .id = 7 },
    Tunable{ .name = "NMPBetaDivisor", .value = "196", .min_value = "100", .max_value = "320", .c_end = "11", .r_end = "0.002", .id = 8 },
    Tunable{ .name = "RazoringBase", .value = "68", .min_value = "20", .max_value = "140", .c_end = "6", .r_end = "0.002", .id = 9 },
    Tunable{ .name = "RazoringMargin", .value = "227", .min_value = "80", .max_value = "320", .c_end = "12", .r_end = "0.002", .id = 10 },
    Tunable{ .name = "AspirationWindow", .value = "13", .min_value = "5", .max_value = "30", .c_end = "1.25", .r_end = "0.002", .id = 11 },
    Tunable{ .name = "NodeTmBase", .value = "150", .min_value = "100", .max_value = "250", .c_end = "8", .r_end = "0.002", .id = 12 },
    Tunable{ .name = "NodeTmMultiplier", .value = "174", .min_value = "80", .max_value = "260", .c_end = "10", .r_end = "0.002", .id = 13 },
};
