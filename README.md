# zc - A tui spreadsheet program written in Zig

zc has its origins from an attempted incremental rewrite of
[sc](https://github.com/andmarti1424/sc-im) in zig. This proved to be more difficult than
anticipated, due to the codebase being extremely tightly coupled with liberal usage of global state,
random isolated heap allocations, deeply nested call stacks and so on. Thus it was decided to start
from scratch.
