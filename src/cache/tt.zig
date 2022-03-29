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

pub const TTData = packed struct {
    hash: u64,
    depth: u8,
    age: u16,
    score: i16,
    bm: u24,
    flag: TTFlag,
};

pub const TT = struct {
    data: std.ArrayList(TTData),
    size: usize,
    age: u16,

    pub fn new(mb: usize) TT {
        var tt = TT{
            .data = std.ArrayList(TTData).init(TTArena.allocator()),
            .size = mb * MB / @sizeOf(TTData),
            .age = 0,
        };

        tt.data.ensureTotalCapacity(tt.size) catch {};
        tt.data.expandToCapacity();

        std.debug.print("Allocated {} KB, {} items for TT\n", .{ tt.size * @sizeOf(TTData) / KB, tt.size });

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
        const data = self.data.items[hash % self.size];
        var replace: bool = false;
        if (data.hash == 0) {
            replace = true;
        } else if (data.hash == hash) {
            replace = (depth >= data.depth - 3) or (data.flag == TTFlag.Exact);
        } else {
            replace = (data.age != self.age) or (depth >= data.depth);
        }
        if (replace) {
            self.data.items[hash % self.size] = TTData{
                .hash = hash,
                .depth = depth,
                .score = score,
                .flag = flag,
                .bm = bm,
                .age = self.age,
            };
        }
    }

    pub fn age(self: *TT) void {
        self.age +%= 1;
    }
};
