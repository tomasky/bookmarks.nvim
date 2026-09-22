local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
  error("This plugins requires nvim-telescope/telescope.nvim")
end
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local entry_display = require("telescope.pickers.entry_display")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local config = require("bookmarks.config").config
local actions = require("bookmarks.actions")
local utils = require("telescope.utils")

local function get_text(annotation)
  local ret = actions.ann_icon(annotation)
  if ret == nil then
    ret = config.signs.ann.text .. " "
  end
  return ret .. annotation
end

local function get_list()
  -- Bookmark line numbers are kept in sync lazily, so fold in any pending
  -- edits before listing them. Dead entries are pruned by bookmark() before
  -- the picker opens, so this stays synchronous.
  actions.sync_all()
  local marklist = {}
  for file, marks in pairs(config.cache.data) do
    for lnum, v in pairs(marks) do
      table.insert(marklist, {
        filename = file,
        lnum = tonumber(lnum),
        text = v.a and get_text(v.a) or v.m,
      })
    end
  end
  return marklist
end

local function display(entry)
  local displayer = entry_display.create({
    separator = "▏",
    items = {
      { width = 5 },
      { width = 30 },
      { remaining = true },
    },
  })
  local line_info = { entry.lnum, "TelescopeResultsLineNr" }
  return displayer({
    line_info,
    entry.text:gsub(".* | ", ""),
    utils.path_smart(entry.filename), -- or path_tail
  })
end

local function make_finder()
  return finders.new_table({
    results = get_list(),
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
  })
end

local function delete_selected(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  if not entry then
    return
  end
  actions.bookmark_del(entry.filename, entry.lnum)
  action_state.get_current_picker(prompt_bufnr):refresh(make_finder())
end

local function bookmark(opts)
  opts = opts or {}
  -- Drop entries whose file is gone before showing them. The checks are async,
  -- so a slow or hung mount cannot stall the picker from opening.
  actions.prune_dead(function()
    pickers
      .new(opts, {
        prompt_title = "bookmarks",
        finder = make_finder(),
        sorter = conf.generic_sorter(opts),
        previewer = conf.qflist_previewer(opts),
        attach_mappings = function(prompt_bufnr, map)
          -- <C-d> rather than <Del> so the prompt keeps its native forward
          -- delete, and so the same key works without leaving insert mode.
          map({ "i", "n" }, "<C-d>", delete_selected)
          return true
        end,
      })
      :find()
  end)
end

return telescope.register_extension({ exports = { list = bookmark } })
