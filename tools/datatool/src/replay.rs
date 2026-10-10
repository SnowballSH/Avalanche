use crate::header;
use std::sync::atomic::Ordering;
use viriformat::chess::CHESS960;
use viriformat::chess::board::Board;
use viriformat::chess::chessmove::Move;
use viriformat::chess::piece::{Colour, Piece, PieceType};
use viriformat::chess::types::Rank;
use viriformat::dataformat::Game;

fn generate_castles_from_any_file() {
    CHESS960.store(true, Ordering::Relaxed);
}

fn side_to_move_can_capture_the_king(board: &Board) -> bool {
    let waiting_side = board.turn().flip();
    board.sq_attacked(board.king_sq(waiting_side), board.turn())
}

fn en_passant_square_is_behind_a_pawn_that_just_advanced(board: &Board) -> bool {
    let Some(en_passant) = board.ep_sq() else {
        return true;
    };
    let advanced_side = board.turn().flip();
    let passed_rank = match advanced_side {
        Colour::White => Rank::Three,
        Colour::Black => Rank::Six,
    };
    en_passant.rank() == passed_rank
        && board.piece_at(en_passant).is_none()
        && en_passant
            .pawn_push(advanced_side)
            .and_then(|square| board.piece_at(square))
            == Some(Piece::new(advanced_side, PieceType::Pawn))
}

fn start_position(game: &Game) -> Result<Board, String> {
    header::check(&game.initial_position.as_bytes())?;
    let board = game.initial_position();
    if side_to_move_can_capture_the_king(&board) {
        return Err(String::from("the side to move can capture the king"));
    }
    if !en_passant_square_is_behind_a_pawn_that_just_advanced(&board) {
        return Err(String::from(
            "en passant square without a pawn that just advanced past it",
        ));
    }
    Ok(board)
}

fn check_counters_fit_the_packed_format(board: &Board) -> Result<(), String> {
    if board.fifty_move_counter() == u8::MAX {
        return Err(format!("halfmove clock would pass {}", u8::MAX));
    }
    if u16::try_from(board.full_move_number()).is_err() {
        return Err(format!("fullmove number passes {}", u16::MAX));
    }
    Ok(())
}

pub fn visit_positions(
    game: &Game,
    mut visit: impl FnMut(&Board, Move, i32),
) -> Result<(), String> {
    let mut board =
        start_position(game).map_err(|problem| format!("invalid start position: {problem}"))?;
    generate_castles_from_any_file();
    for (ply, (mv, eval)) in game.moves.iter().enumerate() {
        check_counters_fit_the_packed_format(&board)
            .map_err(|problem| format!("{problem} at ply {ply}"))?;
        if !board.legal_moves().contains(mv) {
            return Err(format!("illegal move {mv:?} at ply {ply}"));
        }
        visit(&board, *mv, i32::from(eval.get()));
        board.make_move_simple(*mv);
    }
    Ok(())
}
