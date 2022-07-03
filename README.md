# bookmarks.nvim

A Bookmarks Plugin With Global File Store For Neovim Written In Lua.

## Requirements

- Neovim >= 0.7.0

## Installation

With [packer.nvim]:

```lua
use {
'tomasky/bookmarks.nvim',
-- tag = 'release' -- To use the latest release
}

```

## Usage

For basic setup with all default configs using [packer.nvim]

```lua
use {
  'tomasky/bookmarks.nvim',
  config = function()
    require('bookmarks').setup()
  end
}
```

Here is an example with most of the default settings:

```lua
require('bookmarks').setup {
  save_file = "$HOME/.bookmarks",
  on_attach = function(bufnr)
    local bm = require "bookmarks"
    local map = vim.keymap.set
    map("n","mm",bm.bookmark_toggle) -- mark signs or not signs
    map("n","mc",bm.bookmark_clean) -- clean all marks in local buffer
    map("n","mi",bm.bookmark_ann) -- add mark annotation
  end
}
```

## Credits

- [gitsigns.nvim] most of lua functions come from this plugin
- [vim-bookmarks](https://github.com/MattesGroeger/vim-bookmarks) inspired by this vim plugin
- [possession.nvim](https://github.com/jedrzejboczar/possession.nvim) some util functions

[gitsigns.nvim]: https://github.com/lewis6991/gitsigns.nvim
[packer.nvim]: https://github.com/wbthomason/packer.nvim
