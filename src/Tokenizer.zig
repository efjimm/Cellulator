const std = @import("std");
const Position = @import("Sheet.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;

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
        hash,

        lparen,
        rparen,

        column_name,
        cell_name,
        builtin,

        single_string_literal,
        double_string_literal,

        keyword_let,

        eof,
        unknown,
    };
};

const keywords = std.ComptimeStringMap(Token.Tag, .{
    .{ "let", .keyword_let },
});

pub fn init(bytes: []const u8) Tokenizer {
    return .{
        .bytes = bytes,
    };
}

pub fn next(tokenizer: *Tokenizer) ?Token {
    if (tokenizer.pos >= tokenizer.bytes.len) return null;
    var start = tokenizer.pos;

    var state: State = .start;
    var tag = Token.Tag.unknown;

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
                '#' => {
                    tag = .hash;
                    tokenizer.pos += 1;
                    break;
                },
                '\'' => {
                    state = .single_string_literal;
                },
                '"' => {
                    state = .double_string_literal;
                },
                else => {
                    defer tokenizer.pos += 1;
                    return .{
                        .tag = .unknown,
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
                '\'' => {
                    tag = .single_string_literal;
                    break;
                },
                else => {},
            },
            .double_string_literal => switch (c) {
                '"' => {
                    tag = .double_string_literal;
                    break;
                },
                else => {},
            },
        }
    }

    switch (state) {
        .word => {
            const str = tokenizer.bytes[start..tokenizer.pos];
            tag = keywords.get(str) orelse .column_name;
        },
        .single_string_literal, .double_string_literal => {
            tokenizer.pos += 1;
            return Token{
                .tag = tag,
                .start = start + 1,
                .end = tokenizer.pos - 1,
            };
        },
        else => {},
    }

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

test "Tokens" {
    const t = std.testing;
    const testTokens = struct {
        fn func(bytes: []const u8, tokens: []const Token.Tag) !void {
            var tokenizer = Tokenizer.init(bytes);
            for (tokens) |tag| {
                if (tag == .eof) {
                    try t.expectEqual(@as(?Token, null), tokenizer.next());
                } else {
                    try t.expectEqual(tag, tokenizer.next().?.tag);
                }
            }
            try t.expectEqual(@as(?Token, null), tokenizer.next());
        }
    }.func;

    const data = .{
        .{ "", .{.eof} },
        .{ "'what'", .{ .single_string_literal, .eof } },
        .{ "\"what\"", .{ .double_string_literal, .eof } },
        .{ "'what", .{ .unknown, .eof } },
        .{ "what'", .{ .column_name, .unknown, .eof } },
        .{ "123", .{ .number, .eof } },
        .{ "123.123", .{ .number, .eof } },
        .{ "123.123.123", .{ .number, .number, .eof } },
        .{ "123_123_123", .{ .number, .eof } },
        .{ "=+-*/%,:#", .{ .equals_sign, .plus, .minus, .asterisk, .forward_slash, .percent, .comma, .colon, .hash, .eof } },
        .{ "() aaaaaa a0", .{ .lparen, .rparen, .column_name, .cell_name } },
        .{ "let a = 3", .{ .keyword_let, .column_name, .equals_sign, .number, .eof } },
        .{ "@max(34, 100 + 45, @min(3, 1))", .{ .builtin, .lparen, .number, .comma, .number, .plus, .number, .comma, .builtin, .lparen, .number, .comma, .number, .rparen, .rparen, .eof } },
    };

    inline for (data) |d| {
        try testTokens(d[0], &d[1]);
    }
}

test "Token text range" {
    const t = std.testing;
    var tokenizer = Tokenizer{ .bytes = "let a0 = 'this is epic'" };
    var token = tokenizer.next().?;
    try t.expectEqual(Token.Tag.keyword_let, token.tag);
    try t.expectEqual(@as(u32, 0), token.start);
    try t.expectEqual(@as(u32, "let".len), token.end);
    token = tokenizer.next().?;
    try t.expectEqual(Token.Tag.cell_name, token.tag);
    try t.expectEqual(@as(u32, "let ".len), token.start);
    try t.expectEqual(@as(u32, "let a0".len), token.end);
    token = tokenizer.next().?;
    try t.expectEqual(Token.Tag.equals_sign, token.tag);
    try t.expectEqual(@as(u32, "let a0 ".len), token.start);
    try t.expectEqual(@as(u32, "let a0 =".len), token.end);
    token = tokenizer.next().?;
    try t.expectEqual(Token.Tag.single_string_literal, token.tag);
    try t.expectEqual(@as(u32, "let a0 = '".len), token.start);
    try t.expectEqual(@as(u32, "let a0 = 'this is epic".len), token.end);
}
