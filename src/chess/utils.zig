const std = @import("std");

// Pseudo-random Number Generator
pub const PRNG = struct {
    seed: u128,

    pub fn rand64(self: *PRNG) u64 {
        var x = self.seed;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed = x;
        var r = @truncate(u64, x);
        r = r ^ @truncate(u64, x >> 64);
        return r;
    }

    // Less bits
    pub fn sparse_rand64(self: *PRNG) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }

    pub fn new(seed: u128) PRNG {
        return PRNG{ .seed = seed };
    }
};

pub fn first_index(comptime T: type, arr: []const T, val: T) ?usize {
    var i: usize = 0;
    var end = arr.len;
    while (i < end) : (i += 1) {
        if (arr[i] == val) {
            return i;
        }
    }
    return null;
}
