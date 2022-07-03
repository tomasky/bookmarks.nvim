local config = require("bookmarks.config").config
local uv = vim.loop
local Signs = require "bookmarks.signs"
local utils = require "bookmarks.util"
local api = vim.api
local current_buf = api.nvim_get_current_buf
local M = {}
local signs
M.setup = function()
   signs = Signs.new(config.signs)
end

M.detach = function(bufnr, keep_signs)
   if not keep_signs then
      signs:remove(bufnr)
   end
end

local function updateBookmarks(bufnr, lnum, mark, ann)
   local filepath = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   if filepath == nil then
      return
   end
   local data = config.cache["data"]
   local marks = data[filepath]
   local isIns = false
   if lnum == -1 then
      marks = nil
      isIns = true
      -- check buffer auto_save to file
   end
   for k, _ in pairs(marks or {}) do
      if k == tostring(lnum) then
         isIns = true
         if mark == "" then
            marks[k] = nil
         end
         break
      end
   end
   if isIns == false then
      marks = marks or {}
      marks[tostring(lnum)] = ann and { m = mark, a = ann } or { m = mark }
      -- check buffer auto_save to file
      -- M.saveBookmarks()
   end
   data[filepath] = marks
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

M.bookmark_toggle = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "add",
      lnum = lnum,
   } }
   local isExt = signs:add(bufnr, signlines)
   if isExt then
      signs:remove(bufnr, lnum)
      updateBookmarks(bufnr, lnum, "")
   else
      local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1]
      updateBookmarks(bufnr, lnum, line)
   end
end

M.bookmark_clean = function()
   local bufnr = current_buf()
   signs:remove(bufnr)
   updateBookmarks(bufnr, -1, "")
end

M.bookmark_line = function(lnum, bufnr)
   bufnr = bufnr or current_buf()
   local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   local marks = config.cache["data"][file]
   return marks[lnum]
end

M.bookmark_ann = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "ann",
      lnum = lnum,
   } }
   local isExt = signs:add(bufnr, signlines)
   local input_msg = isExt and "Edit:" or "Enter:"
   local mark = M.bookmark_line(lnum, bufnr)
   vim.ui.input({ prompt = input_msg, default = mark.a }, function(answer)
      local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1]
      updateBookmarks(bufnr, lnum, line, answer)
   end)
end

M.bookmark_prev = function()
   local mark = M.bookmark_line(lnum)
end

M.bookmark_next = function()
   local mark = M.bookmark_line(lnum)
end

M.bookmark_showall = function() end

M.refresh = function(bufnr)
   bufnr = bufnr or current_buf()
   local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   if file == nil then
      return
   end
   local marks = config.cache.data[file]
   local signlines = {}
   if marks then
      for k, v in pairs(marks) do
         local ma = {
            type = v.a and "ann" or "add",
            lnum = tonumber(k),
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
