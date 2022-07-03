local void = require("bookmarks.async").void
local scheduler = require("bookmarks.async").scheduler
local api = vim.api
local uv = vim.loop
local current_buf = api.nvim_get_current_buf
local config = require "bookmarks.config"
local signs = require "bookmarks.signs"
local nvim = require "bookmarks.nvim"
local hl = require "bookmarks.highlight"
local actions = require "bookmarks.actions"

local M = {}

local function wrap_func(fn, ...)
   local args = { ... }
   local nargs = select("#", ...)
   return function()
      fn(unpack(args, 1, nargs))
   end
end
local function autocmd(event, opts)
   local opts0 = {}
   if type(opts) == "function" then
      opts0.callback = wrap_func(opts)
   else
      opts0 = opts
   end
   opts0.group = "bookmarks"
   nvim.autocmd(event, opts0)
end

M.attach = void(function(bufnr, aucmd)
   scheduler()
   actions.loadBookmarks()
   if config.on_attach then
      config.on_attach(bufnr)
   end
end)

M.detach_all = void(function(bufnr)
   scheduler()
   signs.detach(bufnr)
   actions.saveBookmarks()
end)

M.setup = void(function(cfg)
   config.build(cfg)
   signs.setup()
   nvim.augroup "bookmarks"
   autocmd("VimLeavePre", M.detach_all)
   autocmd("ColorScheme", hl.setup_highlights)
   autocmd("BufRead", wrap_func(M.attach, nil, "BufRead"))
end)

return setmetatable(M, {
   __index = function(_, f)
      return actions[f]
   end,
})
