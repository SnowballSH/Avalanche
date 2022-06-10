// Pseudo-random Number Generator
pub const PRNG = struct {
    seed: u64,

    pub fn rand64(self: *PRNG) u64 {
        self.seed ^= self.seed >> 12;
        self.seed ^= self.seed << 25;
        self.seed ^= self.seed >> 27;
        return self.seed *% 2685821657736338717;
    }

    // Less bits
    pub fn sparse_rand64(self: *PRNG) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }

    pub fn new(seed: u64) PRNG {
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
