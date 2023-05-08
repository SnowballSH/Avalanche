// Pseudo-random Number Generator
pub const PRNG = struct {
    seed: u64,

    pub fn rand64(self: *PRNG) u64 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 7;
        self.seed ^= self.seed << 17;
        return self.seed;
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
