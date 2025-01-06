This is a schizo document that contains basically every idea I thought should be written down while
working on cellulator. It's completely unorganised and some parts are very outdated. I thought it
might be an interesting read so I committed it. The stuff at the top is probably newer.

- Eliminate recursion
  - Will run into stack overflows with big data. An older implementation of `markDirty` caused
  - one on a large input sheet.
- Commands for every sheet operation
  - Allows for writing "scripts" for unit tests!
- Support for justifying strings
- Generate fuzzer output files from the build system
- Reconsider using ranges that store references to rows/cols, instead reverting back to using u32
  x/y positions.
  - Original intent was to avoid having to update the x/y value of every position in the r-tree
    when a row/column was inserted/deleted.
  - This makes inserting/deleting rows/columns faster, at the expense of adding a level of
    indirection every time a range is resolved.
  - Now that all data structures are backed by arrays, iterating over all the x/y values to update
    them would be trivial *and* fast.
  - Deleting/inserting rows/columns is relatively rare compared to resolving ranges which is
    extremely common.
  - The planned strategy for deleting rows/columns is hazy and would rely on tombstones in the rows/
    columns skiplists. The alternative would require no strategy!
  - Need to benchmark!
- Reconsider rtree
  - Not well suited to constantly mutating data
  - Deletions are particularly expensive.
    - Can cause every single value in the tree to have to be re-inserted.
  - Uses lots of recursion (bad.)
- Store undos and redos in a single list and just keep an index into where the current undo is.
  When an undo happens we can just invert the Undo operation at the index and decrement the index
  by one. When a redo happens we invert the operation at index+1 and increment the index by one.

- **WRITE BETTER TESTS**
- !!! **PERFORMANCE PROFILING AND BENCHMARKS** !!!

- Figure out how to handle deleting a row/col in the range tree
  - Should figure itself out by recalculating the bounding ranges on removal of the cells in the row/column

Dependency information needs to be retained somehow after deleting a row/column. References to
deleted rows/cols can't stay in the rtree, as they mess up range calculations.

Should be stored in undos.

Need to handle ranges that are anchored on a row/col that is being removed.
Need to handle branch ranges being anchored on a deleted row/col.

Modify the affected keys directly, and then traverse the whole tree and recalc all ranges?
'Easy' to implement.

- Relative cell references
- 'Precision as shown' option

- Implement constant folding
  - Full expressions still need to exist in the Ast for printing purposes
    - Do they tho?
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

- Interpolation in strings
  - Allow for any arbitrary numeric or string expression
  - format is "{specifier:expr}"
    - 'specifier' is either 'd' or 's' for numeric/string expressions respectively
    - 'expr' is any numeric or string expression, depending on the specifier
  - Expression's AST is part of the overall AST
- Undo/redo for command mode
- Detailed error reporting in parser

- Multiple sheets
- Document code
- Rebinding keys

- File formats
  - csv
  - xls / xlsx

- Store string dependencies in a single buffer in Sheet
  - Undos and redos are sequential in time, so when we nuke redos we can just chop off the end
    portion of the buffer.
- Goto command
- Consider changing functionality of `w` motion and adding `e` motion
  - Currently `w` just goes to the next populated cell. It may be better to have it function
    similar to vim's `w`, where it goes to the first cell in the next set of column-continuous cells.
    This may make it easier to work with 'blocks' of values.
    Going to the next populated cell can still be done, either by hitting `w` if the current/next cell
    is blank or pressing `l` if not.
- Make string concat operator work on ranges
- Alignment of string in text cells
- String repeat builtin

- Limits documentation
- Multi-threaded evaluation of cells
- Flush 'cold' cells to disk when there are many
- Per-cell colors
- GNUPlot integration

- Optimize aroundDelimiters function
