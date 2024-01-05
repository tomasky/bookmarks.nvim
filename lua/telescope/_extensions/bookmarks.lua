local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
   error "This plugins requires nvim-telescope/telescope.nvim"
end
local finders = require "telescope.finders"
local pickers = require "telescope.pickers"
local entry_display = require "telescope.pickers.entry_display"
local conf = require("telescope.config").values
local config = require("bookmarks.config").config
local utils = require "telescope.utils"

local function get_text(annotation)
   local pref = string.sub(annotation, 1, 2)
   local ret = config.keywords[pref]
   if ret == nil then
      ret = config.signs.ann.text .. " "
   end
   return ret .. annotation
end

local function bookmark(opts)
   opts = opts or {}
   local allmarks = config.cache.data
   local marklist = {}
   for k, ma in pairs(allmarks) do
      for l, v in pairs(ma) do
         table.insert(marklist, {
            filename = k,
            lnum = tonumber(l),
            text = v.a and get_text(v.a) or v.m,
         })
      end
   end
   local display = function(entry)
      local displayer = entry_display.create {
         separator = "▏",
         items = {
            { width = 5 },
            { width = 30 },
            { remaining = true },
         },
      }
      local line_info = { entry.lnum, "TelescopeResultsLineNr" }
      return displayer {
         line_info,
         entry.text:gsub(".* | ", ""),
         utils.path_smart(entry.filename), -- or path_tail
      }
   end
   pickers.new(opts, {
      prompt_title = "bookmarks",
      finder = finders.new_table {
         results = marklist,
         entry_maker = function(entry)
            return {
               valid = true,
               value = entry,
               display = display,
               ordinal = entry.filename .. entry.text,
               filename = entry.filename,
               lnum = entry.lnum,
               col = 1,
               text = entry.text,
            }
         end,
      },
      sorter = conf.generic_sorter(opts),
      previewer = conf.qflist_previewer(opts),
   }):find()
end

return telescope.register_extension { exports = { list = bookmark } }
