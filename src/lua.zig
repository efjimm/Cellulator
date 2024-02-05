const std = @import("std");
const lua = @import("ziglua");
const utils = @import("utils.zig");
const Lua = lua.Lua;
const ZC = @import("ZC.zig");
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig").Position;
const assert = std.debug.assert;
const _log = std.log.scoped(.lua);

pub fn init(zc: *ZC) !Lua {
    var state = try Lua.init(&zc.allocator);
    errdefer state.deinit();
    try state.checkStack(2);

    state.openLibs();

    try createMetatable(&state, "position");
    state.pop(1);

    // Main 'zc' object is a reference to a ZC pointer, so we can use uservalues on it
    state.newUserdata(*ZC, 1).* = zc;

    // zc metatable
    try createMetatable(&state, "zc");
    state.setMetatable(1);

    // zc uservalue
    state.createTable(0, 1);
    try state.setUserValue(1, 1);

    state.setGlobal("zc");

    try initEvents(&state);
    return state;
}

/// Emits an event to be handled by Lua code.
pub fn emitEvent(state: *Lua, event: []const u8, args: anytype) !void {
    try state.checkStack(4);

    const top_index = state.getTop();
    defer state.setTop(top_index);

    // Call `zc.events:emit`
    _ = state.getGlobal("zc") catch return;
    _ = state.getField(-1, "events");
    _ = state.getField(-1, "emit");
    state.remove(-3);

    // Push arguments
    _ = state.pushValue(-2);
    _ = state.pushBytes(event);

    var arg_count: i32 = 0;
    inline for (args) |arg| arg_count += try pushArgument(state, arg);
    try state.protectedCall(arg_count + 2, 0, 0);
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
        _ = state.pushBytes(value);
    } else switch (info) {
        .ComptimeInt => state.pushInteger(value),
        .Int => state.pushInteger(@intCast(value)),

        .ComptimeFloat => state.pushNumber(value),
        .Float => state.pushNumber(@floatCast(value)),

        .Struct => {
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
        else => @compileError("Could not deduce generic type"),
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
    if (info != .Fn) return false;

    const f = info.Fn;

    return f.calling_convention == .C and
        f.return_type == c_int and
        f.params.len == 1 and
        f.params[0].type == ?*lua.LuaState;
}

fn LuaFuncsRet(comptime T: type) type {
    const info = @typeInfo(T);
    var func_count = 0;
    inline for (info.Struct.decls) |decl| {
        const d = @field(T, decl.name);
        if (comptime isLuaFunction(d)) func_count += 1;
    }

    return [func_count]lua.FnReg;
}

fn getLuaFunctions(comptime T: type) LuaFuncsRet(T) {
    var ret: LuaFuncsRet(T) = undefined;
    const decls = @typeInfo(T).Struct.decls;
    comptime var i = 0;
    inline for (decls) |decl| {
        const f = @field(T, decl.name);
        if (comptime isLuaFunction(f)) {
            ret[i] = .{
                .name = comptime &utils.dupeZ(u8, decl.name[0..].*),
                .func = f,
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
        const str = state.toBytes(index) catch unreachable;
        return Position.fromAddress(str) catch
            state.argError(index, "Invalid cell address string");
    } else if (state.isTable(index)) {
        _ = state.getField(index, "x");
        _ = state.getField(index, "y");

        const x = state.toInteger(-2) catch state.typeError(2, "integer");
        const y = state.toInteger(-1) catch state.typeError(2, "integer");

        // NOTE: values here need to be updated when Position's fields are changed to u32
        switch (x) {
            0...std.math.maxInt(u16) => {},
            else => state.argError(index, "Invalid x value (min: 0, max: 65535)"),
        }
        switch (y) {
            0...std.math.maxInt(u16) => {},
            else => state.argError(index, "Invalid y value (min: 0, max: 65535)"),
        }

        return .{ .x = @intCast(x), .y = @intCast(y) };
    } else state.typeError(2, "string or table");
}

fn getZc(state: *Lua) *ZC {
    _ = state.getGlobal("zc") catch unreachable;
    defer state.pop(1);
    return (state.toUserdata(*ZC, -1) catch unreachable).*;
}

/// Returns the Zig wrapper around a Lua state.
inline fn getState(c_state: ?*lua.LuaState) Lua {
    return .{ .state = c_state.? };
}

/// Zig functions that get called for certain events.
/// These are not exposed to lua code, and always get executed BEFORE
/// any registered lua handlers.
const handlers = struct {
    pub fn Start(zc: *ZC, name: []const u8) void {
        // Creates a new `sheet` object in zc.sheets.
        // TODO: Move this into the NewSheet handler
        _ = zc.lua.getGlobal("zc") catch unreachable;
        _ = zc.lua.getField(-1, "sheets");

        zc.lua.createTable(0, 1);
        zc.lua.setMetatableRegistry("sheet");
        zc.lua.pushBytes(name);
        zc.lua.setField(-1, "name");
    }
};

const metatables = .{
    .zc = struct {
        pub fn __newindex(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);
            return newIndexCommon(&state);
        }

        pub fn __index(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            if (state.isString(2)) {
                const key = state.toBytes(2) catch unreachable;
                const map = std.ComptimeStringMap(
                    enum {
                        current_sheet,
                    },
                    .{
                        .{ "current_sheet", .current_sheet },
                    },
                );

                if (map.get(key)) |tag| {
                    const zc = (state.toUserdata(*ZC, 1) catch unreachable).*;
                    switch (tag) {
                        .current_sheet => {
                            _ = state.getUserValue(1, 1) catch unreachable;
                            _ = state.getField(-1, "current_sheet");
                            const name = zc.sheet.filepath.constSlice();
                            _ = state.pushBytes(name);
                            state.setField(-2, "name");
                            return 1;
                        },
                    }
                }
            }

            return indexCommon(&state);
        }

        pub fn log(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            state.checkType(1, .table);
            _ = state.getIndex(1, 1);
            const msg = state.checkBytes(-1);
            _ = state.getField(1, "level");
            const level_str = state.toBytes(-1) catch "info";

            const map = std.ComptimeStringMap(std.log.Level, .{
                .{ "error", .err },
                .{ "warn", .warn },
                .{ "info", .info },
                .{ "debug", .debug },
            });

            const level = map.get(level_str) orelse .info;

            switch (level) {
                .err => _log.err("{s}", .{msg}),
                .warn => _log.warn("{s}", .{msg}),
                .info => _log.info("{s}", .{msg}),
                .debug => _log.debug("{s}", .{msg}),
            }

            return 0;
        }

        pub fn end_undo_group(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            zc.sheet.endUndoGroup();
            return 0;
        }

        pub fn set_cell(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            state.checkType(2, .table);

            _ = state.getIndex(2, 1);
            _ = state.getIndex(2, 2);
            const expr_str = state.checkBytes(-1);
            const pos = checkCellAddress(&state, -2);

            zc.setCellString(pos, expr_str, .{ .emit_event = false }) catch |err| switch (err) {
                error.InvalidCellAddress => unreachable,
                error.UnexpectedToken => state.argError(2, "Unexpected token"),
                error.OutOfMemory => return 0, // TODO: Make sure this is handle properly
            };
            return 0;
        }

        pub fn delete_cell(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            const zc = state.checkUserdata(*ZC, 1, "zc").*;
            state.checkType(2, .table);

            _ = state.getIndex(2, 1);
            const pos = checkCellAddress(&state, -1);

            zc.deleteCell2(pos, .{ .emit_event = false }) catch {};

            return 0;
        }

        pub fn set_cursor(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            const zc: *ZC = state.checkUserdata(*ZC, 1, "zc").*;
            const pos = checkCellAddress(&state, 2);

            zc.setCursor(pos);

            return 0;
        }

        // pub fn get_cell_number(c_state: ?*lua.LuaState) callconv(.C) c_int {
        //     var state = getState(c_state);

        //     const zc: *ZC = state.checkUserdata(*ZC, 1, "zc").*;
        //     const pos = checkCellAddress(&state, 2);

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
        //     const pos = checkCellAddress(&state, -1);

        //     const cell = zc.sheet.text_cells.get(pos) orelse return 0;
        //     const str = cell.string() orelse return 0;
        //     _ = state.pushBytes(str);

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
        pub fn __tostring(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);

            const pos = checkCellAddress(&state, 1);
            var buf = std.BoundedArray(u8, 64){};
            pos.writeCellAddress(buf.writer()) catch unreachable;

            _ = state.pushBytes(buf.slice());

            return 1;
        }

        pub fn __concat(c_state: ?*lua.LuaState) callconv(.C) c_int {
            var state = getState(c_state);
            _ = state.toBytesFmt(1);
            _ = state.toBytesFmt(2);
            state.concat(2);
            return 1;
        }
    },
};

// Exports all lua functions in `metatables` with unique names
comptime {
    const Metatables = @TypeOf(metatables);
    for (std.meta.fields(Metatables)) |field| {
        const T = @field(metatables, field.name);
        assert(@TypeOf(T) == type);

        const prefix = "metatable." ++ field.name ++ ".";

        for (@typeInfo(T).Struct.decls) |decl| {
            const d = @field(T, decl.name);
            if (!isLuaFunction(d)) @compileError(prefix ++ decl.name ++ " is not a Lua function");
            @export(d, .{ .name = prefix ++ decl.name });
        }
    }
}
