const std = @import("std");
const Position = @import("../board/position.zig");
const Search = @import("../search/search.zig");

pub const UciInterface = struct {
    position: Position.Position,

    pub fn new() UciInterface {
        return UciInterface{
            .position = Position.new_position_by_fen(Position.STARTPOS),
        };
    }

    pub fn main_loop(self: *UciInterface) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        var command_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer command_arena.deinit();

        var searcher = Search.Searcher.new_searcher();

        _ = try stdout.writeAll("Avalanche 0.0 by SnowballSH\n");

        self.position = Position.new_position_by_fen(Position.STARTPOS);

        out: while (true) {
            // The command will probably be less than 512 characters
            var line = try stdin.readUntilDelimiterOrEofAlloc(command_arena.allocator(), '\n', 512);
            if (line == null) {
                break;
            }
            defer command_arena.allocator().free(line.?);

            var tokens = std.mem.split(u8, line.?, " ");
            var token = tokens.next();
            if (token == null) {
                break;
            }

            if (std.mem.eql(u8, token.?, "quit")) {
                break :out;
            } else if (std.mem.eql(u8, token.?, "uci")) {
                _ = try stdout.write("id name Avalanche 0.0\n");
                _ = try stdout.write("id author SnowballSH\n");
                _ = try stdout.writeAll("uciok\n");
            } else if (std.mem.eql(u8, token.?, "isready")) {
                _ = try stdout.writeAll("readyok\n");
            } else if (std.mem.eql(u8, token.?, "go")) {
                searcher.iterative_deepening(&self.position, std.time.ns_per_ms * 3000);
            }
        }
    }
};
