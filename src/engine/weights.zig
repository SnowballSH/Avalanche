const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("../platform.zig");

const NNUE_SOURCE = @embedFile("nnue");

/// King input buckets. 1 = flat Chess768; 16 = ChessBucketsMirrored.
pub const NUM_INPUT_BUCKETS: usize = build_options.input_buckets;

pub const INPUT_SIZE: usize = 768 * NUM_INPUT_BUCKETS;
pub const HIDDEN_SIZE: usize = 1024;
pub const OUTPUT_SIZE: usize = 8;
pub const OUTPUT_WEIGHT_MIN: i16 = -128;
pub const OUTPUT_WEIGHT_MAX: i16 = 127;

pub const NNUEWeights = struct {
    layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
    layer_1_bias: [HIDDEN_SIZE]i16 align(64),
    layer_2: [OUTPUT_SIZE][HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: [OUTPUT_SIZE]i16 align(64),
};

const MODEL_ALIGN = if (builtin.os.tag == .linux) 2 * 1024 * 1024 else std.atomic.cache_line;
var model_storage: NNUEWeights align(MODEL_ALIGN) = undefined;

// Read in place on wasm to avoid a second 25 MB copy in linear memory. It must
// be a var: through a const, every MODEL access would be folded at comptime.
var embedded_model: [@sizeOf(NNUEWeights)]u8 align(@alignOf(NNUEWeights)) = NNUE_SOURCE[0..@sizeOf(NNUEWeights)].*;

pub const MODEL: *const NNUEWeights = if (platform.is_wasm) @ptrCast(&embedded_model) else &model_storage;

fn adviseHugePages() void {
    if (builtin.os.tag != .linux) return;
    const MADV_HUGEPAGE = 14;
    const bytes = std.mem.asBytes(&model_storage);
    const ptr: [*]align(2 * 1024 * 1024) u8 = @alignCast(bytes.ptr);
    std.posix.madvise(ptr, bytes.len, MADV_HUGEPAGE) catch {};
}

pub const EMBEDDED_NAME = "<embedded>";

/// Shown to users, e.g. "768x16->1024->8".
pub const ARCHITECTURE = std.fmt.comptimePrint("768x{d}->{d}->{d}", .{ NUM_INPUT_BUCKETS, HIDDEN_SIZE, OUTPUT_SIZE });

var active_name_buf: [128]u8 = undefined;
var active_name: []const u8 = build_options.net_name;

/// Name of the network in use: the embedded network's name (the stem of the
/// `-Dnet` file it was built from) or the file name of the loaded EvalFile.
pub fn active_network() []const u8 {
    return active_name;
}

/// Whether a network can be loaded from a file at runtime. Wasm has no file
/// system and reads the embedded network in place.
pub const supports_eval_file = !platform.is_wasm;

pub const NetworkError = error{ WrongSize, OutputWeightOutOfRange };

/// Checks that `bytes` is a network this build can run: the exact quantised
/// layout (including bullet's trailing padding) with output weights inside the
/// range the SIMD inference assumes.
pub fn validate(bytes: []const u8) NetworkError!void {
    if (bytes.len != @sizeOf(NNUEWeights)) return NetworkError.WrongSize;
    const layer_2 = bytes[@offsetOf(NNUEWeights, "layer_2")..][0..@sizeOf(@FieldType(NNUEWeights, "layer_2"))];
    var i: usize = 0;
    while (i < layer_2.len) : (i += 2) {
        const weight = std.mem.readInt(i16, layer_2[i..][0..2], .little);
        if (weight < OUTPUT_WEIGHT_MIN or weight > OUTPUT_WEIGHT_MAX) return NetworkError.OutputWeightOutOfRange;
    }
}

comptime {
    if (NNUE_SOURCE.len != @sizeOf(NNUEWeights)) {
        @compileError(std.fmt.comptimePrint("Embedded network has {d} bytes but this build's architecture ({s}) needs {d}; check -Dnet and -Dbuckets", .{ NNUE_SOURCE.len, ARCHITECTURE, @sizeOf(NNUEWeights) }));
    }
}

pub fn do_nnue() void {
    adviseHugePages();
    // Copy straight into the global. Do NOT assign through a by-value temporary.
    // A 25 MB MODEL on the stack may cause overflow.
    if (!platform.is_wasm) {
        @memcpy(std.mem.asBytes(&model_storage), NNUE_SOURCE[0..@sizeOf(NNUEWeights)]);
    }
    // Validate the network in use rather than NNUE_SOURCE: on wasm, referencing
    // the embedded bytes at runtime would emit a second 25 MB copy of them.
    validate(std.mem.asBytes(MODEL)) catch |err| std.debug.panic("Embedded network is unusable: {s}", .{@errorName(err)});
}

/// Replaces the active network with the file at `path`, or with the embedded
/// network for `EMBEDDED_NAME`. The active network is untouched on error.
/// Callers must refresh every position's accumulators afterwards.
pub fn load(path: []const u8) !void {
    if (comptime !supports_eval_file) return error.Unsupported;
    if (std.mem.eql(u8, path, EMBEDDED_NAME)) {
        @memcpy(std.mem.asBytes(&model_storage), NNUE_SOURCE[0..@sizeOf(NNUEWeights)]);
        active_name = build_options.net_name;
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(@sizeOf(NNUEWeights) + 1));
    defer platform.allocator.free(bytes);
    try validate(bytes);
    @memcpy(std.mem.asBytes(&model_storage), bytes);

    const file_name = std.fs.path.basename(path);
    const kept = file_name[0..@min(file_name.len, active_name_buf.len)];
    @memcpy(active_name_buf[0..kept.len], kept);
    active_name = active_name_buf[0..kept.len];
}
