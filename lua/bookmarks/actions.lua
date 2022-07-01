local config = require("bookmarks.config").config
local void = require("bookmarks.async").void
local signs = require "bookmarks.signs"
local utils = require "bookmarks.util"
local api = vim.api
local current_buf = api.nvim_get_current_buf
local M = {}

M.toggle_signs = function(value)
   if value ~= nil then
      config.signcolumn = value
   else
      config.signcolumn = not config.signcolumn
   end
   M.refresh()
   return config.signcolumn
end

M.bookmark_add = function(lnum)
   local signlines = {}
   local bufnr = current_buf()
   signlines[0] = {
      type = "add",
      count = 1,
      lnum = lnum,
   }
   signs:add(bufnr, signlines)
end

M.bookmark_rm = function() end
M.bookmark_clean = function() end
M.bookmark_ann = function() end
M.bookmark_prev = function() end
M.bookmark_next = function() end
M.refresh = function() end

local function saveBookmarks(filepath)
   local content = {
      index = 1,
      data = {
         [filepath] = {
            {
               i = 1, -- index
               l = 1, -- line num
               c = "", -- mark  content
               a = "", -- mark annotation
            },
         },
      },
   }
   local data = vim.json.encode(content)
   utils.write_file(config.save_file, data)
end

local function loadBookmarks()
   utils.read_file(config.save_file, function(data)
      local marks = vim.json.decode(data)
   end)
end
