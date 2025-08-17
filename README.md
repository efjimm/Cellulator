# Cellulator

Cellulator is a terminal based, vim-like spreadsheet calculator.

Cellulator primarily targets Linux. MacOS and FreeBSD 0.14 targets compile successfully but are
otherwise untested.

# Installation

Requirements:

- Zig master

Clone the repo and run `zig build -Doptimize=ReleaseSafe` to build the project. The resulting
binary will be in zig-out/bin by default.

Run `zig build --summary new test` to run the tests.

# Usage

Cellulator is currently in early development. Expect missing features. If you actually intend on
using Cellulator, build it in ReleaseSafe mode to catch any latent bugs.

The maximum sheet size is $2^{32}$ rows by $2^{32}$ columns.

## Modes

Cellulator is a modal program like vim. There are several modes in Cellulator:

 - normal
 - visual
 - visual select
 - command normal
 - command insert
 - command operator pending

Normal mode allows you to move around the sheet using vim-like motions and perform various
operations. Visual mode is used for performing operations on a range of cells interactively.

Command modes are for editing the text in the command line. vim-style text editing is available for
editing the command line buffer, hence the multiple command modes.

## Statements and Commands

Cellulator differentiates between **statements** and **commands**. They can both be entered via the
command line. The main difference is that statements can be read from a file - this is how
Cellulator saves sheet state to disk.

There is currently only one type of statement in cellulator:

```
let CELL = EXPR
```

CELL is the address of a cell, e.g. `A0`, `GL3600`
EXPR is any [expression](#expressions)

Commands can be entered via placing a colon character as the first character of a command.
Pressing ':' in normal mode will do this automatically. What follows is a list of currently
implemented commands. Values surrounded in {} are optional.

A help dialogue for commands can be displayed by passing a `-h` flag to the command anywhere in
the argument list. Passing the `-h` flag will only display the help dialogue and will not run the
command.

Currently implemented commands are:

```
:w
:e
:q
:q!
:fill
:fill-expr
:bw
:be
:undo
:redo
:delete
:delete-cols
:delete-rows
:insert-cols
:insert-rows
:text-align
:set
:unset
:yank
:put
:p
:put-adjust
:pa
:sheet-close
:sheet-close!
:sc
:sc!
:sheet-rename
:go
```

Type the command name followed by `-h` to see usage information for each command.

## Expressions

Expressions consist of number/string literals, cell references, cell ranges, builtins,
and operators. They can be used on the right-hand side of the `=` in a `let` statement.

### Number literals

Number literals consist of a string of ASCII digit characters (0-9) and underscores, with at most
one decimal point. Underscores are ignored and are only used for visual separation of digits.
Underscores are not preserved when assigned to cells.

Examples:

- `1000000`
- `1_000_000`
- `1_234_567.000_089`

### String Literals

String literals consist of arbitrary text surrounded by single or double quotes. There is
currently no way to escape quotes inside of quotes.

Examples:

- 'This is a string'
- 'Double "quotes" inside of single quotes'
- "Single 'quotes' inside of double quotes"

### Cell References

Cell references evaluate to the value of another cell. The value returned by a cell reference will be
updated if the expression contained by that cell changes.

Examples:

- `A0`
- `GP359`
- `crxp65535`

### Cell Ranges

Cell ranges represent all cells in the inclusive square area between two positions. Cell ranges can
only be used in builtin functions. They are defined as two cell references separated with a colon
`:` character.

Examples:

- `A0:B0` (Contains 2 cells)
- `A0:A0` (Contains 1 cell)
- `D6:E3` (Contains 8 cells)

### Truthiness

Cellulator has logical and equality operators but does not have a boolean data type. Instead, values
have truthiness. An empty cell or the number zero is interpreted as false, and anything else is
interpreted as true.

### Numeric Operators

The following is a list of all operators that return number values. They try to convert non-number
operands (e.g. strings) to numbers. Strings that cannot be converted to numbers will return an
InvalidCoercion error.

- unary `+` Positive value (absolute value)
- unary `-` Negative value (* -1)
- binary `+` Addition
- binary `-` Subtraction
- `*` Multiplication
- `/` Division
- `%` Modulo division (remainder)
- `(` and `)` Grouping operators

The following operators return 0 for false and 1 for true:

- `>` Greater than
- `<` Less than
- `>=` Greater than or equal to
- `<=` Less than or equal to
- `==` Equal
- `!=` Not equal

### Logical Operators

- `and` Returns it's first operand if it is false, otherwise returns it's second operand.
- `or` Returns it's first argument if not false, otherwise returns it's second operand.
- `!` Logical not. Returns either 0 or 1 depending on the truthiness of it's operand.

Note that due to the `and`/`or` operators returning their arguments instead of a true/false value
they can be used like conditionals. For example, `A0 > B0 and "Greater" or "Not greater"` will
evaluate to `"Greater"` when A0 > B0 and "Not greater" otherwise.

### String Operators

The following is a list of operators that return string values. They try to convert non-string
operands to strings. Converting a number to a string never fails outside of OOM situations.

- `#` Concatenates the strings on the left and right
  - Examples:
    - `'This is a string' # ' that has been concatenated'`
    - `'1: ' # A0`
    - `A0 # B0`

### Builtins

There are two types of builtins: functions and constants. Builtin functions are used in the
format `@builtin_name(argument_1, argument_2, argument_3, ...)`. Different builtin functions take
and return different types and numbers of arguments. Builtin constants are used in the format
`@builtin_name`.

The following builtin functions take an arbitrary number of arguments and coerce them to numbers.
They may also take ranges as arguments.

- `@sum` Returns the sum of its arguments
- `@prod` Returns the product of its arguments
- `@avg` Returns the average of its arguments.
- `@min` Returns the smallest argument.
- `@max` Returns the largest argument.
- `@count` Returns the count of number variables.
- `@countAll` Returns the count of any type of variable.

The following builtin functions take one argument and coerce it to a number:

- `@sqrt` Returns the square root of the given number.
- `@round` Rounds the given number to the nearest integer. If two integers are equally close, rounds away from zero.
- `@floor` Returns the largest integral value not greater than the given number.
- `@ceil` Returns the smallest integral value not less than the given number.
- `@log(base, x)` Returns the logarithm of x for the provided base.

The following builtins take one argument and coerce it to a string. They may *not* take a range
as an argument.

- `@upper` Returns the ASCII uppercase version of its argument as a string.
- `@lower` Returns the ASCII lowercase version of its argument as a string.
- `@len` Returns the number of grapheme clusters in the given string.

The following builtins are constants and do not take any arguments or parentheses:

- `@pi` Archimede's constant (n).
- `@e` Euler's number (e).

The following builtins take a single range as an argument:

- `@width` Returns the width of the given range.
- `@height` Returns the heigh of the given range.

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
- `C-f` Page down
- `C-b` Page up
- `C-d` Half page down
- `C-u` Half page up
- `:` Enter command insert mode
- `=` Enter command insert mode, with text set to `let cellname = `, where cellname is the cell
  under the cursor
- `e` Edit the expression of the current cell
- `dd`, `x` Delete the cell under the cursor
- `Esc` Dismiss status message
- `$` Move cursor to the last populated cell on the current row
- `gc` Move cursor to the count column
- `gr` Move cursor to the count row
- `gg` Move cursor to the first cell in the current column
- `G`, `ge` Move cursor to the last cell in the current column
- `w` Move cursor to the next populated cell
- `b` Move cursor to the previous populated cell
- `f` Increase decimal precision of the current column
- `F` Decrease decimal precision of the current column
- `+` Increase width of current column if non-empty
- `-` Decrease width of current column if non-empty
- `aa` Fit column width to contents
- `u` Undo
- `U` Redo
- `<` Align text under cursor to the left
- `>` Align text under cursor to the right
- `|` Align text undor cursor to the center
- `gn` Go to the next sheet
- `gp` Go to the previous sheet
- `C-wq` Close the current sheet
- `yy` Yank selected cell
- `p` Put yanked cells at cursor, copying expression exactly
- `P` Put yanked cells at cursor, adjusting cell references in the expressions
- `ic` Insert count columns at the cursor
- `dc` Delete count columns at the cursor
- `ir` Insert count rows at the cursor
- `dr` Delete count rows at the cursor

### Visual Mode

- All normal mode motions
- `Esc`, `C-[` Enter normal mode
- `d`, `x` Delete the cells in the given range
- `o` Swap cursor and anchor
- `Alt-j` Move selection down count times
- `Alt-k` Move selection up count times
- `Alt-h` Move selection left count times
- `Alt-l` Move selection right count times
- `yy` Yank selected cells and enter normal mode

### Visual Select Mode

- All visual mode motions
- `Return` Write the selected range to the command buffer
- `Esc` Cancel select mode

### Command Insert Mode

- `Esc` Enter command normal mode
- `Return`, `C-m`, `C-j` Submit current command or completion
- `Backspace`, `Del` Delete the character before the cursor and move backwards one
- `C-p`, `Up` Previous command
- `C-n`, `Down` Next command
- `C-a`, `Home` Move cursor to the beginning of the line
- `C-e`, `End` Move cursor to the end of the line
- `C-f`, `Right` Move cursor forward one character
- `C-b`, `Left` Move cursor backward one character
- `C-w` Delete the word before the cursor
- `C-u` Delete all text before the cursor
- `C-k` Delete all text after the cursor
- `C-v` Enter visual select mode
- `C-p`, `<Up>` History prev
- `C-n`, `<Down>` History next
- `<Tab>` Next completion
- `<S-<Tab>>` Previous completion

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

## Lua Scripting

Cellulator integrates Lua for scripting and configuration purposes. Currently the API is a very
small proof of concept and not at all stable.

At startup Cellulator runs the Lua file at `$XDG_CONFIG_HOME/cellulator/init.lua`. A global variable
`zc` is exposed which provides functionality to interact with Cellulator.

Here is an example `init.lua`:

```lua
zc.events:subscribe('Start', function()
  -- Set theme on startup
  zc:command('set theme mytheme')
end)

zc.events:subscribe('SetCell', function(pos)
  -- Move the cursor down one
  zc:set_cursor{ x = pos.x, y = pos.y + 1 }

  -- Set the cell directly to the right to (expr) * 2
  zc:set_cell({ x = pos.x + 1, y = pos.y }, '(' .. expr .. ') * 2')
end)

zc.events:subscribe('UpdateFilePath', function(sheet_name, new_path)
  -- Display a status message when we open a new file
  zc:status{'Opened file "' .. new_path  .. '" in ' .. sheet_name}
end)
```

### Events

Cellulator has a mechanism for emitting events, which Lua code can register handlers for. Lua code
can also register and emit its own events.

### Themes

When a theme is set using the `:set THEME_NAME` command, the corresponding theme file at
`${XDG_CONFIG_HOME}/cellulator/themes/terminal/THEME_NAME.lua` is loaded. For the terminal UI, theme
files are lua files that when executed return a table containing the theme definition. The keys of
the returned table correspond to a specific UI element to be styled. Omitted keys are left at their
default value.

Here is an (extremely ugly) example theme:

```lua
local bg = '#ff0000'
local fg = '#c0c5ce'
local high_bg = '#6984ae'
local high_fg = '#292d36'
local high = { fg = high_fg, bg = high_bg }
local plain= { fg = fg, bg = bg }

return {
  filepath = { fg = fg, bg = bg, attrs = { 'bold', 'underline' } },
  status_line = { fg = '#00ff00', bg = '#0000ff' },
  command_line = { fg = '#00ff00', bg = '#0000ff' },
  expression = { fg = '#00ff00', bg = bg },

  column_heading_unselected = plain,
  column_heading_selected   = high,
  row_heading_unselected    = plain,
  row_heading_selected      = high,

  cell_blank_selected    = high,
  cell_blank_unselected  = plain,
  cell_number_selected   = high,
  cell_number_unselected = plain,
  cell_text_selected     = high,
  cell_text_unselected   = plain,
  cell_error_selected    = high,
  cell_error_unselected  = plain,

  selected_sheet = high,
  unselected_sheet = plain,
}
```

See `src/Tui.zig` for a list of valid element names.
