This is a schizo document that contains basically every idea I thought should be written down while
working on cellulator. It's completely unorganised and some parts are very outdated. I thought it
might be an interesting read so I committed it. The stuff at the top is probably newer.

# TODO

- Add TUI styles for different cell values
- Rework TUI cell width handling
- Remove some unnecessary formatted printing to improve compile times

- Bug: Cells are unnecessarily evaluated once after deletion.
- Bug: Cell expression not shown for cells with simple values and no AST
- Bug: Expand column to width not correct with wide characters
- Bug: Assertion trip when loading file header with empty line or something
- Bug: fill command doesn't update cell dependents
- Serialize column widths
- Serialize column precision

- Implement integer types
- Implement tuple indexing and functions for manipulation
- More stream functionality
  - Generic reduce function
  - User-defined pipeline steps
- Number arrays with vectorized operations
- Structs/maps/objects/records/product types/whatever
- Regex
- Parallel streams

- Update the README

- Runtime dependency tracking
  - Static tracking is too imprecise with features like closures, pipelines, references.
- Re-think core data structure
  - PH-trees are a general solution with acceptable performance for almost all operations,
    except row/column manipulations.
    - Row/column manipulations in large (1m+ cells) sheets have bad performance
  - What SHOULD have been chosen was a solution with exceptional common-case performance,
    with rarer cases mattering less.
    - In a typical spreadsheet usecase:
      - Setting individual cells is very common
      - Reading invidual cells is very common
      - Reading columns of cells is very common
      - Inserting/removing rows is very common
      - Other operations are less common
  - Idea: B+tree storing blocks of rows
    - Each row block stores a fixed amount of data in a column-major order.
      This way columns of numbers can be stored as a dense f64 array.
    - [1024]f64; BitSet(1024); ArrayHashMap(u10, Value);
    - Bit set for tracking 'holes' in dense number data.
    - ArrayHashMap for sparse data and non-number data.
  - BENCHMARK BENCHMARK BENCHMARK
- Format strings for functions/builtins/pipelines properly
- Unbound keys should input their unmodified versions in command insert mode

- Globals / Named cells
  - Some way to view globals
- Aggregate types
  - Native arrays
    - Array of "native" float/integer types instead of any type
  - Structs
- Anonymous functions with implicit arguments (placeholders)
- Consider removing @ prefix from builtins
- Update README

- 32 bit builds
- Vet uses of usize

- Cellulator as an interpreter
  - Treat each line as a command
  - Different from loading files
    - File loads are specialised and have lots of limitations to improve load speed.

- Clean up handling of cell inserts
  - Deduplicate common logic
- Labels for cells
- Custom functions implemented in Lua
- Select around blocks
- Replace mode in cli
- Tables with headings
- Errors as values
  - count/countAll should work on cell references that are errors

## Statements and Commands

- Row and column to cell ref
- String to cell ref
- Implement filtering rows
- Command for freezing rows / columns

## Miscellaneous

- Write better tests
- Reset count when changing modes
- Move cursor back to start position after interactively inserting range in command line

# OLD TODO

- Implement basically everything mentioned in sc-im's help page

- String manipulation functions
- Allow setting a style for individual cells/ranges
- Format strings for cells

- Support generic flags in commands
  - change :put-adjust to be :put -a    :put --adjust

- Per-sheet cursor

- Performance: Store cached cell values separately from ASTs
- Filtering rows/columns
- Sorting rows/columns

- Interpolation in strings
  - Allow for any arbitrary numeric or string expression
  - format is "{specifier:expr}"
    - 'specifier' is either 'd' or 's' for numeric/string expressions respectively
    - 'expr' is any numeric or string expression, depending on the specifier
  - Expression's AST is part of the overall AST

- Store undos and redos in a single list and just keep an index into where the current undo is.
  When an undo happens we can just invert the Undo operation at the index and decrement the index
  by one. When a redo happens we invert the operation at index+1 and increment the index by one.
- Allow registering new commands from lua

- Command mode
  - Undos and redos

- Make the "has changes" indicator reset when undo back to initial state

- Handle sheet list overflowing screen
- Add fzf-like popup for searching sheets
- Copy sheets
- Flush inactive sheets to disk as binary data
  - Store a checksum of the data in-memory to ensure integrity
- Read-only sheets
- Actions across sheets

- Allow associating Lua data with cells

- Allow providing a custom format function for displaying cells
  - Would be exposed via the UI's Lua API, and differ depending on UI backend
  - Doesn't need to be fast, as the number of cells on screen is small

- Allow defining custom undo types in Lua

- Features
  - Better error reporting when setting themes
  - Deduplicate repeated commands in command history
  - Expandable, scrollable status messages for more verbose error messages and documentation
  - Rows spanning multiple lines
  - 'Precision as shown' option
  - Random numbers
  - Insert cells feature from libreoffice
  - Highlight cells in expression of hovered cell
  - Go to definition for cell references
  - Show the expression and cached value for hovered over cells in command mode

- Investigate FAP sets

- Lua
  - Expose cells
  - Functions
    - Bind keys
    - Delete cells
    - Set text cells
    - Run commands
    - Register new commands
  - More events
    - DeleteCell
    - ChangeMode
    - FileOpen
    - FileClose
    - FileSave(Pre/Post)
    - Quit
    - Input

- Undo/redo for command mode
- Even more detailed error reporting in parser

- File formats
  - xls / xlsx

- Consider changing functionality of `w` motion and adding `e` motion
  - Currently `w` just goes to the next populated cell. It may be better to have it function
    similar to vim's `w`, where it goes to the first cell in the next set of column-contiguous cells.
    This may make it easier to work with 'blocks' of values.
    Going to the next populated cell can still be done, either by hitting `w` if the current/next cell
    is blank or pressing `l` if not.
- String repeat builtin

- Limits documentation
- Multi-threaded evaluation of cells
- GNUPlot integration
