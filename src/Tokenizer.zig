const std = @import("std");
const Position = @import("Sheet.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const HeaderList = @import("header_list.zig").HeaderList;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Tokenizer = @This();

bytes: []const u8,
pos: u32 = 0,

const log = std.log.scoped(.tokenizer);

const State = enum {
    start,
    integer_number,
    decimal_number,
    builtin,
    word,
    cell_address,
    single_string_literal,
    double_string_literal,
};

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub fn text(ast: Token, source: []const u8) []const u8 {
        return source[ast.start..ast.end];
    }

    pub const Tag = enum {
        number,
        equals_sign,

        plus,
        minus,
        asterisk,
        forward_slash,
        percent,
        comma,
        colon,

        lparen,
        rparen,

        column_name,
        cell_name,
        builtin,

        single_string_literal,
        double_string_literal,

        keyword_let,
        keyword_label,

        eof,
        invalid,
    };
};

const keywords = std.ComptimeStringMap(Token.Tag, .{
    .{ "label", .keyword_label },
    .{ "let", .keyword_let },
});

pub fn init(bytes: []const u8) Tokenizer {
    return .{
        .bytes = bytes,
    };
}

pub fn next(tokenizer: *Tokenizer) ?Token {
    var start = tokenizer.pos;

    var state: State = .start;
    var tag = Token.Tag.eof;

    while (tokenizer.pos < tokenizer.bytes.len) : (tokenizer.pos += 1) {
        const c = tokenizer.bytes[tokenizer.pos];

        switch (state) {
            .start => switch (c) {
                '0'...'9' => {
                    state = .integer_number;
                    tag = .number;
                },
                '.' => {
                    state = .decimal_number;
                    tag = .number;
                },
                '=' => {
                    tag = .equals_sign;
                    tokenizer.pos += 1;
                    break;
                },
                ' ', '\t', '\r', '\n' => {
                    start += 1;
                },
                'a'...'z', 'A'...'Z' => {
                    state = .word;
                },
                '@' => {
                    state = .builtin;
                    tag = .builtin;
                    start += 1;
                },
                ',' => {
                    tag = .comma;
                    tokenizer.pos += 1;
                    break;
                },
                '+' => {
                    tag = .plus;
                    tokenizer.pos += 1;
                    break;
                },
                '-' => {
                    tag = .minus;
                    tokenizer.pos += 1;
                    break;
                },
                '*' => {
                    tag = .asterisk;
                    tokenizer.pos += 1;
                    break;
                },
                '/' => {
                    tag = .forward_slash;
                    tokenizer.pos += 1;
                    break;
                },
                '%' => {
                    tag = .percent;
                    tokenizer.pos += 1;
                    break;
                },
                '(' => {
                    tag = .lparen;
                    tokenizer.pos += 1;
                    break;
                },
                ')' => {
                    tag = .rparen;
                    tokenizer.pos += 1;
                    break;
                },
                ':' => {
                    tag = .colon;
                    tokenizer.pos += 1;
                    break;
                },
                '\'' => {
                    tag = .single_string_literal;
                    state = .single_string_literal;
                },
                '"' => {
                    tag = .double_string_literal;
                    state = .single_string_literal;
                },
                else => {
                    defer tokenizer.pos += 1;
                    return .{
                        .tag = .invalid,
                        .start = start,
                        .end = tokenizer.pos,
                    };
                },
            },
            .integer_number => switch (c) {
                '0'...'9', '_' => {},
                '.' => state = .decimal_number,
                else => break,
            },
            .decimal_number => switch (c) {
                '0'...'9', '_' => {},
                else => break,
            },
            .word => switch (c) {
                'a'...'z', 'A'...'Z' => {},
                '0'...'9', '_' => {
                    state = .cell_address;
                    tag = .cell_name;
                },
                else => break,
            },
            .cell_address => switch (c) {
                '0'...'9', '_' => {},
                else => break,
            },
            .builtin => switch (c) {
                'a'...'z', 'A'...'Z', '_' => {},
                else => break,
            },
            .single_string_literal => switch (c) {
                '\'' => break,
                else => {},
            },
            .double_string_literal => switch (c) {
                '"' => break,
                else => {},
            },
        }
    }

    switch (state) {
        .word => {
            const str = tokenizer.bytes[start..tokenizer.pos];
            tag = keywords.get(str) orelse .column_name;
        },
        else => {},
    }

    if (tag == .eof)
        return null;

    return Token{
        .tag = tag,
        .start = start,
        .end = tokenizer.pos,
    };
}

pub fn eofToken() Token {
    return Token{
        .tag = .eof,
        .start = undefined,
        .end = undefined,
    };
}

// test "Tokenizer" {
//     const t = std.testing;
//     const testTokens = struct {
//         fn func(bytes: []const u8, tokens: []const Token.Tag) !void {
//             var tokenizer = Tokenizer.init(bytes);
//             for (tokens) |tag| {
//                 if (tag == .eof) {
//                     try t.expectEqual(@as(?Token, null), tokenizer.next());
//                 } else {
//                     try t.expectEqual(tag, tokenizer.next().?.tag);
//                 }
//             }
//             try t.expectEqual(@as(?Token, null), tokenizer.next());
//         }
//     }.func;

//     try testTokens("a = 3", &.{ .column_name, .equals_sign, .number, .eof });
//     try testTokens("@max(34, 100 + 45, @min(3, 1))", &.{ .builtin, .lparen, .number, .comma, .number, .plus, .number, .comma, .builtin, .lparen, .number, .comma, .number, .rparen, .rparen, .eof });
//     try testTokens("", &.{.eof});
// }
