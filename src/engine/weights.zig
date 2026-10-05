const std = @import("std");
const build_options = @import("build_options");
const platform = @import("../platform.zig");
const large_memory = platform.large_memory;

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
pub const FORMAT_VERSION = 2;

/// Where the header keeps the network's L1 shift, a u32.
pub const L1_SHIFT_OFFSET = MAGIC.len + 12 * 4;

/// The header of a multi-layer network this build can run, with L1 shift 0:
/// the magic, then little-endian u32 fields. A file must match it byte for
/// byte except for its L1 shift, which is 0..7.
pub const MULTI_HEADER: [HEADER_SIZE]u8 = multi_header(0);

pub fn multi_header(shift: head_multi.L1Shift) [HEADER_SIZE]u8 {
    const fields = [_]u32{
        FORMAT_VERSION,
        @backingInt(Head.multi),
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
        shift,
    };
    var header: [HEADER_SIZE]u8 = @splat(0);
    @memcpy(header[0..MAGIC.len], MAGIC);
    for (fields, 0..) |field, i| {
        std.mem.writeInt(u32, header[MAGIC.len + i * 4 ..][0..4], field, .little);
    }
    return header;
}

/// The L1 shift of a validated header.
pub inline fn l1_shift(header: *const [HEADER_SIZE]u8) head_multi.L1Shift {
    return @truncate(header[L1_SHIFT_OFFSET]);
}

fn header_supported(header: *const [HEADER_SIZE]u8) bool {
    const shift = std.mem.readInt(u32, header[L1_SHIFT_OFFSET..][0..4], .little);
    if (shift > head_multi.L1_SHIFT_MAX) return false;
    return std.mem.eql(u8, header, &multi_header(@intCast(shift)));
}

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

/// The embedded network, aligned for inference: the only copy of it in the
/// executable. Wasm runs on it in place to avoid a second 25 MB in linear memory.
const embedded_model align(@alignOf(NNUEWeights)) = NNUE_SOURCE.*;

/// The network in use: the embedded image until `adopt` has copied a network
/// into large memory (docs/MEMORY.md).
pub var MODEL: *const NNUEWeights = @ptrCast(&embedded_model);

var model_block: ?*align(large_memory.ALIGNMENT) NNUEWeights = null;

/// Copies `bytes`, a validated network, into the block, allocated on first use
/// and never freed, and makes it the network in use.
fn adopt(bytes: *const [@sizeOf(NNUEWeights)]u8) void {
    const block = model_block orelse large_memory.create(NNUEWeights, "network") catch @panic("out of memory for the network");
    model_block = block;
    @memcpy(std.mem.asBytes(block), bytes);
    MODEL = block;
    prepare();
}

/// What the head derives from `MODEL`; `prepare` keeps it in step.
pub var prepared: switch (HEAD) {
    .single => void,
    .multi => head_multi.Prepared,
} = undefined;

/// Changes whenever another network becomes the active one; what was computed
/// with the previous network is recognised by an older value.
pub var generation: u32 = 0;

fn prepare() void {
    generation +%= 1;
    if (HEAD == .multi) prepared = .init(&MODEL.head, l1_shift(&MODEL.header));
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

pub const NetworkError = error{ NotANetwork, WrongSize, WrongArchitecture, UnsupportedHeader, OutputWeightOutOfRange, WeightOutOfRange, BiasOutOfRange };

/// Checks that `bytes` is a network of architecture `kind`: the exact
/// quantised layout with every weight inside the range inference assumes.
pub fn validate_as(comptime kind: Head, bytes: []const u8) NetworkError!void {
    const Net = Network(kind);
    switch (kind) {
        .single => if (has_magic(bytes)) return NetworkError.WrongArchitecture,
        .multi => {
            // Without the magic it is a single-layer network only if it has
            // exactly that size; anything else is not a network at all.
            if (!has_magic(bytes)) {
                return if (bytes.len == @sizeOf(Network(.single))) NetworkError.WrongArchitecture else NetworkError.NotANetwork;
            }
            if (bytes.len < HEADER_SIZE or !header_supported(bytes[0..HEADER_SIZE])) return NetworkError.UnsupportedHeader;
        },
    }
    if (bytes.len != @sizeOf(Net)) return NetworkError.WrongSize;
    const head_bytes = bytes[@offsetOf(Net, "head")..][0..@sizeOf(@FieldType(Net, "head"))];
    try switch (kind) {
        .single => head_single.validate(head_bytes),
        .multi => head_multi.validate(head_bytes),
    };
}

/// Evaluation of the active network in centipawns for the side to move, whose
/// accumulator is `own`.
pub inline fn evaluate(own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    return switch (HEAD) {
        .single => head_single.evaluate(&MODEL.head, own, opp, bucket),
        .multi => head_multi.evaluate(&MODEL.head, &prepared, own, opp, bucket),
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
            .multi => "it has the size of a single-layer network and no multi-layer header, but this build runs " ++ ARCHITECTURE ++ "; a single-layer network needs a -Dhead=single build",
        },
        NetworkError.NotANetwork => "it is not a network of either architecture: no multi-layer header, and not the size of a single-layer network",
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
    if (HEAD == .multi and NNUE_SOURCE.len >= HEADER_SIZE and !header_supported(NNUE_SOURCE[0..HEADER_SIZE])) {
        @compileError("The embedded multi-layer network's header does not match this build's architecture (" ++ ARCHITECTURE ++ "); see docs/NNUE.md");
    }
    if (NNUE_SOURCE.len != @sizeOf(NNUEWeights)) {
        @compileError(std.fmt.comptimePrint("Embedded network has {d} bytes but this build's architecture ({s}) needs {d}; check -Dnet, -Dbuckets and -Dhead", .{ NNUE_SOURCE.len, ARCHITECTURE, @sizeOf(NNUEWeights) }));
    }
}

pub fn do_nnue() void {
    validate(embedded_model[0..@sizeOf(NNUEWeights)]) catch |err| std.debug.panic("Embedded network is unusable: {s}", .{@errorName(err)});
    if (platform.is_wasm) prepare() else adopt(embedded_model[0..@sizeOf(NNUEWeights)]);
}

/// Large enough to read a network of either architecture, so that a file of
/// the other one is named as such rather than as too large.
pub const MAX_FILE_SIZE = @max(@sizeOf(Network(.single)), @sizeOf(Network(.multi)));

/// The whole file at `path`, for `install`. The caller frees it with
/// `platform.allocator`.
pub fn read_file(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(MAX_FILE_SIZE + 1));
}

/// Replaces the active network's weights with `bytes`, a whole network file,
/// keeping its name. Every network enters through here, so `bytes` gets the
/// checks of `validate`: this build's architecture, header and weight ranges.
/// The active network is untouched on error. Callers must refresh the
/// evaluation of every position they keep (`Position.refresh_evaluation`, or
/// setting it up again). Not for wasm, which reads the embedded network in place.
pub fn install(bytes: []const u8) NetworkError!void {
    try validate(bytes);
    adopt(bytes[0..@sizeOf(NNUEWeights)]);
}

/// Replaces the active network with the file at `path`, or with the embedded
/// network for `EMBEDDED_NAME`. The active network is untouched on error.
/// Callers must refresh the evaluation of every position they keep.
pub fn load(path: []const u8) !void {
    if (comptime !supports_eval_file) return error.Unsupported;
    if (std.mem.eql(u8, path, EMBEDDED_NAME)) {
        try install(embedded_model[0..@sizeOf(NNUEWeights)]);
        active_name = build_options.net_name;
        return;
    }
    const bytes = try read_file(path);
    defer platform.allocator.free(bytes);
    try install(bytes);

    const file_name = std.fs.path.basename(path);
    @memcpy(active_name_buf[0..file_name.len], file_name);
    active_name = active_name_buf[0..file_name.len];
}
