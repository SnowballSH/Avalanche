//! The compressed value stream of one subtable: canonical Huffman codes over symbols that each
//! expand to a pair of symbols, down to single values.

const std = @import("std");

const MAX_SYMBOLS = 4096;

pub const Kind = enum { wdl, dtz };

pub const PairsData = struct {
    /// Empty for a table that holds one value.
    index_table: []const u8 = &.{},
    size_table: []const u8 = &.{},
    data: []const u8 = &.{},
    /// The first code value of each code length, from `min_len` on, as little-endian u16s.
    offset: []const u8 = &.{},
    sym_pat: []const u8 = &.{},
    sym_len: []const u8 = &.{},
    /// The lowest code of each length, left-aligned in 64 bits, from `min_len` on.
    base: []const u64 = &.{},
    block_size: u6 = 0,
    /// 0 for a table that holds one value.
    idx_bits: u6 = 0,
    min_len: u8 = 0,
    const_value: [2]u8 = .{ 0, 0 },

    /// The two bytes of the value at `idx`.
    pub fn decompress(self: *const PairsData, idx: u64) [2]u8 {
        if (self.idx_bits == 0) return self.const_value;

        const main_idx: usize = @intCast(idx >> self.idx_bits);
        var lit_idx: i64 = @as(i64, @intCast(idx & ((@as(u64, 1) << self.idx_bits) - 1))) -
            (@as(i64, 1) << (self.idx_bits - 1));
        const entry = self.index_table[6 * main_idx ..][0..6];
        var block: usize = std.mem.readInt(u32, entry[0..4], .little);
        lit_idx += std.mem.readInt(u16, entry[4..6], .little);

        if (lit_idx < 0) {
            while (lit_idx < 0) {
                block -= 1;
                lit_idx += @as(i64, self.block_length(block)) + 1;
            }
        } else {
            while (lit_idx > self.block_length(block)) {
                lit_idx -= @as(i64, self.block_length(block)) + 1;
                block += 1;
            }
        }

        var cursor = block << self.block_size;
        var code = std.mem.readInt(u64, self.data[cursor..][0..8], .big);
        cursor += 8;
        var bit_count: u32 = 0;
        var sym: usize = undefined;
        while (true) {
            var len: usize = 0;
            while (code < self.base[len]) len += 1;
            const length: u6 = @intCast(self.min_len + len);
            sym = std.mem.readInt(u16, self.offset[2 * len ..][0..2], .little) +
                @as(usize, @intCast((code - self.base[len]) >> @intCast(64 - @as(u7, length))));
            if (lit_idx < @as(i64, self.sym_len[sym]) + 1) break;
            lit_idx -= @as(i64, self.sym_len[sym]) + 1;
            code <<= length;
            bit_count += length;
            if (bit_count >= 32) {
                bit_count -= 32;
                const next: u64 = std.mem.readInt(u32, self.data[cursor..][0..4], .big);
                cursor += 4;
                code |= next << @intCast(bit_count);
            }
        }

        while (self.sym_len[sym] != 0) {
            const w = self.sym_pat[3 * sym ..][0..3];
            const left = (@as(usize, w[1] & 0x0f) << 8) | w[0];
            if (lit_idx < @as(i64, self.sym_len[left]) + 1) {
                sym = left;
            } else {
                lit_idx -= @as(i64, self.sym_len[left]) + 1;
                sym = (@as(usize, w[2]) << 4) | (w[1] >> 4);
            }
        }
        const w = self.sym_pat[3 * sym ..][0..2];
        return w.*;
    }

    inline fn block_length(self: *const PairsData, block: usize) u16 {
        return std.mem.readInt(u16, self.size_table[2 * block ..][0..2], .little);
    }
};

/// The lengths of the three regions that follow the headers of a subtable: index, sizes, data.
pub const Sizes = [3]usize;

pub const Setup = struct {
    pairs: PairsData,
    sizes: Sizes,
    flags: u8,
};

pub const Error = error{ OutOfMemory, CorruptTable };

/// Reads the header of one subtable at `cursor.*` in `file` and moves the cursor past it.
/// `sym_len` and `base` are allocated with `arena`.
pub fn setup(arena: std.mem.Allocator, file: []const u8, cursor: *usize, tb_size: u64, kind: Kind) Error!Setup {
    const header = file[cursor.*..];
    const flags = header[0];
    if (flags & 0x80 != 0) {
        cursor.* += 2;
        return .{
            .pairs = .{ .const_value = .{ if (kind == .wdl) header[1] else 0, 0 } },
            .sizes = .{ 0, 0, 0 },
            .flags = flags,
        };
    }

    const block_size = header[1];
    const idx_bits = header[2];
    const real_num_blocks = std.mem.readInt(u32, header[4..8], .little);
    const num_blocks = @as(u64, real_num_blocks) + header[3];
    const max_len = header[8];
    const min_len = header[9];
    if (block_size > 63 or idx_bits == 0 or idx_bits > 63 or min_len == 0 or max_len < min_len or max_len > 63)
        return error.CorruptTable;
    const h: usize = max_len - min_len + 1;
    const num_syms = std.mem.readInt(u16, header[10 + 2 * h ..][0..2], .little);
    if (num_syms >= MAX_SYMBOLS) return error.CorruptTable;

    const offset = header[10..][0 .. 2 * h];
    const sym_pat = header[12 + 2 * h ..][0 .. 3 * @as(usize, num_syms)];
    cursor.* += 12 + 2 * h + 3 * @as(usize, num_syms) + (num_syms & 1);

    const sym_len = try arena.alloc(u8, num_syms);
    var visited: [MAX_SYMBOLS]bool = undefined;
    @memset(visited[0..num_syms], false);
    for (0..num_syms) |s| {
        if (!visited[s]) try calc_sym_len(sym_len, sym_pat, @intCast(s), &visited);
    }

    const base = try arena.alloc(u64, h);
    base[h - 1] = 0;
    var i = h - 1;
    while (i > 0) {
        i -= 1;
        const here = std.mem.readInt(u16, offset[2 * i ..][0..2], .little);
        const next = std.mem.readInt(u16, offset[2 * (i + 1) ..][0..2], .little);
        base[i] = (base[i + 1] +% here -% next) / 2;
    }
    for (base, 0..) |*b, len| b.* = std.math.shl(u64, b.*, 64 - (min_len + len));

    const num_indices = (tb_size + (@as(u64, 1) << @intCast(idx_bits)) - 1) >> @intCast(idx_bits);
    return .{
        .pairs = .{
            .offset = offset,
            .sym_pat = sym_pat,
            .sym_len = sym_len,
            .base = base,
            .block_size = @intCast(block_size),
            .idx_bits = @intCast(idx_bits),
            .min_len = min_len,
        },
        .sizes = .{
            @intCast(6 * num_indices),
            @intCast(2 * num_blocks),
            @as(usize, real_num_blocks) << @intCast(block_size),
        },
        .flags = flags,
    };
}

fn calc_sym_len(sym_len: []u8, sym_pat: []const u8, s: u12, visited: *[MAX_SYMBOLS]bool) Error!void {
    const w = sym_pat[3 * @as(usize, s) ..][0..3];
    const right = (@as(u12, w[2]) << 4) | (w[1] >> 4);
    if (right == 0x0fff) {
        sym_len[s] = 0;
    } else {
        const left = (@as(u12, w[1] & 0x0f) << 8) | w[0];
        if (left >= sym_len.len or right >= sym_len.len) return error.CorruptTable;
        if (!visited[left]) try calc_sym_len(sym_len, sym_pat, left, visited);
        if (!visited[right]) try calc_sym_len(sym_len, sym_pat, right, visited);
        sym_len[s] = sym_len[left] +% sym_len[right] +% 1;
    }
    visited[s] = true;
}
