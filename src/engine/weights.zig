const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("../platform.zig");

const NNUE_SOURCE = @embedFile("nnue");

pub const arch = @import("nnue/arch.zig");
pub const head_single = @import("nnue/head_single.zig");
pub const head_multi = @import("nnue/head_multi.zig");

/// King input buckets. 1 = flat Chess768; 16 = ChessBucketsMirrored.
pub const NUM_INPUT_BUCKETS: usize = build_options.input_buckets;

pub const INPUT_SIZE: usize = 768 * NUM_INPUT_BUCKETS;
pub const HIDDEN_SIZE: usize = arch.HIDDEN_SIZE;
pub const OUTPUT_SIZE: usize = arch.OUTPUT_SIZE;
pub const OUTPUT_WEIGHT_MIN: i16 = head_single.OUTPUT_WEIGHT_MIN;
pub const OUTPUT_WEIGHT_MAX: i16 = head_single.OUTPUT_WEIGHT_MAX;

/// The layers after the feature transformer. docs/NNUE.md specifies both.
pub const Head = enum { single, multi };

/// A multi-layer network file starts with this; a single-layer one has no
/// header and starts with feature-transformer weights.
pub const MAGIC = "AVALNNUE";
pub const HEADER_SIZE = 64;
pub const FORMAT_VERSION = 1;

/// The whole header of a multi-layer network this build can run: the magic,
/// then little-endian u32 fields. A file must match it byte for byte.
pub const MULTI_HEADER: [HEADER_SIZE]u8 = blk: {
    const fields = [_]u32{
        FORMAT_VERSION,
        @intFromEnum(Head.multi),
        NUM_INPUT_BUCKETS,
        HIDDEN_SIZE,
        OUTPUT_SIZE,
        head_multi.L1_SIZE,
        head_multi.L2_SIZE,
        arch.QA,
        head_multi.FT_SHIFT,
        head_multi.ACT_BITS,
        head_multi.WEIGHT_BITS,
        arch.SCALE,
    };
    var header: [HEADER_SIZE]u8 = @splat(0);
    @memcpy(header[0..MAGIC.len], MAGIC);
    for (fields, 0..) |field, i| {
        std.mem.writeInt(u32, header[MAGIC.len + i * 4 ..][0..4], field, .little);
    }
    break :blk header;
};

fn has_magic(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, MAGIC);
}

/// The quantised network file, byte for byte (little-endian), including the
/// trailing padding bullet adds to reach a multiple of 64 bytes.
pub fn Network(comptime kind: Head) type {
    return switch (kind) {
        .single => extern struct {
            layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
            layer_1_bias: [HIDDEN_SIZE]i16 align(64),
            head: head_single.Weights align(64),
        },
        .multi => extern struct {
            header: [HEADER_SIZE]u8 align(64),
            layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
            layer_1_bias: [HIDDEN_SIZE]i16 align(64),
            head: head_multi.Weights align(64),
        },
    };
}

/// The head this build runs: `-Dhead`, or by default whichever the embedded
/// network is.
pub const HEAD: Head = switch (build_options.head) {
    .auto => if (has_magic(NNUE_SOURCE)) .multi else .single,
    .single => .single,
    .multi => .multi,
};

pub const head = switch (HEAD) {
    .single => head_single,
    .multi => head_multi,
};

pub const NNUEWeights = Network(HEAD);

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
pub const ARCHITECTURE = std.fmt.comptimePrint("768x{d}->{d}->{s}", .{ NUM_INPUT_BUCKETS, HIDDEN_SIZE, head.DESCRIPTION });

var active_name_buf: [std.fs.max_name_bytes]u8 = undefined;
var active_name: []const u8 = build_options.net_name;

/// Name of the network in use: the embedded network's name (the stem of the
/// `-Dnet` file it was built from) or the file name of the loaded EvalFile.
pub fn active_network() []const u8 {
    return active_name;
}

/// Whether a network can be loaded from a file at runtime. Wasm has no file
/// system and reads the embedded network in place.
pub const supports_eval_file = !platform.is_wasm;

pub const NetworkError = error{ WrongSize, WrongArchitecture, UnsupportedHeader, OutputWeightOutOfRange, WeightOutOfRange, BiasOutOfRange };

/// Checks that `bytes` is a network of architecture `kind`: the exact
/// quantised layout with every weight inside the range inference assumes.
pub fn validate_as(comptime kind: Head, bytes: []const u8) NetworkError!void {
    const Net = Network(kind);
    switch (kind) {
        .single => if (has_magic(bytes)) return NetworkError.WrongArchitecture,
        .multi => {
            if (!has_magic(bytes)) return NetworkError.WrongArchitecture;
            if (bytes.len < HEADER_SIZE or !std.mem.eql(u8, bytes[0..HEADER_SIZE], &MULTI_HEADER)) return NetworkError.UnsupportedHeader;
        },
    }
    if (bytes.len != @sizeOf(Net)) return NetworkError.WrongSize;
    const head_bytes = bytes[@offsetOf(Net, "head")..][0..@sizeOf(@FieldType(Net, "head"))];
    try switch (kind) {
        .single => head_single.validate(head_bytes),
        .multi => head_multi.validate(head_bytes),
    };
}

/// Checks that `bytes` is a network this build can run.
pub fn validate(bytes: []const u8) NetworkError!void {
    return validate_as(HEAD, bytes);
}

/// A sentence for the user about a failed `load`.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        NetworkError.WrongArchitecture => switch (HEAD) {
            .single => "it is a multi-layer network, but this build runs the single-layer " ++ ARCHITECTURE ++ "; build with -Dhead=multi -Dnet=<file>",
            .multi => "it has no multi-layer network header, but this build runs " ++ ARCHITECTURE ++ "; a single-layer network needs a -Dhead=single build",
        },
        NetworkError.UnsupportedHeader => "its header describes a different multi-layer architecture or format version than " ++ ARCHITECTURE,
        NetworkError.WrongSize => "its size does not match " ++ ARCHITECTURE,
        NetworkError.OutputWeightOutOfRange, NetworkError.WeightOutOfRange, NetworkError.BiasOutOfRange => "a weight is outside the range the integer inference allows",
        else => @errorName(err),
    };
}

comptime {
    if (build_options.head != .auto and has_magic(NNUE_SOURCE) != (HEAD == .multi)) {
        @compileError("-Dhead=" ++ @tagName(HEAD) ++ " does not match the embedded network, which is a " ++ (if (has_magic(NNUE_SOURCE)) "multi" else "single") ++ "-layer one; check -Dnet");
    }
    if (HEAD == .multi and !std.mem.eql(u8, NNUE_SOURCE[0..HEADER_SIZE], &MULTI_HEADER)) {
        @compileError("The embedded multi-layer network's header does not match this build's architecture (" ++ ARCHITECTURE ++ "); see docs/NNUE.md");
    }
    if (NNUE_SOURCE.len != @sizeOf(NNUEWeights)) {
        @compileError(std.fmt.comptimePrint("Embedded network has {d} bytes but this build's architecture ({s}) needs {d}; check -Dnet, -Dbuckets and -Dhead", .{ NNUE_SOURCE.len, ARCHITECTURE, @sizeOf(NNUEWeights) }));
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

/// Replaces the active network's weights with `bytes`, a whole network file,
/// keeping its name. The active network is untouched on error. Callers must
/// refresh every position's accumulators afterwards. Not for wasm, which reads
/// the embedded network in place.
pub fn install(bytes: []const u8) NetworkError!void {
    try validate(bytes);
    @memcpy(std.mem.asBytes(&model_storage), bytes);
}

/// Replaces the active network with the file at `path`, or with the embedded
/// network for `EMBEDDED_NAME`. The active network is untouched on error.
/// Callers must refresh every position's accumulators afterwards.
/// Large enough to read a network of either architecture and name the problem.
const MAX_FILE_SIZE = @max(@sizeOf(Network(.single)), @sizeOf(Network(.multi)));

pub fn load(path: []const u8) !void {
    if (comptime !supports_eval_file) return error.Unsupported;
    if (std.mem.eql(u8, path, EMBEDDED_NAME)) {
        @memcpy(std.mem.asBytes(&model_storage), NNUE_SOURCE[0..@sizeOf(NNUEWeights)]);
        active_name = build_options.net_name;
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(MAX_FILE_SIZE + 1));
    defer platform.allocator.free(bytes);
    try install(bytes);

    const file_name = std.fs.path.basename(path);
    @memcpy(active_name_buf[0..file_name.len], file_name);
    active_name = active_name_buf[0..file_name.len];
}
