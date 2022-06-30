local api = vim.api
local nvim = require "bookmarks.nvim"

local M = {}

local hls = {
   { BookMarksAdd = { "MarkAdd" } },
}

local function is_hl_set(hl_name)
   local exists, hl = pcall(api.nvim_get_hl_by_name, hl_name, true)
   local color = hl.foreground or hl.background or hl.reverse
   return exists and color ~= nil
end

M.setup_highlights = function()
   for _, hlg in ipairs(hls) do
      for hl, candidates in pairs(hlg) do
         if is_hl_set(hl) then
         else
            for _, d in ipairs(candidates) do
               if is_hl_set(d) then
                  nvim.highlight(hl, { default = true, link = d })
                  break
               end
            end
         end
      end
   end
end

return M
