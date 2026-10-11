const std = @import("std");
const build_options = @import("build_options");
const platform = @import("../platform.zig");
const large_memory = platform.large_memory;

const NNUE_SOURCE = @embedFile("nnue");

pub const arch = @import("nnue/arch.zig");
pub const head_single = @import("nnue/head_single.zig");
pub const head_multi = @import("nnue/head_multi.zig");

pub const NUM_INPUT_BUCKETS: usize = build_options.input_buckets;

pub const INPUT_SIZE: usize = arch.FEATURES_PER_BUCKET * NUM_INPUT_BUCKETS;
pub const HIDDEN_SIZE: usize = arch.HIDDEN_SIZE;
pub const OUTPUT_SIZE: usize = arch.OUTPUT_SIZE;

pub const Head = enum { single, multi };

pub const MAGIC = "AVALNNUE";
pub const HEADER_SIZE = 64;
pub const FORMAT_VERSION = 2;

const HeaderField = enum {
    format_version,
    head,
    input_buckets,
    accumulator_width,
    output_buckets,
    l1_outputs,
    l2_outputs,
    qa,
    ft_shift,
    act_bits,
    weight_bits,
    scale,
    l1_shift,
    reserved,
};

const HeaderFields = std.enums.EnumArray(HeaderField, u32);

comptime {
    std.debug.assert(MAGIC.len + HeaderFields.len * @sizeOf(u32) == HEADER_SIZE);
}

fn header_offset(field: HeaderField) usize {
    return MAGIC.len + HeaderFields.Indexer.indexOf(field) * @sizeOf(u32);
}

pub const L1_SHIFT_OFFSET = header_offset(.l1_shift);

pub fn multi_header(shift: head_multi.L1Shift) [HEADER_SIZE]u8 {
    var fields: HeaderFields = .init(.{
        .format_version = FORMAT_VERSION,
        .head = @backingInt(Head.multi),
        .input_buckets = NUM_INPUT_BUCKETS,
        .accumulator_width = HIDDEN_SIZE,
        .output_buckets = OUTPUT_SIZE,
        .l1_outputs = head_multi.L1_SIZE,
        .l2_outputs = head_multi.L2_SIZE,
        .qa = arch.QA,
        .ft_shift = head_multi.FT_SHIFT,
        .act_bits = head_multi.ACT_BITS,
        .weight_bits = head_multi.WEIGHT_BITS,
        .scale = arch.SCALE,
        .l1_shift = shift,
        .reserved = 0,
    });
    var header: [HEADER_SIZE]u8 = undefined;
    @memcpy(header[0..MAGIC.len], MAGIC);
    var stored = fields.iterator();
    while (stored.next()) |field| {
        std.mem.writeInt(u32, header[header_offset(field.key)..][0..@sizeOf(u32)], field.value.*, .little);
    }
    return header;
}

fn stored_l1_shift(header: *const [HEADER_SIZE]u8) u32 {
    return std.mem.readInt(u32, header[L1_SHIFT_OFFSET..][0..@sizeOf(u32)], .little);
}

pub inline fn l1_shift(header: *const [HEADER_SIZE]u8) head_multi.L1Shift {
    return @intCast(stored_l1_shift(header));
}

fn header_supported(header: *const [HEADER_SIZE]u8) bool {
    const shift = stored_l1_shift(header);
    if (shift > head_multi.L1_SHIFT_MAX) return false;
    return std.mem.eql(u8, header, &multi_header(@intCast(shift)));
}

fn has_magic(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, MAGIC);
}

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

const EMBEDDED_MODEL align(@alignOf(NNUEWeights)) = NNUE_SOURCE.*;
const EMBEDDED_BYTES: *align(@alignOf(NNUEWeights)) const [@sizeOf(NNUEWeights)]u8 = EMBEDDED_MODEL[0..@sizeOf(NNUEWeights)];

pub var MODEL: *const NNUEWeights = @ptrCast(EMBEDDED_BYTES);

var model_block: ?*align(large_memory.ALIGNMENT) NNUEWeights = null;

fn adopt(bytes: *const [@sizeOf(NNUEWeights)]u8) void {
    const block = model_block orelse large_memory.create(NNUEWeights, "network") catch platform.fatal("out of memory: network", .{});
    model_block = block;
    @memcpy(std.mem.asBytes(block), bytes);
    MODEL = block;
    prepare();
}

pub var prepared: switch (HEAD) {
    .single => void,
    .multi => head_multi.Prepared,
} = undefined;

pub var generation: u32 = 0;

fn prepare() void {
    generation +%= 1;
    if (HEAD == .multi) prepared = .init(&MODEL.head, l1_shift(&MODEL.header));
}

pub const EMBEDDED_NAME = "<embedded>";

pub const ARCHITECTURE = std.fmt.comptimePrint("{d}x{d}->{d}->{s}", .{ arch.FEATURES_PER_BUCKET, NUM_INPUT_BUCKETS, HIDDEN_SIZE, head.DESCRIPTION });

var active_name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
var active_name: []const u8 = build_options.net_name;

pub fn active_network() []const u8 {
    return active_name;
}

pub const supports_eval_file = !platform.is_wasm;

pub const NetworkError = error{ NotANetwork, WrongSize, WrongArchitecture, UnsupportedHeader, OutputWeightOutOfRange, WeightOutOfRange, BiasOutOfRange };

pub fn validate_as(comptime kind: Head, bytes: []const u8) NetworkError!void {
    const Net = Network(kind);
    switch (kind) {
        .single => if (has_magic(bytes)) return NetworkError.WrongArchitecture,
        .multi => {
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

pub inline fn evaluate(own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    return switch (HEAD) {
        .single => head_single.evaluate(&MODEL.head, own, opp, bucket),
        .multi => head_multi.evaluate(&MODEL.head, &prepared, own, opp, bucket),
    };
}

pub fn validate(bytes: []const u8) NetworkError!void {
    return validate_as(HEAD, bytes);
}

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

pub fn use_embedded() void {
    validate(EMBEDDED_BYTES) catch |err| platform.fatal("embedded network is unusable: {s}", .{@errorName(err)});
    if (platform.is_wasm) prepare() else adopt(EMBEDDED_BYTES);
}

pub const MAX_FILE_SIZE = @max(@sizeOf(Network(.single)), @sizeOf(Network(.multi)));

pub fn read_file(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(MAX_FILE_SIZE + 1));
}

pub fn install(bytes: []const u8) NetworkError!void {
    try validate(bytes);
    adopt(bytes[0..@sizeOf(NNUEWeights)]);
}

pub fn load(path: []const u8) !void {
    if (comptime !supports_eval_file) return error.Unsupported;
    if (std.mem.eql(u8, path, EMBEDDED_NAME)) {
        try install(EMBEDDED_BYTES);
        active_name = build_options.net_name;
        return;
    }
    const bytes = try read_file(path);
    defer platform.allocator.free(bytes);
    try install(bytes);

    const file_name = std.Io.Dir.path.basename(path);
    @memcpy(active_name_buf[0..file_name.len], file_name);
    active_name = active_name_buf[0..file_name.len];
}
