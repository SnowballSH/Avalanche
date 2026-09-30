/// Checks the packed header before unpacking it: viriformat panics on headers it cannot decode.
pub fn check(packed: &[u8; 32]) -> Result<(), String> {
    const MAX_PIECES: u32 = 32;
    const UNMOVED_ROOK: u8 = 6;
    const KING: u8 = 5;
    const BLACK: u8 = 8;
    let occupancy = u64::from_le_bytes(packed[..8].try_into().expect("8-byte slice"));
    let pieces = occupancy.count_ones();
    if pieces > MAX_PIECES {
        return Err(format!("{pieces} pieces on the board"));
    }
    let nibbles: Vec<u8> = (0..pieces as usize)
        .map(|i| (packed[8 + i / 2] >> (4 * (i & 1))) & 0x0f)
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
    Ok(())
}
