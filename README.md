# bookmarks.nvim

A Bookmarks Plugin With Global File Store For Neovim Written In Lua.

## Features

- Display different icons according to annotation keywords
  ![](http://raw.github.com/tomasky/tomasky/main/bookmarksfeatures2.png)
- open bookmarks in a quickfix list
- search marks with Telescope
  ![](http://raw.github.com/tomasky/tomasky/main/bookmarksfeatures1.png)

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
  save_file = vim.fn.expand "$HOME/.bookmarks", -- bookmarks save file path
  keywords =  {
    ["@t"] = "☑️ ", -- mark annotation startswith @t ,signs this icon as `Todo`
    ["@w"] = "⚠️ ", -- mark annotation startswith @w ,signs this icon as `Warn`
    ["@f"] = "⛏ ", -- mark annotation startswith @f ,signs this icon as `Fix`
    ["@n"] = " ", -- mark annotation startswith @n ,signs this icon as `Note`
  },
  on_attach = function(bufnr)
    local bm = require "bookmarks"
    local map = vim.keymap.set
    map("n","mm",bm.bookmark_toggle) -- add or remove bookmark at current line
    map("n","mi",bm.bookmark_ann) -- add or edit mark annotation at current line
    map("n","mc",bm.bookmark_clean) -- clean all marks in local buffer
    map("n","mn",bm.bookmark_next) -- jump to next mark in local buffer
    map("n","mp",bm.bookmark_prev) -- jump to previous mark in local buffer
    map("n","ml",bm.bookmark_list) -- show marked file list in quickfix window
  end
}
```

## Telescope

```lua
require('telescope').load_extension('bookmarks')
```

Then use `:Telescope bookmarks list` or `require('telescope').extensions.bookmarks.list()`

## Credits

- [gitsigns.nvim] most of lua functions come from this plugin
- [vim-bookmarks](https://github.com/MattesGroeger/vim-bookmarks) inspired by this vim plugin
- [possession.nvim](https://github.com/jedrzejboczar/possession.nvim) some util functions

[gitsigns.nvim]: https://github.com/lewis6991/gitsigns.nvim
[packer.nvim]: https://github.com/wbthomason/packer.nvim
