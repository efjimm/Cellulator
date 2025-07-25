const std = @import("std");
const Position = @import("Sheet.zig").Position;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Tokenizer = @This();

reader: *std.io.Reader,
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
    comment,
};

pub fn collectTokens(
    allocator: std.mem.Allocator,
    r: *std.io.Reader,
    pre_alloc: u32,
) !std.MultiArrayList(Token) {
    var tokenizer: Tokenizer = .init(r);
    var list: std.MultiArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    try list.ensureTotalCapacity(allocator, pre_alloc);

    while (true) {
        const token = try tokenizer.next();
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
        caret,

        lparen,
        rparen,

        column_name,
        rel_rel,
        rel_abs,
        abs_rel,
        abs_abs,
        builtin,

        single_string_literal_start,
        single_string_literal_end,
        double_string_literal_start,
        double_string_literal_end,

        keyword_let,

        eof,
        unknown,

        pub fn format(tag: Tag, writer: *std.io.Writer) !void {
            const strings = comptime std.EnumArray(Tag, []const u8).init(.{
                .number = "number",
                .equals_sign = "'='",
                .plus = "'+'",
                .minus = "'-'",
                .asterisk = "'*'",
                .forward_slash = "'/'",
                .percent = "'%'",
                .comma = "','",
                .colon = "':'",
                .hash = "'#'",
                .lparen = "'('",
                .rparen = "')'",
                .column_name = "column name",
                .rel_rel = "cell address",
                .rel_abs = "cell address",
                .abs_rel = "cell address",
                .abs_abs = "cell address",
                .builtin = "builtin",
                .single_string_literal_start = "\"'\"",
                .single_string_literal_end = "\"'\"",
                .double_string_literal_start = "'\"'",
                .double_string_literal_end = "'\"'",
                .keyword_let = "'let'",
                .eof = "eof",
                .caret = "^",
                .unknown = "",
            });

            const str = strings.get(tag);
            try writer.writeAll(str);
        }
    };
};

const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "let", .keyword_let },
});

pub fn init(reader: *std.io.Reader) Tokenizer {
    return .{ .reader = reader };
}

fn byte(tok: *const Tokenizer) !u8 {
    return tok.reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

fn toss(t: *Tokenizer, n: u32) void {
    t.reader.toss(n);
    t.pos += n;
}

pub fn next(t: *Tokenizer) !Token {
    const eof: Token = .{
        .tag = .eof,
        .start = t.pos,
    };

    if (t.reader.buffer.len == 0) {
        @branchHint(.unlikely);
        return eof;
    }

    var start = t.pos;
    var tag = Token.Tag.unknown;

    var kw_buf: std.BoundedArray(u8, 64) = .{};

    state: switch (t.state) {
        .start => switch (try t.byte()) {
            0 => return eof,
            '0'...'9' => {
                tag = .number;
                continue :state .integer_number;
            },
            '.' => {
                t.toss(1);
                switch (try t.byte()) {
                    '0'...'9' => {
                        tag = .number;
                        continue :state .decimal_number;
                    },
                    else => {},
                }
            },
            '=' => {
                tag = .equals_sign;
                t.toss(1);
            },
            ' ', '\t', '\r', '\n' => {
                start += 1;
                t.toss(1);
                continue :state .start;
            },
            '$' => {
                tag = .abs_rel;
                continue :state .word;
            },
            'a'...'z', 'A'...'Z' => |c| {
                tag = .rel_rel;
                kw_buf.appendAssumeCapacity(c);
                continue :state .word;
            },
            '@' => {
                tag = .builtin;
                continue :state .builtin;
            },
            ',' => {
                tag = .comma;
                t.toss(1);
            },
            '+' => {
                tag = .plus;
                t.toss(1);
            },
            '-' => {
                t.toss(1);
                switch (try t.byte()) {
                    '-' => continue :state .comment,
                    else => {},
                }
                tag = .minus;
            },
            '*' => {
                tag = .asterisk;
                t.toss(1);
            },
            '/' => {
                tag = .forward_slash;
                t.toss(1);
            },
            '%' => {
                tag = .percent;
                t.toss(1);
            },
            '^' => {
                tag = .caret;
                t.toss(1);
            },
            '(' => {
                tag = .lparen;
                t.toss(1);
            },
            ')' => {
                tag = .rparen;
                t.toss(1);
            },
            ':' => {
                tag = .colon;
                t.toss(1);
            },
            '#' => {
                tag = .hash;
                t.toss(1);
            },
            '\'' => {
                tag = .single_string_literal_start;
                t.state = .single_string_literal;
                t.toss(1);
            },
            '"' => {
                tag = .double_string_literal_start;
                t.state = .double_string_literal;
                t.toss(1);
            },
            else => {
                defer t.toss(1);
                return .{
                    .tag = .unknown,
                    .start = start,
                };
            },
        },
        .comment => {
            t.toss(1);
            switch (try t.byte()) {
                '\n' => {
                    start = t.pos;
                    continue :state .start;
                },
                0 => return eof,
                else => continue :state .comment,
            }
        },
        .integer_number => {
            t.toss(1);
            switch (try t.byte()) {
                '0'...'9', '_' => continue :state .integer_number,
                '.' => continue :state .decimal_number,
                else => {},
            }
        },
        .decimal_number => {
            t.toss(1);
            switch (try t.byte()) {
                '0'...'9', '_' => continue :state .decimal_number,
                else => {},
            }
        },
        .word => {
            t.toss(1);
            switch (try t.byte()) {
                'a'...'z', 'A'...'Z' => |c| {
                    kw_buf.appendAssumeCapacity(c);
                    continue :state .word;
                },
                '0'...'9', '_' => { // TODO: Should we accept _ here?
                    continue :state .cell_address;
                },
                '$' => {
                    tag = switch (tag) {
                        .abs_rel => .abs_abs,
                        else => .rel_abs,
                    };
                    continue :state .cell_address;
                },
                else => {
                    const str = kw_buf.constSlice();
                    tag = keywords.get(str) orelse .column_name;
                },
            }
        },
        .cell_address => {
            t.toss(1);
            switch (try t.byte()) {
                '0'...'9', '_' => continue :state .cell_address,
                else => {},
            }
        },
        .builtin => {
            t.toss(1);
            switch (try t.byte()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .builtin,
                else => {},
            }
        },
        .single_string_literal => {
            switch (try t.byte()) {
                '\'' => {
                    tag = .single_string_literal_end;
                    start = t.pos;
                    t.toss(1);
                    t.state = .start;
                },
                0 => {
                    t.state = .start;
                    if (tag == .unknown and t.pos == start) return eof;
                },
                else => {
                    t.toss(1);
                    continue :state .single_string_literal;
                },
            }
        },
        .double_string_literal => {
            switch (try t.byte()) {
                '"' => {
                    tag = .double_string_literal_end;
                    start = t.pos;
                    t.toss(1);
                    t.state = .start;
                },
                0 => {
                    t.state = .start;
                    if (tag == .unknown and t.pos == start) return eof;
                },
                else => {
                    t.toss(1);
                    continue :state .double_string_literal;
                },
            }
        },
    }

    return .{
        .tag = tag,
        .start = start,
    };
}

test "Tokens" {
    const testTokens = struct {
        fn func(bytes: []const u8, tokens: []const Token.Tag) !void {
            var reader: std.io.Reader = .fixed(bytes);
            var tokenizer = Tokenizer.init(&reader);
            for (tokens) |tag| {
                const token = try tokenizer.next();
                try std.testing.expectEqual(tag, token.tag);
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
        .{ "() aaaaaa a0", .{ .lparen, .rparen, .column_name, .rel_rel } },
        .{ "let a = 3", .{ .keyword_let, .column_name, .equals_sign, .number, .eof } },
        .{ "@max(34, 100 + 45, @min(3, 1))", .{ .builtin, .lparen, .number, .comma, .number, .plus, .number, .comma, .builtin, .lparen, .number, .comma, .number, .rparen, .rparen, .eof } },
        .{ "$a1", .{ .abs_rel, .eof } },
        .{ "$a$1", .{ .abs_abs, .eof } },
        .{ "a$1", .{ .rel_abs, .eof } },
    };

    inline for (data) |d| {
        testTokens(d[0], &d[1]) catch |err| {
            std.debug.print("{s}\n", .{d[0]});
            return err;
        };
    }
}

test "Token text range" {
    const t = std.testing;
    var reader: std.io.Reader = .fixed("let a0 = 'this is epic'");
    var tokenizer: Tokenizer = .init(&reader);
    var token = try tokenizer.next();
    try t.expectEqual(.keyword_let, token.tag);
    try t.expectEqual(0, token.start);
    token = try tokenizer.next();
    try t.expectEqual(.rel_rel, token.tag);
    try t.expectEqual("let ".len, token.start);
    token = try tokenizer.next();
    try t.expectEqual(.equals_sign, token.tag);
    try t.expectEqual("let a0 ".len, token.start);
    token = try tokenizer.next();
    try t.expectEqual(.single_string_literal_start, token.tag);
    try t.expectEqual("let a0 = ".len, token.start);
}
