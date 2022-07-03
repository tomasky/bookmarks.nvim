local config = require("bookmarks.config").config
local uv = vim.loop
local signs = require "bookmarks.signs"
local utils = require "bookmarks.util"
local api = vim.api
local current_buf = api.nvim_get_current_buf
local M = {}

local function updateBookmarks(bufnr, line, mark, ann)
   local filepath = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   local marks = config.cache[filepath]
   local isIns = false
   if line == -1 then
      marks = nil
      -- check buffer auto_save to file
      return
   end
   for i = 1, #marks do
      if marks[i].l == line and mark == "" then
         table.remove(marks, i)
      elseif marks[i].l == line then
         isIns = true
      end
   end
   if isIns == false then
      table.insert(marks, ann and { l = line, m = mark, a = ann } or { l = line, m = mark })
      -- check buffer auto_save to file
      -- M.saveBookmarks()
   end
end

M.toggle_signs = function(value)
   if value ~= nil then
      config.signcolumn = value
   else
      config.signcolumn = not config.signcolumn
   end
   M.refresh()
   return config.signcolumn
end

M.bookmark_add = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "add",
      lnum = lnum,
   } }
   signs:add(bufnr, signlines)
   updateBookmarks(bufnr, lnum, "line ")
end

M.bookmark_rm = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   signs:remove(bufnr, lnum)
   updateBookmarks(bufnr, lnum, "")
end

M.bookmark_clean = function()
   local bufnr = current_buf()
   updateBookmarks(bufnr, -1, "")
end

M.bookmark_ann = function(old_annotation)
   local new_annotation = ""
   local input_msg = old_annotation ~= "" and "Edit" or "Enter"
   vim.ui.input(input_msg, old_annotation, function(answer)
      new_annotation = answer
   end)
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "ann",
      lnum = lnum,
   } }
   signs:add(bufnr, signlines)
   updateBookmarks(bufnr, lnum, "line ", new_annotation)
end

M.bookmark_prev = function() end
M.bookmark_next = function() end
M.bookmark_showall = function() end

M.refresh = function()
   local cache = config.cache
   local bufnr = current_buf()
   local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   local marks = cache.data[file]
   local signlines = {}
   if marks then
      for mark in marks do
         local ma = {
            type = mark.a and "ann" or "add",
            lnum = mark.l,
         }
         signs:remove(bufnr, ma.lnum)
         table.insert(signlines, ma)
      end
      signs:add(bufnr, signlines)
   end
end

function M.loadBookmarks()
   utils.read_file(config.save_file, function(data)
      local contents = vim.json.decode(data)
      config.cache = contents
   end)
end

function M.saveBookmarks()
   local data = vim.json.encode(config.cache)
   utils.write_file(config.save_file, data)
end

return M
