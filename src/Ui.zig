const std = @import("std");
const Ui = @This();
const Sheet = @import("Sheet.zig");
const ZC = @import("ZC.zig");

ptr: *anyopaque,
vtable: *const Vtable,

pub const ApplyThemeError = error{
    Unsupported,
    Failed,
};

pub const Vtable = struct {
    /// Run the main loop. Returns an exit code. This function is only run once, and the UI should
    /// deinitialize itself before returning from this function.
    run: *const fn (*anyopaque, *ZC) u8 = runStub,

    /// When a user sets a theme, the path
    /// `${XDG_CONFIG_HOME}/cellulator/themes/${UI}/${THEME_NAME}` is passed to this function.
    /// The UI backend is then responsible for applying the theme in this file.
    applyTheme: *const fn (*anyopaque, [:0]const u8) ApplyThemeError!void = applyThemeStub,

    /// Apply the default theme.
    applyDefaultTheme: *const fn (*anyopaque) ApplyThemeError!void = applyDefaultThemeStub,

    stringWidth: *const fn (*anyopaque, []const u8, StringWidthOptions) StringWidthResult = stringWidthStub,
    defaultWidth: *const fn (*anyopaque) u16 = defaultWidthStub,

    /// Returns the number of fully visible rows on screen.
    visibleRowCount: *const fn (*anyopaque) u16 = visibleRowCountStub,

    /// Returns the width to display the entire contents of a single column.
    widthNeededForColumn: *const fn (*anyopaque, *ZC, *Sheet, u32) u16 = widthNeededForColumnStub,

    /// Enables truecolor. Can be ignored by non-terminal UIs.
    setTrueColour: *const fn (*anyopaque, *ZC, bool) void = setTrueColourStub,

    /// Called when a command is entered.
    submitCommand: *const fn (*anyopaque, [:0]const u8) void = submitCommandStub,

    // Yes these are a little bit cursed to put in a vtable but this is better than calling
    // a virtual function to get these.
    theme_file_extension: []const u8,
    ui_name: []const u8,
};

pub const StringWidthOptions = struct {
    max_width: u32 = std.math.maxInt(u32),
};

pub const StringWidthResult = struct {
    width: u32,
    len: usize,
};

/// No UI. Main loop returns immediately without doing anything.
pub const none: Ui = .{
    .ptr = undefined,
    .vtable = &.{
        .run = runStub,
        .applyTheme = applyThemeStub,
        .applyDefaultTheme = applyDefaultThemeStub,
        .stringWidth = stringWidthStub,
        .defaultWidth = defaultWidthStub,
        .visibleRowCount = visibleRowCountStub,
        .widthNeededForColumn = widthNeededForColumnStub,
        .setTrueColour = setTrueColourStub,
        .theme_file_extension = "",
        .ui_name = "none",
    },
};

pub fn run(ui: Ui, zc: *ZC) u8 {
    return ui.vtable.run(ui.ptr, zc);
}

// TODO: Better error handling and reporting
pub fn applyTheme(ui: Ui, theme_filepath: [:0]const u8) ApplyThemeError!void {
    return ui.vtable.applyTheme(ui.ptr, theme_filepath);
}

pub fn applyDefaultTheme(ui: Ui) ApplyThemeError!void {
    return ui.vtable.applyDefaultTheme(ui.ptr);
}

/// Returns the file extension for the theme files used by this UI backend. Returned memory
/// should be statically allocated.
pub fn getThemeFileExtension(ui: Ui) []const u8 {
    return ui.vtable.theme_file_extension;
}

pub fn getUiName(ui: Ui) []const u8 {
    return ui.vtable.ui_name;
}

pub fn stringWidth(
    ui: Ui,
    bytes: []const u8,
    opts: StringWidthOptions,
) StringWidthResult {
    return ui.vtable.stringWidth(ui.ptr, bytes, opts);
}

pub fn defaultWidth(ui: Ui) u16 {
    return ui.vtable.defaultWidth(ui.ptr);
}

pub fn visibleRowCount(ui: Ui) u16 {
    return ui.vtable.visibleRowCount(ui.ptr);
}

pub fn widthNeededForColumn(ui: Ui, zc: *ZC, sheet: *Sheet, column_index: u32) u16 {
    return ui.vtable.widthNeededForColumn(ui.ptr, zc, sheet, column_index);
}

pub fn setTrueColour(ui: Ui, zc: *ZC, enable: bool) void {
    ui.vtable.setTrueColour(ui.ptr, zc, enable);
}

pub fn submitCommand(ui: Ui, cmd: [:0]const u8) void {
    ui.vtable.submitCommand(ui.ptr, cmd);
}

fn runStub(_: *anyopaque, _: *ZC) u8 {
    return 0;
}

fn applyThemeStub(_: *anyopaque, _: [:0]const u8) ApplyThemeError!void {}

fn applyDefaultThemeStub(_: *anyopaque) ApplyThemeError!void {}

fn stringWidthStub(_: *anyopaque, bytes: []const u8, opts: StringWidthOptions) StringWidthResult {
    const res = @import("zg").display_width.strWidth(bytes, .{
        .max_width = opts.max_width,
    });
    return .{ .width = @intCast(res.width), .len = res.len };
}

fn defaultWidthStub(_: *anyopaque) u16 {
    return 10;
}

fn visibleRowCountStub(_: *anyopaque) u16 {
    return std.math.maxInt(u16);
}

fn widthNeededForColumnStub(_: *anyopaque, _: *ZC, _: *Sheet, _: u32) u16 {
    return 1;
}

fn setTrueColourStub(_: *anyopaque, _: *ZC, _: bool) void {}

fn submitCommandStub(_: *anyopaque, _: [:0]const u8) void {}
