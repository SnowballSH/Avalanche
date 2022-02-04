const std = @import("std");
const Position = @import("./board/position.zig");
const Perft = @import("./uci/perft.zig");
const Magic = @import("./board/magic.zig");
const Zobrist = @import("./board/zobrist.zig");
const TT = @import("./cache/tt.zig");
const Uci = @import("./uci/uci.zig");
const HCE = @import("./evaluation/hce.zig");
const Search = @import("./search/search.zig");

pub fn main() !void {
    Zobrist.init_zobrist();
    Magic.init_magic();

    defer TT.TTArena.deinit();

    std.debug.print("Avalanche 0.0 by SnowballSH\n", .{});

    // https://www.chessprogramming.org/Perft_Results
    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    const s = "4nrk1/1pq2p1p/r3p1p1/7Q/3B1P2/3R4/1PP3PP/2K4R w - - 0 1";
    // const s = Position.STARTPOS;
    var pos = Position.new_position_by_fen(s);
    defer pos.deinit();
    pos.display();

    // _ = try Perft.perft_root(&pos, 5);

    var searcher = Search.new_searcher();
    std.debug.print("Evaluation: {}\n", .{HCE.evaluate(&pos)});

    const depth = 6;

    var dp: u8 = 1;
    while (dp <= depth) {
        var score = searcher.negamax(&pos, -Search.INF, Search.INF, dp);
        if (score > 0 and Search.INF - score < 50) {
            std.debug.print(
                "info depth {} score mate {} pv",
                .{
                    dp,
                    Search.INF - score,
                },
            );
        } else if (score < 0 and Search.INF + score < 50) {
            std.debug.print(
                "info depth {} score mate -{} pv",
                .{
                    dp,
                    Search.INF + score,
                },
            );
        } else {
            std.debug.print(
                "info depth {} score cp {} pv",
                .{
                    dp,
                    score,
                },
            );
        }

        var i: usize = 0;
        while (i < dp) {
            if (searcher.pv_array[i] == 0) {
                break;
            }
            std.debug.print(" {s}", .{Uci.move_to_uci(searcher.pv_array[i])});

            i += 1;
        }
        std.debug.print("\n", .{});
        dp += 1;
    }
}
