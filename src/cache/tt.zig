pub const std = @import("std");

pub const MB: usize = 1 << 20;
pub const KB: usize = 1 << 10;

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub const TTFlag = enum(u3) {
    Invalid,
    Upper,
    Lower,
    Exact,
};

pub const TTData = struct {
    hash: u64,
    depth: u8,
    score: i16,
    flag: TTFlag,
    bm: u24,
};

pub const TT = struct {
    data: std.ArrayList(TTData),
    size: usize,

    pub fn new(mb: usize) TT {
        var tt = TT{
            .data = std.ArrayList(TTData).init(TTArena.allocator()),
            .size = @divFloor(mb * MB, @sizeOf(TTData)),
        };

        tt.data.ensureTotalCapacity(tt.size) catch {};
        tt.data.expandToCapacity();

        std.debug.print("Allocated {} MB, {} items for TT\n", .{ mb, tt.size });

        return tt;
    }

    pub fn reset(self: *TT) void {
        for (self.data.items) |*ptr| {
            ptr.* = std.mem.zeroes(TTData);
        }
    }

    pub fn deinit(self: *TT) void {
        self.data.deinit();
    }

    pub fn probe(self: *TT, hash: u64) ?*TTData {
        var entry = &self.data.items[hash % self.size];

        if (entry.hash == hash and entry.flag != TTFlag.Invalid and entry.depth != 0 and entry.bm != 0) {
            return entry;
        }

        return null;
    }

    pub fn insert(self: *TT, hash: u64, depth: u8, score: i16, flag: TTFlag, bm: u24) void {
        self.data.items[hash % self.size] = TTData{
            .hash = hash,
            .depth = depth,
            .score = score,
            .flag = flag,
            .bm = bm,
        };
    }
};
