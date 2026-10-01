use std::f32::consts::PI;

use bullet::trainer::schedule::{
    ansi,
    lr::{ConstantLR, CosineDecayLR, LrScheduler},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LrKind {
    Cosine,
    CosineLegacy,
    Constant,
}

impl LrKind {
    pub const SUPPORTED: &str = "cosine (default), cosine-legacy, constant";

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "cosine" => Some(Self::Cosine),
            "cosine-legacy" => Some(Self::CosineLegacy),
            "constant" => Some(Self::Constant),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Cosine => "cosine",
            Self::CosineLegacy => "cosine-legacy",
            Self::Constant => "constant",
        }
    }
}

/// bullet's cosine decay as it was before jw1912/bullet#553: progress is `superbatch / final_superbatch`
/// rather than `(superbatch - 1) / (final_superbatch - 1)`, so superbatch 1 already sits below `initial_lr`.
#[derive(Clone, Debug)]
pub struct LegacyCosineDecayLR {
    pub initial_lr: f32,
    pub final_lr: f32,
    pub final_superbatch: usize,
}

impl LrScheduler for LegacyCosineDecayLR {
    fn lr(&self, _batch: usize, superbatch: usize) -> f32 {
        if superbatch >= self.final_superbatch {
            return self.final_lr;
        }

        let progress = superbatch as f32 / self.final_superbatch as f32;
        let lambda = 1.0 - 0.5 * (1.0 + (PI * progress).cos());
        self.initial_lr + lambda * (self.final_lr - self.initial_lr)
    }

    fn colourful(&self) -> String {
        format!(
            "start at {} and legacy cosine decay to {} at superbatch {}",
            ansi(self.initial_lr, 31),
            ansi(self.final_lr, 31),
            ansi(self.final_superbatch, 31),
        )
    }
}

#[derive(Clone, Debug)]
pub enum BaseLr {
    Cosine(CosineDecayLR),
    CosineLegacy(LegacyCosineDecayLR),
    Constant(ConstantLR),
}

impl BaseLr {
    pub fn new(kind: LrKind, initial_lr: f32, final_lr: f32, final_superbatch: usize) -> Self {
        match kind {
            LrKind::Cosine => Self::Cosine(CosineDecayLR {
                initial_lr,
                final_lr,
                final_superbatch,
            }),
            LrKind::CosineLegacy => Self::CosineLegacy(LegacyCosineDecayLR {
                initial_lr,
                final_lr,
                final_superbatch,
            }),
            LrKind::Constant => Self::Constant(ConstantLR { value: initial_lr }),
        }
    }
}

impl LrScheduler for BaseLr {
    fn lr(&self, batch: usize, superbatch: usize) -> f32 {
        match self {
            Self::Cosine(schedule) => schedule.lr(batch, superbatch),
            Self::CosineLegacy(schedule) => schedule.lr(batch, superbatch),
            Self::Constant(schedule) => schedule.lr(batch, superbatch),
        }
    }

    fn colourful(&self) -> String {
        match self {
            Self::Cosine(schedule) => schedule.colourful(),
            Self::CosineLegacy(schedule) => schedule.colourful(),
            Self::Constant(schedule) => schedule.colourful(),
        }
    }
}

/// Scales `inner` by a factor rising linearly, batch by batch, from `1 / warmup batches` to 1 over the
/// first `warmup_superbatches`. bullet's own `lr::Warmup` cannot be used: it only acts inside superbatch 1
/// and divides by the batches left, which is not a linear ramp.
#[derive(Clone, Debug)]
pub struct LinearWarmup<LR> {
    pub inner: LR,
    pub warmup_superbatches: usize,
    pub batches_per_superbatch: usize,
}

impl<LR: LrScheduler> LrScheduler for LinearWarmup<LR> {
    fn lr(&self, batch: usize, superbatch: usize) -> f32 {
        let base_lr = self.inner.lr(batch, superbatch);
        let warmup_batches = self.warmup_superbatches * self.batches_per_superbatch;
        let batches_done = superbatch.saturating_sub(1) * self.batches_per_superbatch + batch;
        if batches_done >= warmup_batches {
            return base_lr;
        }
        base_lr * (batches_done + 1) as f32 / warmup_batches as f32
    }

    fn colourful(&self) -> String {
        if self.warmup_superbatches == 0 {
            return self.inner.colourful();
        }
        format!(
            "{}, linear warmup over {} superbatches",
            self.inner.colourful(),
            ansi(self.warmup_superbatches, 31)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INITIAL: f32 = 0.001;
    const FINAL: f32 = 1e-7;
    const SUPERBATCHES: usize = 40;

    fn warmed(kind: LrKind, warmup_superbatches: usize) -> LinearWarmup<BaseLr> {
        LinearWarmup {
            inner: BaseLr::new(kind, INITIAL, FINAL, SUPERBATCHES),
            warmup_superbatches,
            batches_per_superbatch: 100,
        }
    }

    #[test]
    fn legacy_cosine_starts_below_initial_and_ends_at_final() {
        let legacy = BaseLr::new(LrKind::CosineLegacy, INITIAL, FINAL, SUPERBATCHES);
        let expected = INITIAL + (1.0 - 0.5 * (1.0 + (PI / 40.0).cos())) * (FINAL - INITIAL);
        assert_eq!(legacy.lr(0, 1), expected);
        assert!(legacy.lr(0, 1) < INITIAL);
        assert_eq!(legacy.lr(0, SUPERBATCHES), FINAL);
    }

    #[test]
    fn current_cosine_starts_at_initial() {
        let cosine = BaseLr::new(LrKind::Cosine, INITIAL, FINAL, SUPERBATCHES);
        assert_eq!(cosine.lr(0, 1), INITIAL);
        assert_eq!(cosine.lr(0, SUPERBATCHES), FINAL);
    }

    #[test]
    fn no_warmup_leaves_the_schedule_untouched() {
        let schedule = warmed(LrKind::CosineLegacy, 0);
        for superbatch in 1..=SUPERBATCHES {
            assert_eq!(schedule.lr(0, superbatch), schedule.inner.lr(0, superbatch));
        }
    }

    #[test]
    fn warmup_ramps_linearly_then_follows_the_schedule() {
        let schedule = warmed(LrKind::Constant, 2);
        assert_eq!(schedule.lr(0, 1), INITIAL / 200.0);
        assert_eq!(schedule.lr(99, 1), INITIAL * 100.0 / 200.0);
        assert_eq!(schedule.lr(99, 2), INITIAL);
        assert_eq!(schedule.lr(0, 3), INITIAL);
    }
}
