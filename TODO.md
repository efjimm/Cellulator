This is a schizo document that contains basically every idea I thought should be written down while
working on cellulator. It's completely unorganised and some parts are very outdated. I thought it
might be an interesting read so I committed it. The stuff at the top is probably newer.

# TODO

- MAKE CELL EVALUATION NON RECURSIVE!!!!
  - AAAAAAAAAAAAAAAAH!!!!!
- Serialize column widths
- Serialize column precision
- Escape single quotes in printed string values

- Implement tuple indexing and functions for manipulation
- More stream functionality
  - @any
  - Collect to tuple or array
  - Generic reduce function
  - User-defined pipeline steps
- Number arrays with vectorized operations
- Structs/maps/objects/records/product types/whatever
- Regex
- Parallel streams

- Update the README

- :wq command
- :wqa command

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
  - Arrays/Tuples
  - Native arrays
    - Array of "native" float/integer types instead of any type
  - Structs
- Streams
  - map filter reduce
- Anonymous functions with implicit arguments (placeholders)
- Maybe remove @ prefix from builtins
- Vet cell literal boundaries in evaluation
- Update README
- Tests

- 32 bit builds
- Vet uses of usize

- Opening a new buffer while the current buffer is empty with no undos should replace the empty buffer
  instead of opening a new one

- Cellulator as an interpreter
  - Treat each line as a command
  - Different from loading files
    - File loads are specialised and have lots of limitations to improve load speed.
  - REPL
    - Essentially just the command line without the UI
    - We have vim keybindings!

- Make string evaluation not complete SHIT

- Throw nicer errors with new type tracking in parser
- Make all index types enums
- MultiArrayList.Slice wrapper that uses index types, like PhTree.Slice
- Remove dynamic range ast node
- Clean up handling of cell inserts
  - Deduplicate common logic
- Map expressions to cells
  - Allows better sharing of expressions between cells
  - Can store a list of volatile expressions instead of volatile cells
- Fold keyword
- Reduce size of Cell struct
- Labels for cells
- Custom functions implemented in Lua
- Select around blocks
- Replace mode in cli
- Commands not being respected when opening sheet
- Tables with headings
- Pipe operators
  - Filtered range AST node
- Errors as values
  - count/countAll should work on cell references that are errors

## Statements and Commands

- Reduce operators instead of builtins
  - |+, |-, ||

- Lists of cells, e.g. `[1, a0, d10:g20]`
  - Could be used with reduce operators

- Cell references as values
  - Explicit reference required, e.g. &A0
    - Making references implicit would mean a0 + b0 wouldn't work, you'd have to deref them to get
      their values. Operators could be made to implicitly deref their operands but that's annoying
      for other reasons.
    - Still supports reactive updates as expected
    - Cell literals implicitly coerce to references in contexts that require references
  - Ranges are always a reference, because dereferencing a range makes no sense.
    - Similar to a slice in Zig
    - Could be indexed and sliced
  - Allow arbitrary expressions on the left side of the assignment operator

- Row and column to cell ref
- String to cell ref
- Penis operator
- Boolean type

- Partial caching for expressions
- Implement anonymous functions
- Implement conditional functions, conditional ranges
  - A conditional range is a range that associated with a predicate
    - The predicate is an anonymous function that filters cells from that range
    - Operations on that range will only use cells within the range satisfying the predicate
- Implement filtering rows
- Command for freezing rows / columns

## Miscellaneous

- Rip out stupid slow test
- Write better tests

- Reset count when changing modes
- Move cursor back to start position after interactively inserting range in command line

# OLD TODO

- Implement basically everything mentioned in sc-im's help page
  - Filter rows
  - Freeze rows/columns

- Tests for all builtins and operators
- Boolean operators and functions
- Conditional operators
- Text manipulation
  - substitute
  - indexOf
- Arbitrary expressions over ranges of cells
- User defined functions
- Arbitrary identifiers

- Allow setting a style for individual cells/ranges
- Format strings for cells

- Support generic flags in commands
  - change :put-adjust to be :put -a    :put --adjust

- Per-sheet cursor
- Fix cli text not scrolling when it goes off screen
  - Make it wrap to multiple lines instead!
    - Much easier
    - Better visuals

- Performance: Store cached cell values separately from ASTs
- Filtering rows/columns
- Sorting rows/columns
- OOM resistance
  - Should not crash
  - Basic functionality should still work
    - UI
    - Command line
    - Saving

- Interpolation in strings
  - Allow for any arbitrary numeric or string expression
  - format is "{specifier:expr}"
    - 'specifier' is either 'd' or 's' for numeric/string expressions respectively
    - 'expr' is any numeric or string expression, depending on the specifier
  - Expression's AST is part of the overall AST

- Store undos and redos in a single list and just keep an index into where the current undo is.
  When an undo happens we can just invert the Undo operation at the index and decrement the index
  by one. When a redo happens we invert the operation at index+1 and increment the index by one.
- Unify command and statement parsing
- Multithreading
  - Nvidia paper for building radix trees in parallel
    - http://research.nvidia.com/sites/default/files/publications/karras2012hpg_paper.pdf

- Allow registering new commands from lua

- Command mode
  - Undos and redos
  - File completion

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

- Text alignment
  - Can be implemented via Lua with the three aformentioned features.

- Features
  - Better error reporting when setting themes
  - Deduplicate repeated commands in command history
  - Expandable, scrollable status messages for more verbose error messages and documentation
  - Rows spanning multiple lines
  - Align text in cells
    - Correctly adjust when updating rows/columns
    - Integrate with undos
    - Integrate with serialization
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

- Rebinding keys

- File formats
  - csv
  - xls / xlsx

- Undos and redos are sequential in time, so when we nuke redos we can just chop off the end
  portion of the buffer.
- Consider changing functionality of `w` motion and adding `e` motion
  - Currently `w` just goes to the next populated cell. It may be better to have it function
    similar to vim's `w`, where it goes to the first cell in the next set of column-contiguous cells.
    This may make it easier to work with 'blocks' of values.
    Going to the next populated cell can still be done, either by hitting `w` if the current/next cell
    is blank or pressing `l` if not.
- Make string concat operator work on ranges
- String repeat builtin

- Limits documentation
- Multi-threaded evaluation of cells
- Per-cell colors
- GNUPlot integration
