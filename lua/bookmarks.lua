local void = require("bookmarks.async").void
local scheduler = require("bookmarks.async").scheduler
local api = vim.api
local uv = vim.loop
local current_buf = api.nvim_get_current_buf
local config = require "bookmarks.config"
local signs = require "bookmarks.signs"

local M = {}
M.setup = void(function(cfg)
   config.build(cfg)
   signs.setup()
end)

return M
