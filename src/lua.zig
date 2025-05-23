const std = @import("std");
const lua = @import("zlua");
const utils = @import("utils.zig");
const Lua = lua.Lua;
const ZC = @import("ZC.zig");
const Position = @import("Position.zig").Position;
const assert = std.debug.assert;
const _log = std.log.scoped(.lua);
const Tui = @import("Tui.zig");

pub fn init(zc: *ZC) !*Lua {
    const state = try Lua.init(zc.allocator);
    errdefer state.deinit();
    try state.checkStack(2);

    state.openLibs();

    try createMetatable(state, "position");
    state.pop(1);

    // Main 'zc' object is a reference to a ZC pointer, so we can use uservalues on it
    state.newUserdata(*ZC, 1).* = zc;

    {
        // zc metatable
        try createMetatable(state, "zc");

        {
            // Tui
            // Requires `zc` to be a stable pointer
            state.newUserdata(*Tui, 1).* = &zc.ui;

            try createMetatable(state, "tui");
            state.setMetatable(-2);
            state.setField(-2, "tui");
        }

        state.setMetatable(1);
    }

    // zc uservalue
    state.createTable(0, 1);

    // zc.current_sheet table
    state.createTable(0, 1);
    state.setField(-2, "sheet");

    try state.setUserValue(1, 1);

    state.setGlobal("zc");

    try initEvents(state);
    return state;
}

/// Emits an event to be handled by Lua code.
pub fn emitEvent(state: *Lua, event: []const u8, args: anytype) !void {
    try state.checkStack(4);

    const top_index = state.getTop();
    defer state.setTop(top_index);

    // Push `zc.events:emit`
    _ = state.getGlobal("zc") catch return;
    _ = state.getField(-1, "events");
    _ = state.getField(-1, "emit");
    state.remove(-3);

    // Push arguments
    _ = state.pushValue(-2);
    _ = state.pushString(event);

    var arg_count: i32 = 0;
    inline for (args) |arg| arg_count += try pushArgument(state, arg);
    state.protectedCall(.{
        .args = args.len + 2,
    }) catch |err| {
        std.log.err("Lua pcall error: {s}", .{
            try state.toString(-1),
        });
        return err;
    };
}

/// Pushes a generic argument on to the Lua stack.
/// Structs are pushed as tables. Strings must be null terminated.
///
/// Returns the number of values pushed onto the stack.
fn pushArgument(state: *Lua, value: anytype) !i32 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    const old_top = state.getTop();
    errdefer state.setTop(old_top);

    try state.checkStack(1);

    if (comptime utils.isZigString(T)) {
        _ = state.pushString(value);
    } else switch (info) {
        .comptime_int => state.pushInteger(value),
        .int => state.pushInteger(@intCast(value)),

        .comptime_float => state.pushNumber(value),
        .float => state.pushNumber(@floatCast(value)),

        .@"struct" => {
            if (@hasDecl(T, "toLua")) {
                return value.toLua(state);
            } else {
                const fields = comptime std.meta.fields(T);

                state.createTable(0, @intCast(fields.len));

                try state.checkStack(1);
                inline for (fields) |f| {
                    const field_name = comptime &utils.dupeZ(u8, f.name[0..].*);
                    _ = try pushArgument(state, @field(value, f.name));
                    state.setField(-2, field_name);
                }
                return 1;
            }
        },
        .optional => if (value) |v| {
            if (@typeInfo(@TypeOf(v)) == .optional)
                @compileError("Nested optionals are not supported");
            _ = try pushArgument(state, v);
        } else {
            state.pushNil();
        },
        else => @compileError("Unsupported type passed to pushArgument"),
    }
    return 1;
}

/// Initialises the events table and pushes it onto the Lua stack
fn initEvents(state: *Lua) !void {
    try state.doString(@embedFile("init.lua"));
}

fn newIndexCommon(state: *Lua) c_int {
    _ = state.getUserValue(1, 1) catch unreachable;
    state.pushValue(2);
    state.pushValue(3);
    state.setTable(-3);
    return 0;
}

fn indexCommon(state: *Lua) c_int {
    // Index the type's metatable
    state.getMetatable(1) catch unreachable;
    state.pushValue(2);
    _ = state.getTable(-2);

    // If not found, index the uservalue
    if (state.isNil(-1)) {
        _ = state.getUserValue(1, 1) catch unreachable;
        state.pushValue(2);
        _ = state.getTable(-2);
    }
    return 1;
}

fn isLuaFunction(func: anytype) bool {
    const info = @typeInfo(@TypeOf(func));
    if (info != .@"fn") return false;

    const f = info.@"fn";

    return f.calling_convention.eql(.c) and
        f.return_type == c_int and
        f.params.len == 1 and
        f.params[0].type == *Lua;
}

fn LuaFuncsRet(comptime T: type) type {
    const info = @typeInfo(T);
    var func_count = 0;
    inline for (info.@"struct".decls) |decl| {
        const d = @field(T, decl.name);
        if (comptime isLuaFunction(d)) func_count += 1;
    }

    return [func_count]lua.FnReg;
}

fn getLuaFunctions(comptime T: type) LuaFuncsRet(T) {
    var ret: LuaFuncsRet(T) = undefined;
    const decls = @typeInfo(T).@"struct".decls;
    comptime var i = 0;
    inline for (decls) |decl| {
        const f = @field(T, decl.name);
        if (comptime isLuaFunction(f)) {
            ret[i] = .{
                .name = comptime &utils.dupeZ(u8, decl.name[0..].*),
                .func = @ptrCast(&f),
            };
            i += 1;
        }
    }
    comptime assert(i == ret.len);
    return ret;
}

fn createMetatable(state: *Lua, comptime name: [:0]const u8) !void {
    try state.newMetatable(name);
    const funcs = comptime &getLuaFunctions(@field(metatables, name));
    state.setFuncs(funcs, 0);
}

fn checkCellAddress(state: *Lua, raw_index: i32) Position {
    const index = state.absIndex(raw_index);
    if (state.isString(index)) {
        const str = state.toString(index) catch unreachable;
        return Position.fromAddress(str) catch
            state.argError(index, "Invalid cell address string");
    } else if (state.isTable(index)) {
        _ = state.getField(index, "x");
        _ = state.getField(index, "y");

        const x = state.toInteger(-2) catch state.typeError(2, "integer");
        const y = state.toInteger(-1) catch state.typeError(2, "integer");

        switch (x) {
            0...std.math.maxInt(Position.Int) => {},
            else => state.argError(index, "Invalid x value (min: 0, max: 2^32 - 1)"),
        }
        switch (y) {
            0...std.math.maxInt(Position.Int) => {},
            else => state.argError(index, "Invalid y value (min: 0, max: 2^32 - 1)"),
        }

        return .{ .x = @intCast(x), .y = @intCast(y) };
    } else state.typeError(2, "string or table");
}

const metatables = .{
    .zc = struct {
        pub fn __newindex(state: *Lua) callconv(.C) c_int {
            return newIndexCommon(state);
        }

        pub fn __index(state: *Lua) callconv(.C) c_int {
            if (!state.isString(2)) return indexCommon(state);

            // const key = state.toString(2) catch unreachable;

            return indexCommon(state);
        }

        pub fn status(state: *Lua) callconv(.C) c_int {
            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            state.checkType(2, .table);
            _ = state.getIndex(2, 1);
            const msg = state.checkString(-1);
            _ = state.getField(2, "level");

            const level: ZC.StatusMessageType =
                if (state.toString(-1)) |level_str| blk: {
                    const map = std.StaticStringMap(ZC.StatusMessageType).initComptime(.{
                        .{ "error", .err },
                        .{ "warn", .warn },
                        .{ "info", .info },
                        // .{ "debug", .debug },
                    });

                    break :blk map.get(level_str) orelse .info;
                } else |_| .info;

            zc.setStatusMessage(level, "{s}", .{msg});
            return 0;
        }

        pub fn end_undo_group(state: *Lua) callconv(.C) c_int {
            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            zc.sheet.endUndoGroup();
            return 0;
        }

        pub fn set_cell(state: *Lua) callconv(.C) c_int {
            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            state.checkType(2, .table);

            _ = state.getIndex(2, 1);
            _ = state.getIndex(2, 2);
            const expr_str = state.checkString(-1);
            const pos = checkCellAddress(state, -2);

            zc.setCellString(pos, expr_str, .{ .emit_event = false }) catch |err| switch (err) {
                error.InvalidCellAddress => unreachable,
                error.UnexpectedToken => state.argError(2, "Unexpected token"),
                error.OutOfMemory => return 0, // TODO: Make sure this is handled properly
            };
            return 0;
        }

        pub fn delete_cell(state: *Lua) callconv(.C) c_int {
            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            state.checkType(2, .table);

            _ = state.getIndex(2, 1);
            const pos = checkCellAddress(state, -1);
            zc.deleteCell2(pos, .{ .emit_event = false }) catch {};

            state.setTop(0);
            return 0;
        }

        pub fn set_cursor(state: *Lua) callconv(.C) c_int {
            const zc: *ZC = state.checkUserdata(*ZC, 1, "zc").*;
            const pos = checkCellAddress(state, 2);

            zc.setCursor(pos);

            state.setTop(0);
            return 0;
        }

        pub fn command(state: *Lua) callconv(.C) c_int {
            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            const cmd_str = state.checkString(2);
            zc.runCommand(cmd_str) catch {};
            state.setTop(0);
            return 0;
        }

        // pub fn get_cell_number(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     var state = getState(c_state);

        //     const zc: *ZC = state.checkUserdata(*ZC, 1, "zc").*;
        //     const pos = checkCellAddress(state, 2);

        //     const cell = zc.sheet.cells.get(pos) orelse return 0;
        //     const num = cell.getValue() orelse return 0;
        //     state.pushNumber(num);

        //     return 1;
        // }

        // // TODO: Allow selecting sheet
        // pub fn get_cell_text(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     var state = getState(c_state);

        //     const zc: *ZC = state.checkUserdata(*ZC, 1, "zc").*;
        //     state.checkType(2, .table);
        //     _ = state.getIndex(2, 1);
        //     const pos = checkCellAddress(state, -1);

        //     const cell = zc.sheet.text_cells.get(pos) orelse return 0;
        //     const str = cell.string() orelse return 0;
        //     _ = state.pushString(str);

        //     return 1;
        // }

        // TODO
        // pub fn get_cell_expr_number(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     _ = c_state;
        //     return 1;
        // }

        // pub fn get_cell_expr_text(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     _ = c_state;
        //     return 1;
        // }

        // pub fn bind(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     _ = c_state;
        //     return 0;
        // }

        // pub fn unbind(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     _ = c_state;
        //     return 0;
        // }
    },

    .position = struct {
        pub fn __tostring(state: *Lua) callconv(.C) c_int {
            const pos = checkCellAddress(state, 1);
            var buf = std.BoundedArray(u8, 64){};
            pos.writeCellAddress(buf.writer()) catch unreachable;

            _ = state.pushString(buf.slice());

            return 1;
        }

        pub fn __concat(state: *Lua) callconv(.C) c_int {
            _ = state.toStringEx(1);
            _ = state.toStringEx(2);
            state.concat(2);
            return 1;
        }
    },

    .tui = struct {
        pub fn __index(state: *Lua) callconv(.C) c_int {
            return indexCommon(state);
        }
    },
};

const shovel = @import("shovel");

pub fn parseColourString(state: *Lua, t: lua.LuaType) shovel.Style.Colour {
    if (t == .nil) return .none;
    const str = state.checkString(-1);
    const colour = shovel.Style.Colour.fromDescription(str) catch {
        state.raiseErrorStr("invalid colour string '%s'", .{str.ptr});
    };
    state.pop(1);
    return colour;
}

// Exports all lua functions in `metatables` with unique names
comptime {
    const Metatables = @TypeOf(metatables);
    for (std.meta.fields(Metatables)) |field| {
        const T = @field(metatables, field.name);
        assert(@TypeOf(T) == type);

        const prefix = "metatable." ++ field.name ++ ".";

        for (@typeInfo(T).@"struct".decls) |decl| {
            const d = @field(T, decl.name);
            if (!isLuaFunction(d)) @compileError(prefix ++ decl.name ++ " is not a Lua function");
            @export(&d, .{ .name = prefix ++ decl.name });
        }
    }
}
