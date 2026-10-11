pub const PRNG = struct {
    seed: u128,

    pub fn rand64(self: *PRNG) u64 {
        var x = self.seed;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed = x;
        var r = @as(u64, @truncate(x));
        r = r ^ @as(u64, @truncate(x >> 64));
        return r;
    }

    pub fn new(seed: u128) PRNG {
        return PRNG{ .seed = seed };
    }
};
