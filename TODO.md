This is a schizo document that contains basically every idea I thought should be written down while
working on cellulator. It's completely unorganised and some parts are very outdated. I thought it
might be an interesting read so I committed it. The stuff at the top is probably newer.

- Completions for commands
- Support generic flags in commands and change :put-adjust to be :put -a    :put --adjust

- Fix deleting backwards with empty CLI
- Fix :delete command on deleting empty cell

- Per-sheet cursor
- Fix cli text not scrolling when it goes off screen
  - Make it wrap to multiple lines instead!
    - Much easier
    - Better visuals

- Performance: Store cached cell values separately from ASTs
- Make string concat evaluation not shitty
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
- Handle commands better
  - Usage text
  - Command descriptions
  - Standard way of signifying if parameters are required and what type they should be
  - Automatically check validity of entered commands against a declared structure
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
  - Web UI could have the function return HTML or CSS

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
- Detailed error reporting in parser

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
