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

## Statements / Commands

Cellulator differentiates between **statements** and **commands**. They can both be entered via the
command line. The main difference is that statements can be read from a file - this is how
Cellulator saves sheet state to disk.

There are currently 2 types of statements in Cellulator:

- `let {cell address} = {numerical expression}`
  - {cell address} is the text address of a cell, e.g. `A0`, `GL3600`
  - {numerical expression} is any [numerical expression](#numerical-expressions)
- `label {cell address} = {string expression}`
  - {string expression} is any [string expression](#string-expressions)

Commands can be entered via placing a colon character as the first character of a command.
Pressing ':' in normal mode will do this automatically. What follows is a list of currently
implemented commands. Values surrounded in {} are optional.

- `w {filepath}` Save to the given filepath, or to the sheet's filepath if not specified.
- `e{!} filepath` Try to load from the given file. Will not continue if there are unsaved changes.
  This can be overridden by specifying a ! after 'e'.
- `q{!}` Quit the program. Will not continue if there are unsaved changes, unless ! is specified.
- `fill (range) (value) {increment}`
  - Fills the given range with value, incrementing by increment each cell. Increment is applied
    left to right, top to bottom. Example: ":fill b1:d12 30 0.2"

## Numerical Expressions

Numerical expressions consist of numeric literals, cell references, cell ranges, builtin functions,
and numeric operators. They can be used on the right-hand side of the `=` in a `let` statement.

### Numeric literals

Number literals consist of a string of ASCII digit characters (0-9) and underscores, with at most
one decimal point. Underscores are ignored and are only used for visual separation of digits.
Underscores are not preserved when assigned to cells.

Examples:

- `1000000`
- `1_000_000`
- `1_234_567.000_089`

### Cell References

Cell references evaluate to the value of another cell. The value returned by a cell reference will be
updated if the expression contained by that cell changes.

Examples:

- `A0`
- `GP359`
- `crxp65535` (Last cell in a sheet)

### Cell Ranges

Cell ranges represent all cells in the inclusive square area between two positions. Cell ranges can
only be used in builtin functions. They are defined as two cell references separated with a colon
`:` character.

Examples:

- `A0:B0` (Contains 2 cells)
- `A0:A0` (Contains 1 cell)
- `D6:E3` (Contains 8 cells)

### Numeric Operators

The following is a list of all operators available for use with numeric literals, cell references
and builtins:

- unary `+` Positive numeric literal
- unary `-` Negative numeric literal
- binary `+` Addition
- binary `-` Subtraction
- `*` Multiplication
- `/` Division
- `%` Modulo division (remainder)
- `(` and `)` Grouping operators

### Builtin Functions

Builtin functions perform specific operations on an arbitrary number of arguments. Builtins are
used in the format `@builtin_name(argument_1, argument_2, argument_3, ...)`. Builtins must have at
least one argument. Builtins accept numeric literals, cell references, cell ranges and other
builtins as arguments.

The following is a list of all currently implemented builtin functions:

- `@sum` Returns the sum of its arguments
- `@mul` Returns the product of its arguments
- `@avg` Returns the average of its arguments
- `@min` Returns the smallest argument
- `@max` Returns the largest argument

## String Expressions

String expressions consist of string literals, cell references, and string operators. There are
currently no builtin functions that operate on strings. String expressions can be used on the
right hand side of the `=` in a `label` statement.

### String Literals

String literals consist of arbitrary text surrounded by single or double quotes. There is
currently no way to escape quotes inside of quotes.

Examples:

- 'This is a string'
- 'Double "quotes" inside of single quotes'
- "Single 'quotes' inside of double quotes"

### String Operators

The following is a list of all currently available string operators:

- `#` Concatenates the strings on the left and right
  - Examples:
    - `'This is a string' # ' that has been concatenated'`
    - `'1: ' # A0`
    - `A0 # B0`

## Keybinds

Motions in command normal and command operator pending modes can be prefixed by a number, which
will repeat the following motion that many times. This does not currently work for any of the
*inside* or *around* motions.

###  Normal Mode

- `1-9` Set count
- `0` Set count if count is not zero, otherwise move cursor to the first populated cell on the
  current row
- `j`, `Down` Move cursor down
- `k`, `Up` Move cursor up
- `h`, `Left` Move cursor left
- `l`, `Right` Move cursor right
- `:` Enter command insert mode
- `=` Enter command insert mode, with text set to `let cellname = `, where cellname is the cell
  under the cursor
- `\` Enter command insert mode, with text set to `label cellname = `, where cellname is the cell
  under the cursor.
- `e` Edit cell numeric expression
- `E` Edit cell label expression
- `dd`, `x` Delete the cell under the cursor
- `Esc` Dismiss status message
- `$` Move cursor to the last populated cell on the current row
- `gc` Move cursor to the count column
- `gr` Move cursor to the count row
- `gg` Move cursor to the first cell in the current column
- `G` Move cursor to the last cell in the current column
- `w` Move cursor to the next populated cell
- `b` Move cursor to the previous populated cell
- `f` Increase decimal precision of the current column
- `F` Decrease decimal precision of the current column
- `+` Increase width of current column if non-empty
- `-` Decrease width of current column if non-empty
- `aa` Fit column width to contents
- `u` Undo
- `U` Redo

### Visual Mode

- All normal mode motions
- `Esc`, `C-[` Enter normal mode
- `d`, `x` Delete the cells in the given range
- `o` Swap cursor and anchor
- `Alt-j` Move selection down count times
- `Alt-k` Move selection up count times
- `Alt-h` Move selection left count times
- `Alt-l` Move selection right count times

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
- `C-p`, `<Up>` History prev
- `C-n`, `<Down>` History next

### Command Normal Mode

- `Esc` Leaves command mode without submitting command
- `1-9` Set count
- `0` Set count if count is not zero, otherwise move cursor to the first populated cell on the
  current row
- `h`, `Left` Move cursor left count times
- `l`, `Right` Move cursor right count times
- `k`, `Up` Previous command count times
- `j`, `Down` Next command count times
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
- `w` Moves cursor to the start of the next word count times
- `W` Moves cursor to the start of the next WORD count times
- `b` Moves cursor to the start of the previous word count times
- `B` Moves cursor to the start of the previous WORD count times
- `e` Moves cursor to the end of the next word count times
- `E` Moves cursor to the end of the next WORD count times
- `M-e` Moves cursor to the end of the previous word count times
- `M-E` Moves cursor to the end of the previous WORD count times
- `$`, `End` Move cursor to the end of the line
- `k`, `<Up>` History prev
- `j`, `<Down>` History next

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
commands (not statements) or saving to a file. This means that Cellulator *should* continue to
function on OOM and allow for saving the current file, though this is relatively untested.
