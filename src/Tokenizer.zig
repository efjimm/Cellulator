const std = @import("std");
const Position = @import("Sheet.zig").Position;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Tokenizer = @This();

bytes: [:0]const u8,
pos: u32 = 0,
state: State = .start,

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

pub fn collectTokens(
    allocator: std.mem.Allocator,
    src: [:0]const u8,
    pre_alloc: u32,
) !std.MultiArrayList(Token) {
    var tokenizer: Tokenizer = .init(src);
    var list: std.MultiArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    try list.ensureTotalCapacity(allocator, pre_alloc);

    while (true) {
        const token = tokenizer.next();
        try list.append(allocator, token);
        if (token.tag == .eof) break;
    }

    return list;
}

pub const Token = struct {
    tag: Tag,
    start: u32,

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

        single_string_literal_start,
        single_string_literal_end,
        double_string_literal_start,
        double_string_literal_end,

        keyword_let,

        eof,
        unknown,
    };
};

const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "let", .keyword_let },
});

pub fn init(bytes: [:0]const u8) Tokenizer {
    return .{
        .bytes = bytes,
    };
}

pub fn next(tokenizer: *Tokenizer) Token {
    const eof: Token = .{
        .tag = .eof,
        .start = @intCast(tokenizer.bytes.len),
    };

    if (tokenizer.pos >= tokenizer.bytes.len)
        return eof;

    var start = tokenizer.pos;
    var tag = Token.Tag.unknown;

    state: switch (tokenizer.state) {
        .start => switch (tokenizer.bytes[tokenizer.pos]) {
            0 => return eof,
            '0'...'9' => {
                tag = .number;
                continue :state .integer_number;
            },
            '.' => {
                tag = .number;
                continue :state .decimal_number;
            },
            '=' => {
                tag = .equals_sign;
                tokenizer.pos += 1;
            },
            ' ', '\t', '\r', '\n' => {
                start += 1;
                tokenizer.pos += 1;
                continue :state .start;
            },
            'a'...'z', 'A'...'Z' => {
                continue :state .word;
            },
            '@' => {
                tag = .builtin;
                start += 1;
                continue :state .builtin;
            },
            ',' => {
                tag = .comma;
                tokenizer.pos += 1;
            },
            '+' => {
                tag = .plus;
                tokenizer.pos += 1;
            },
            '-' => {
                tag = .minus;
                tokenizer.pos += 1;
            },
            '*' => {
                tag = .asterisk;
                tokenizer.pos += 1;
            },
            '/' => {
                tag = .forward_slash;
                tokenizer.pos += 1;
            },
            '%' => {
                tag = .percent;
                tokenizer.pos += 1;
            },
            '(' => {
                tag = .lparen;
                tokenizer.pos += 1;
            },
            ')' => {
                tag = .rparen;
                tokenizer.pos += 1;
            },
            ':' => {
                tag = .colon;
                tokenizer.pos += 1;
            },
            '#' => {
                tag = .hash;
                tokenizer.pos += 1;
            },
            '\'' => {
                tag = .single_string_literal_start;
                tokenizer.state = .single_string_literal;
                tokenizer.pos += 1;
            },
            '"' => {
                tag = .double_string_literal_start;
                tokenizer.state = .double_string_literal;
                tokenizer.pos += 1;
            },
            else => {
                defer tokenizer.pos += 1;
                return .{
                    .tag = .unknown,
                    .start = start,
                };
            },
        },
        .integer_number => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                '0'...'9', '_' => continue :state .integer_number,
                '.' => continue :state .decimal_number,
                else => {},
            }
        },
        .decimal_number => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                '0'...'9', '_' => continue :state .decimal_number,
                else => {},
            }
        },
        .word => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                'a'...'z', 'A'...'Z' => continue :state .word,
                '0'...'9', '_' => {
                    tag = .cell_name;
                    continue :state .cell_address;
                },
                else => {
                    const str = tokenizer.bytes[start..tokenizer.pos];
                    tag = keywords.get(str) orelse .column_name;
                },
            }
        },
        .cell_address => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                '0'...'9', '_' => continue :state .cell_address,
                else => {},
            }
        },
        .builtin => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                'a'...'z', 'A'...'Z', '_' => continue :state .builtin,
                else => {},
            }
        },
        .single_string_literal => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                '\'' => {
                    tag = .single_string_literal_end;
                    start = tokenizer.pos;
                    tokenizer.pos += 1;
                    tokenizer.state = .start;
                },
                0 => {},
                else => continue :state .single_string_literal,
            }
        },
        .double_string_literal => {
            tokenizer.pos += 1;
            switch (tokenizer.bytes[tokenizer.pos]) {
                '"' => {
                    tag = .double_string_literal_end;
                    start = tokenizer.pos;
                    tokenizer.pos += 1;
                    tokenizer.state = .start;
                },
                0 => {},
                else => continue :state .double_string_literal,
            }
        },
    }

    return .{
        .tag = tag,
        .start = start,
    };
}

test "Tokens" {
    const t = std.testing;
    const testTokens = struct {
        fn func(bytes: [:0]const u8, tokens: []const Token.Tag) !void {
            var tokenizer = Tokenizer.init(bytes);
            for (tokens) |tag| {
                try t.expectEqual(tag, tokenizer.next().tag);
            }
        }
    }.func;

    const data = .{
        .{ "", .{.eof} },
        .{ "'what'", .{ .single_string_literal_start, .single_string_literal_end, .eof } },
        .{ "\"what\"", .{ .double_string_literal_start, .double_string_literal_end, .eof } },
        .{ "'what", .{ .single_string_literal_start, .unknown, .eof } },
        .{ "what'", .{ .column_name, .single_string_literal_start, .eof } },
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
    var tokenizer: Tokenizer = .init("let a0 = 'this is epic'");
    var token = tokenizer.next();
    try t.expectEqual(.keyword_let, token.tag);
    try t.expectEqual(0, token.start);
    token = tokenizer.next();
    try t.expectEqual(.cell_name, token.tag);
    try t.expectEqual("let ".len, token.start);
    token = tokenizer.next();
    try t.expectEqual(.equals_sign, token.tag);
    try t.expectEqual("let a0 ".len, token.start);
    token = tokenizer.next();
    try t.expectEqual(.single_string_literal_start, token.tag);
    try t.expectEqual("let a0 = ".len, token.start);
}
