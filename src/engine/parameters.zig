pub var LMRWeight: f64 = 0.542;
pub var LMRBias: f64 = 0.674;

pub var RFPDepth: i32 = 9;
pub var RFPMultiplier: i32 = 69;
pub var RFPImprovingDeduction: i32 = 80;

pub var NMPImprovingMargin: i32 = 88;
pub var NMPBase: usize = 4;
pub var NMPDepthDivisor: usize = 4;
pub var NMPBetaDivisor: i32 = 180;

pub var RazoringBase: i32 = 104;
pub var RazoringMargin: i32 = 251;

pub var AspirationWindow: i32 = 14;

pub var NodeTmBase: i32 = 133;
pub var NodeTmMultiplier: i32 = 164;

pub var HistPruningDepth: i32 = 4;
pub var HistPruningMargin: i32 = 2120;

pub var FPDepth: i32 = 8;
pub var FPBase: i32 = 75;
pub var FPMargin: i32 = 57;

pub var SEEPruningDepth: i32 = 8;
pub var SEEQuietMargin: i32 = 53;
pub var SEENoisyMargin: i32 = 43;

pub var LMRCutnode: i32 = 2;

pub var SEDoubleMargin: i32 = 33;
pub var SETripleMargin: i32 = 87;

pub var ProbCutMargin: i32 = 228;
pub var ProbCutDepth: usize = 5;
pub var ProbCutReduction: usize = 4;

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
    Tunable{ .name = "LMRWeight", .value = "542", .min_value = "250", .max_value = "650", .c_end = "20", .r_end = "0.002", .id = 0 },
    Tunable{ .name = "LMRBias", .value = "674", .min_value = "300", .max_value = "1300", .c_end = "50", .r_end = "0.002", .id = 1 },
    Tunable{ .name = "RFPDepth", .value = "9", .min_value = "5", .max_value = "12", .c_end = "0.5", .r_end = "0.002", .id = 2 },
    Tunable{ .name = "RFPMultiplier", .value = "69", .min_value = "30", .max_value = "110", .c_end = "4", .r_end = "0.002", .id = 3 },
    Tunable{ .name = "RFPImprovingDeduction", .value = "80", .min_value = "20", .max_value = "120", .c_end = "5", .r_end = "0.002", .id = 4 },
    Tunable{ .name = "NMPImprovingMargin", .value = "88", .min_value = "20", .max_value = "140", .c_end = "6", .r_end = "0.002", .id = 5 },
    Tunable{ .name = "NMPBase", .value = "4", .min_value = "2", .max_value = "5", .c_end = "0.5", .r_end = "0.002", .id = 6 },
    Tunable{ .name = "NMPDepthDivisor", .value = "4", .min_value = "2", .max_value = "5", .c_end = "0.5", .r_end = "0.002", .id = 7 },
    Tunable{ .name = "NMPBetaDivisor", .value = "180", .min_value = "100", .max_value = "320", .c_end = "11", .r_end = "0.002", .id = 8 },
    Tunable{ .name = "RazoringBase", .value = "104", .min_value = "20", .max_value = "140", .c_end = "6", .r_end = "0.002", .id = 9 },
    Tunable{ .name = "RazoringMargin", .value = "251", .min_value = "80", .max_value = "320", .c_end = "12", .r_end = "0.002", .id = 10 },
    Tunable{ .name = "AspirationWindow", .value = "14", .min_value = "5", .max_value = "30", .c_end = "1.25", .r_end = "0.002", .id = 11 },
    Tunable{ .name = "NodeTmBase", .value = "133", .min_value = "100", .max_value = "250", .c_end = "8", .r_end = "0.002", .id = 12 },
    Tunable{ .name = "NodeTmMultiplier", .value = "164", .min_value = "80", .max_value = "260", .c_end = "10", .r_end = "0.002", .id = 13 },
    Tunable{ .name = "HistPruningDepth", .value = "4", .min_value = "1", .max_value = "5", .c_end = "0.5", .r_end = "0.002", .id = 14 },
    Tunable{ .name = "HistPruningMargin", .value = "2120", .min_value = "512", .max_value = "5000", .c_end = "150", .r_end = "0.002", .id = 15 },
    Tunable{ .name = "FPDepth", .value = "8", .min_value = "4", .max_value = "12", .c_end = "0.5", .r_end = "0.002", .id = 16 },
    Tunable{ .name = "FPBase", .value = "75", .min_value = "20", .max_value = "200", .c_end = "8", .r_end = "0.002", .id = 17 },
    Tunable{ .name = "FPMargin", .value = "57", .min_value = "50", .max_value = "250", .c_end = "10", .r_end = "0.002", .id = 18 },
    Tunable{ .name = "SEEPruningDepth", .value = "8", .min_value = "4", .max_value = "12", .c_end = "0.5", .r_end = "0.002", .id = 19 },
    Tunable{ .name = "SEEQuietMargin", .value = "53", .min_value = "30", .max_value = "150", .c_end = "6", .r_end = "0.002", .id = 20 },
    Tunable{ .name = "SEENoisyMargin", .value = "43", .min_value = "10", .max_value = "90", .c_end = "4", .r_end = "0.002", .id = 21 },
    Tunable{ .name = "LMRCutnode", .value = "2", .min_value = "0", .max_value = "3", .c_end = "0.5", .r_end = "0.002", .id = 22 },
    Tunable{ .name = "SEDoubleMargin", .value = "33", .min_value = "2", .max_value = "60", .c_end = "3", .r_end = "0.002", .id = 23 },
    Tunable{ .name = "SETripleMargin", .value = "87", .min_value = "30", .max_value = "200", .c_end = "8", .r_end = "0.002", .id = 24 },
    Tunable{ .name = "ProbCutMargin", .value = "228", .min_value = "100", .max_value = "350", .c_end = "12", .r_end = "0.002", .id = 25 },
    Tunable{ .name = "ProbCutDepth", .value = "5", .min_value = "3", .max_value = "8", .c_end = "0.5", .r_end = "0.002", .id = 26 },
    Tunable{ .name = "ProbCutReduction", .value = "4", .min_value = "3", .max_value = "6", .c_end = "0.5", .r_end = "0.002", .id = 27 },
};
