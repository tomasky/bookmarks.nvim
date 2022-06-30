local config = require("bookmarks.config").config
local void = require("gitsigns.async").void
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

M.bookmark_add = function() end
M.bookmark_rm = function() end
M.bookmark_clean = function() end
M.bookmark_ann = function() end
M.refresh = function() end
