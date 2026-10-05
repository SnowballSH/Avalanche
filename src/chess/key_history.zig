const std = @import("std");

/// Keys of the positions of a game followed by those of the line being
/// searched, oldest first, in a buffer that never grows: a full history
/// refuses an `append`. See "Draw detection" in docs/BOARD.md.
pub const KeyHistory = struct {
    items: []u64,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!KeyHistory {
        const buffer = try allocator.alloc(u64, capacity);
        return .{ .items = buffer[0..0], .capacity = capacity };
    }

    pub fn deinit(self: *KeyHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.items.ptr[0..self.capacity]);
        self.* = undefined;
    }

    pub inline fn append(self: *KeyHistory, key: u64) error{Overflow}!void {
        if (self.items.len == self.capacity) return error.Overflow;
        self.items.ptr[self.items.len] = key;
        self.items.len += 1;
    }

    pub inline fn pop(self: *KeyHistory) ?u64 {
        if (self.items.len == 0) return null;
        const key = self.items[self.items.len - 1];
        self.items.len -= 1;
        return key;
    }

    pub fn append_slice(self: *KeyHistory, keys: []const u64) error{Overflow}!void {
        if (keys.len > self.capacity - self.items.len) return error.Overflow;
        @memcpy(self.items.ptr[self.items.len..][0..keys.len], keys);
        self.items.len += keys.len;
    }

    pub fn clear(self: *KeyHistory) void {
        self.items.len = 0;
    }
};

test "key history: appends, pops and refuses to overflow" {
    var history = try KeyHistory.init(std.testing.allocator, 4);
    defer history.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), history.pop());
    try history.append(1);
    try history.append_slice(&.{ 2, 3 });
    try std.testing.expectError(error.Overflow, history.append_slice(&.{ 9, 9 }));
    try history.append(4);
    try std.testing.expectError(error.Overflow, history.append(5));
    try std.testing.expectError(error.Overflow, history.append_slice(&.{5}));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, history.items);

    try std.testing.expectEqual(@as(?u64, 4), history.pop());
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, history.items);
    history.clear();
    try std.testing.expectEqual(@as(usize, 0), history.items.len);
    try history.append(7);
    try std.testing.expectEqualSlices(u64, &.{7}, history.items);
}
