use std::ops::Range;

pub const OCCUPANCY: Range<usize> = 0..8;
pub const PIECES: Range<usize> = 8..24;
pub const SIDE_TO_MOVE_AND_EN_PASSANT: usize = 24;
pub const HALFMOVE_CLOCK: usize = 25;
pub const FULLMOVE_NUMBER: Range<usize> = 26..28;
pub const GAME_RESULT: usize = 30;

/// Checks the packed header before unpacking it: viriformat panics on headers it cannot decode.
pub fn check(packed: &[u8; 32]) -> Result<(), String> {
    const MAX_PIECES: u32 = 32;
    const UNMOVED_ROOK: u8 = 6;
    const KING: u8 = 5;
    const BLACK: u8 = 8;
    const WHITE_WIN: u8 = 2;
    let occupancy = u64::from_le_bytes(packed[OCCUPANCY].try_into().expect("8-byte slice"));
    let pieces = occupancy.count_ones();
    if pieces > MAX_PIECES {
        return Err(format!("{pieces} pieces on the board"));
    }
    let nibbles: Vec<u8> = (0..pieces as usize)
        .map(|i| (packed[PIECES.start + i / 2] >> (4 * (i & 1))) & 0x0f)
        .collect();
    if let Some(nibble) = nibbles.iter().find(|nibble| *nibble & 7 > UNMOVED_ROOK) {
        return Err(format!("unknown piece code {nibble}"));
    }
    let kings = |colour: u8| {
        nibbles
            .iter()
            .filter(|nibble| *nibble & 7 == KING && *nibble & BLACK == colour)
            .count()
    };
    if kings(0) != 1 || kings(BLACK) != 1 {
        return Err("start position needs exactly one king per side".to_owned());
    }
    if packed[FULLMOVE_NUMBER] == [0, 0] {
        return Err("fullmove number 0".to_owned());
    }
    let result = packed[GAME_RESULT];
    if result > WHITE_WIN {
        return Err(format!("unknown game result {result}"));
    }
    Ok(())
}
