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

Cellulator used mode-based input, like in vim. There are 3 modes in Cellulator: normal, command
normal, and command insert. Normal mode allows you to move around the sheet using vim-like motions
and perform various operations. Command normal and command insert mode allow for editing the
command buffer and submitting commands.

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

###  Normal Mode

- `Return`, `C-m`, `C-j` Submit the current text as a command
- `h`, `Left` Move cursor left
- `j`, `Down` Move cursor down
- `k`, `Up` Move cursor up
- `l`, `Right` Move cursor right
- `:` Enter command insert mode
- `=` Enter command insert mode, with text set to `cellname = `, where cellname is the cell under the
  cursor
- `D`, `x` Delete the cell under the cursor
- `Esc` Dismiss status message
- `0` Move cursor to the first populated cell on the current row
- `$` Move cursor to the last populated cell on the current row
- `g` Move cursor to the first cell in the current column
- `G` Move cursor to the last cell in the current column
- `w` Move cursor to the next populated cell
- `b` Move cursor to the previous populated cell
- `f` Increase decimal precision of the current column
- `F` Decrease decimal precision of the current column

### Command Insert Mode

- `Esc` Enter command normal mode
- `Return`, `C-m`, `C-j` Submit the current text as a command
- `Backspace`, `Del` Delete the character before the cursor and move backwards one
- `C-a`, `Home` Move cursor to the beginning of the line
- `C-e`, `End` Move cursor to the end of the line
- `C-f`, `Right` Move cursor forward one character
- `C-b`, `Left` Move cursor backward one character
- `C-w` Delete the word before the cursor
- `C-u` Delete all text in the command buffer

### Command Normal Mode

- `Esc` Leaves command mode without submitting command
- `h`, `Left` Move cursor left
- `l`, `Right` Move cursor right
- `i` Enter command insert mode
- `I` Enter command insert mode and move to the beginning of the line
- `a` Enter command insert mode and move one character to the right
- `A` Enter command insert mode and move to the end of the line
- `s` Delete the character under the cursor and enters command insert mode
- `S` Deletes all text and enters command insert mode
- `x` Delete the character under the cursor
- `d` Deletes the text delimited by the next inputted motion, or nothing if Escape is pressed
- `c` Deletes the text delimited by the next inputted motion and enters command insert mode
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

## Miscellaneous Notes

Cellulator does not require any heap allocation for running the TUI, handling input, handling
commands or saving to a file. This means that Cellulator *should* continue to function on OOM and
allow for saving the current file, though this is all relatively untested.
