# Cellulator

Cellulator is a TUI spreadsheet calculator written in [Zig](https://ziglang.org).

## Portability

Cellulator works on Linux and MacOS. Zig's standard library is currently missing some constants and
types for other POSIX compliant OS's that are required by Cellulator, and may or may not build for
them.

## Terminal Compatibility

Cellulator should be compatible with most modern software terminals. Cellulator does not use
curses, instead using a [fork](https://github.com/efjimm/zig-spoon) of
[zig-spoon](https://git.sr.ht/~leon_plickat/zig-spoon). spoon uses vt-100 escape sequences to draw
to the screen, which should be supported by any modern terminal.

# Installation

Requirements:

- Zig master

Clone the repo and run `zig build -Doptimize=ReleaseSafe` to build the project. The resulting
binary will be in zig-out/bin by default.

Run `zig build test -fsummary` to run the tests.

# Usage

Cellulator is currently in early development. Expect missing features. If you actually intend on
using Cellulator, build it in ReleaseSafe mode to catch any latent bugs.

## Modes

Cellulator used mode-based input, like in vim. There are multiple modes in Cellulator:

 - normal
 - visual
 - visual select
 - command normal
 - command insert
 - command operator pending

Normal mode allows you to move around the sheet using vim-like motions and perform various
operations. Visual mode is used for performing operations on a range of cells interactively.
Command normal and command insert mode allow for editing the command buffer and submitting
commands. Command operator pending modes perform a specific action on a range of text delimited by
an inputted motion.

## Expressions

A cells value can be set in command mode via the syntax `cellname = expression`, where cellname is
the address of the cell cell, e.g. `a0`, `C52`, `ZZZ100`, and expression is any evaluable
expression. Number literals, cell references, cell ranges and builtin functions are supported, and
can be formed into more complex expressions using operators. Addition, subtraction, multiplication,
division and modulus, unary +/- are all supported operators. Cell ranges are defined as two cell
identifiers separated by a colon character, e.g. `a0:b3`. Cell ranges can only be used as arguments
to builtin functions, using them in other contexts will parse but produce an error on evaluation.

There are a number of builtin functions in Cellulator. All builtin functions take a variadic number
of arguments, which can include range expressions. All builtin functions must have at least one
argument. Each builtin may evaluate empty cells differently. The list of builtin functions is as
follows:

- @max
- @min
- @sum
- @prod
- @avg

Some examples of cell assignments:

- `a0 = 50`
- `a30 = 120 * 3 + (3 - 5)`
- `zzz500 = 2 * @sum(a0:z10, 5, 3, 100, b0:d3)`

## Commands

Program commands can be entered via placing a colon character as the first character of a command.
Pressing ':' in normal mode will do this automatically. What follows is a list of currently
implemented commands. Values surrounded in {} are optional.

- `w {filepath}` Save to the given filepath, or to the sheet's filepath if not specified.
- `e{!} filepath` Try to load from the given file. Will not continue if there are unsaved changes.
  This can be overridden by specifying a ! after 'e'.
- `q{!}` Quit the program. Will not continue if there are unsaved changes, unless ! is specified.

## Keybinds

Motions in command normal and command operator pending modes can be prefixed by a number, which
will repeat the following motion that many times. This does not currently work for any of the
*inside* or *around* motions.

###  Normal Mode

- `Return`, `C-m`, `C-j` Submit the current text as a command
- `j`, `Down` Move cursor down
- `k`, `Up` Move cursor up
- `h`, `Left` Move cursor left
- `l`, `Right` Move cursor right
- `:` Enter command insert mode
- `=` Enter command insert mode, with text set to `cellname = `, where cellname is the cell under the
  cursor
- `dd`, `x` Delete the cell under the cursor
- `Esc` Dismiss status message
- `0` Move cursor to the first populated cell on the current row
- `$` Move cursor to the last populated cell on the current row
- `gg` Move cursor to the first cell in the current column
- `G` Move cursor to the last cell in the current column
- `w` Move cursor to the next populated cell
- `b` Move cursor to the previous populated cell
- `f` Increase decimal precision of the current column
- `F` Decrease decimal precision of the current column
- `+` Increase width of current column if non-empty
- `-` Decrease width of current column if non-empty
- `u` Undo
- `U` Redo

### Visual Mode

- All normal mode motions
- `Esc`, `C-[` Enter normal mode
- `d`, `x` Delete the cells in the given range
- `o` Swap cursor and anchor
- `Alt-j` Move selection down
- `Alt-k` Move selection up
- `Alt-h` Move selection left
- `Alt-l` Move selection right

### Visual Select Mode

- All visual mode motions
- `Return` Write the selected range to the command buffer
- `Esc` Cancel select mode

### Command Insert Mode

- `Esc` Enter command normal mode
- `Return`, `C-m`, `C-j` Submit the current text as a command
- `Backspace`, `Del` Delete the character before the cursor and move backwards one
- `C-p`, `Up` Previous command
- `C-n`, `Down` Next command
- `C-a`, `Home` Move cursor to the beginning of the line
- `C-e`, `End` Move cursor to the end of the line
- `C-f`, `Right` Move cursor forward one character
- `C-b`, `Left` Move cursor backward one character
- `C-w` Delete the word before the cursor
- `C-u` Delete all text in the command buffer
- `C-v` Enter visual select mode

### Command Normal Mode

- `Esc` Leaves command mode without submitting command
- `h`, `Left` Move cursor left
- `l`, `Right` Move cursor right
- `k`, `Up` Previous command
- `j`, `Down` Next command
- `i` Enter command insert mode
- `I` Enter command insert mode and move to the beginning of the line
- `a` Enter command insert mode and move one character to the right
- `A` Enter command insert mode and move to the end of the line
- `s` Delete the character under the cursor and enters command insert mode
- `S` Deletes all text and enters command insert mode
- `x` Delete the character under the cursor
- `d` Enter operator pending mode, with deletion as the operator action
- `c` Enter operator pending mode, with change (delete and enter insert mode) as the operator action
- `D` Deletes all text at and after the cursor
- `C` Deletes all text at and after the cursor, and enters command insert mode
- `w` Moves cursor to the start of the next word
- `W` Moves cursor to the start of the next WORD
- `b` Moves cursor to the start of the previous word
- `B` Moves cursor to the start of the previous WORD
- `e` Moves cursor to the end of the next word
- `E` Moves cursor to the end of the next WORD
- `M-e` Moves cursor to the end of the previous word
- `M-E` Moves cursor to the end of the previous WORD
- `0`, `Home` Move cursor to the beginning of the line
- `$`, `End` Move cursor to the end of the line

### Command Operator Pending Mode

Performs the given operation on the text delimited by the next motion

- All motions in command normal mode
- `iw` Inside word
- `aw` Around word
- `iW` Inside WORD
- `aW` Around WORD
- `i(`, `i)` Inside parentheses
- `a(`, `a)` Around parentheses
- `i[`, `i]` Inside brackets
- `a[`, `a]` Around brackets
- `i{`, `i}` Inside braces
- `a{`, `a}` Around braces
- `i<`, `i>` Inside angle brackets
- `a<`, `a>` Around angle brackets
- `i"` Inside double quotes
- `a"` Around double quotes
- `i'` Inside single quotes
- `a'` Around single quotes
- `` i` `` Inside backticks
- `` a` `` Around backticks

## Miscellaneous Notes

Cellulator does not require any heap allocation for running the TUI, handling input, handling
commands or saving to a file. This means that Cellulator *should* continue to function on OOM and
allow for saving the current file, though this is relatively untested.
