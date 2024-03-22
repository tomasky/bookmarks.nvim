local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
  error("This plugins requires nvim-telescope/telescope.nvim")
end
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local entry_display = require("telescope.pickers.entry_display")
local conf = require("telescope.config").values
local config = require("bookmarks.config").config
local utils = require("telescope.utils")

local action_state = require("telescope.actions.state")

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

  local function bookmarks_finder()
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
    return finders.new_table({
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
    })
  end

  local function find_buffer_by_filepath(filepath)
    -- Normalize the filepath to an absolute path
    local abs_filepath = vim.fn.fnamemodify(filepath, ":p")

    -- Iterate through each tab page
    for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
      -- Iterate through each window in the current tab page
      for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
        local bufnr = vim.api.nvim_win_get_buf(win_id)
        local buf_path = vim.api.nvim_buf_get_name(bufnr)
        if vim.fn.fnamemodify(buf_path, ":p") == abs_filepath then
          return bufnr
        end
      end
    end
    -- Return nil if no matching buffer is found
    return nil
  end

  local function delete_bookmark(prompt_bufnr)
    local selection = action_state.get_selected_entry()
    if selection == nil then
      print("Nothing selected")
      return
    end

    local data = config.cache["data"]

    local filepath = selection.filename
    local lnum = tostring(selection.lnum)

    if data[filepath] and data[filepath][lnum] then
      data[filepath][lnum] = nil
      if next(data[filepath]) == nil then
        data[filepath] = nil
      end

      local current_picker = action_state.get_current_picker(prompt_bufnr)
      current_picker:refresh(bookmarks_finder(), { reset_prompt = true })

      local bufnr = find_buffer_by_filepath(filepath)

      if bufnr then
        local start_lnum = tonumber(lnum)
        vim.api.nvim_buf_clear_namespace(bufnr, -1, start_lnum - 1, start_lnum)
      end
    else
      print("Bookmark not found:", filepath, lnum)
    end
  end

  pickers
    .new(opts, {
      prompt_title = "Bookmarks",
      results_title = "Bookmarks List",
      finder = bookmarks_finder(),
      sorter = conf.generic_sorter(opts),
      previewer = conf.qflist_previewer(opts),

      attach_mappings = function(_, map)
        map("i", "<C-x>", delete_bookmark)
        map("n", "x", delete_bookmark)
        return true
      end,
    })
    :find()
end

return telescope.register_extension({ exports = { list = bookmark } })
