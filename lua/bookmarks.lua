local void = require("bookmarks.async").void
local scheduler = require("bookmarks.async").scheduler
local api = vim.api
-- local uv = vim.loop
local current_buf = api.nvim_get_current_buf
local config = require "bookmarks.config"
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

local function on_detach(_, bufnr)
   M.detach(bufnr, true)
end

M.attach = void(function(bufnr)
   bufnr = bufnr or current_buf()
   scheduler()
   actions.loadBookmarks()
   if config.config.on_attach then
      config.config.on_attach(bufnr)
   end
   if not api.nvim_buf_is_loaded(bufnr) then return end
   api.nvim_buf_attach(bufnr, false, {
      on_detach = on_detach,
   })
end)

M.detach_all = void(function(bufnr)
   bufnr = bufnr or current_buf()
   scheduler()
   actions.detach(bufnr)
   actions.saveBookmarks()
end)

local function on_or_after_vimenter(fn)
   if vim.v.vim_did_enter == 1 then
      fn()
   else
      nvim.autocmd("VimEnter", {
         callback = wrap_func(fn),
         once = true,
      })
   end
end

M.setup = void(function(cfg)
   config.build(cfg)
   actions.setup()
   nvim.augroup "bookmarks"
   autocmd("VimLeavePre", M.detach_all)
   autocmd("ColorScheme", hl.setup_highlights)
   on_or_after_vimenter(function()
      hl.setup_highlights()
      M.attach()
      autocmd("BufWinEnter", actions.refresh)
   end)
end)

return setmetatable(M, {
   __index = function(_, f)
      return actions[f]
   end,
})
