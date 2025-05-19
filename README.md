# Multibuffers in Neovim

Experimental multibuffers API for neovim. Expect breaking changes and some instability. This repository aims to be strictly an API for creating and managing multibuffers. What is a multibuffer? A multibuffer is a single buffer that contains editable regions of other buffers.

Strategy:

* `multibuffer://` schema for buffer name
* reads and writes handled through `BufReadCmd` and `BufWriteCmd`
* customizable virtual text above each section in multibuffer to denote what buffer region is below
* line numbers of each region through signcolumn

API:

* creating a multibuffer
* adding regular buffer(s) to a multibuffer
* customizing virtual text above regions
* getting real buffer and real row/column from line number in multibuffer
