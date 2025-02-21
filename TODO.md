This is a schizo document that contains basically every idea I thought should be written down while
working on cellulator. It's completely unorganised and some parts are very outdated. I thought it
might be an interesting read so I committed it. The stuff at the top is probably newer.

- Make kcov reports a flag rather than a separate step
- Eliminate recursion
  - Will run into stack overflows with big data. An older implementation of `markDirty` caused
    one on a large input sheet.
- Support for justifying strings
- Generate fuzzer output files from the build system
- Store undos and redos in a single list and just keep an index into where the current undo is.
  When an undo happens we can just invert the Undo operation at the index and decrement the index
  by one. When a redo happens we invert the operation at index+1 and increment the index by one.
- Unify command and statement parsing

- Batch undo cell inserts / deletes
- Improve fill implementation
- Remove critbit tree implementation in favour of 1d PH-tree
  - Add prefix functions to phtree

- Features
  - Justify text
  - Copy cells
    - Absolute references
    - Virtual copies of cell expressions
      - Would significantly reduce memory usage when copying many cells
      - Requires making cell references in AST nodes relative
  - 'Precision as shown' option
  - Insert cells feature from libreoffice
  - Highlight cells in expression of hovered cell

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
