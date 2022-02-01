pub const std = @import("std");

pub const MB: usize = 1 << 20;

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
