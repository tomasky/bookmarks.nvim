local config = require("bookmarks.config").config
local schema = require("bookmarks.config").schema
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
   local line_count = api.nvim_buf_line_count(bufnr)
   for k, _ in pairs(marks or {}) do
      if k == tostring(lnum) then
         isIns = true
         if mark == "" then
            marks[k] = nil
         end
         break
      elseif tonumber(k) > line_count then
         marks[k] = nil
      end
   end
   if isIns == false or ann then
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
      local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
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
   local marks = config.cache["data"][file] or {}
   return lnum and marks[tostring(lnum)] or marks
end

M.bookmark_ann = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "ann",
      lnum = lnum,
   } }
   local mark = M.bookmark_line(lnum, bufnr)
   vim.ui.input({ prompt = "Edit:", default = mark.a }, function(answer)
      if answer == nil then return end
      local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
      signs:remove(bufnr, lnum)
      local text = config.keywords[string.sub(answer or "", 1, 2)]
      if text then
         signlines[1]["text"] = text
      end
      signs:add(bufnr, signlines)
      updateBookmarks(bufnr, lnum, line, answer)
   end)
end

local jump_line = function(prev)
   local lnum = api.nvim_win_get_cursor(0)[1]
   local marks = M.bookmark_line()
   local small, big = {}, {}
   for k, _ in pairs(marks) do
      k = tonumber(k)
      if k < lnum then
         table.insert(small, k)
      elseif k > lnum then
         table.insert(big, k)
      end
   end
   if prev then
      local tmp = #small > 0 and small or big
      table.sort(tmp, function(a, b)
         return a > b
      end)
      lnum = tmp[1]
   else
      local tmp = #big > 0 and big or small
      table.sort(tmp)
      lnum = tmp[1]
   end
   if lnum then
      api.nvim_win_set_cursor(0, { lnum, 0 })
      local mark = marks[tostring(lnum)]
      if mark.a then
         api.nvim_echo({ { "ann: " .. mark.a, "WarningMsg" } }, false, {})
      else
      end
   end
end

M.bookmark_prev = function()
   jump_line(true)
end

M.bookmark_next = function()
   jump_line(false)
end

M.bookmark_list = function()
   local allmarks = config.cache.data
   local marklist = {}
   for k, ma in pairs(allmarks) do
      if utils.path_exists(k) == false then
         allmarks[k] = nil
      end
      for l, v in pairs(ma) do
         table.insert(marklist, { filename = k, lnum = l, text = v.m .. "|" .. (v.a or "") })
      end
   end
   utils.setqflist(marklist)
end

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
         local pref = string.sub(v.a or "", 1, 2)
         local text = config.keywords[pref]
         if text then
            ma["text"] = text
         end
         signs:remove(bufnr, ma.lnum)
         table.insert(signlines, ma)
      end
      signs:add(bufnr, signlines)
   end
end

function M.loadBookmarks()
   if utils.path_exists(config.save_file) then
      utils.read_file(config.save_file, function(data)
         config.cache = vim.json.decode(data)
         config.marks = data
      end)
   end
end

function M.saveBookmarks()
   local data = vim.json.encode(config.cache)
   if config.marks ~= data then
      utils.write_file(config.save_file, data)
   end
end

function M.bookmark_clear_all()
    config.cache = schema.cache.default
    M.saveBookmarks()
end

return M
