local M = {}
local has_snacks, snacks = pcall(require, "snacks")

if not has_snacks then error("This feature requires folke/snacks.nvim") end

local config = require("bookmarks.config").config
local actions = require("bookmarks.actions")

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Inline text to show next to a bookmarked line, or nil when there is nothing worth showing. A
-- keyword annotation renders as its icon followed by the annotation without the "@x" prefix.
-- Anything else is shown as typed, because its first character is already the icon.
local function get_text(ann)
  if not ann or ann == "" then return nil end
  if ann:sub(1, 1) == "@" and config.keywords[ann:sub(1, 2)] then
    local icon = trim(config.keywords[ann:sub(1, 2)])
    local body = trim(ann:sub(3))
    return body == "" and icon or icon .. " " .. body
  end
  local body = trim(ann)
  return body == "" and nil or body
end

local function get_list()
  -- Bookmark line numbers are kept in sync lazily, so fold in pending edits before listing them.
  actions.sync_all()
  local marklist = {}
  for file, marks in pairs(config.cache.data) do
    for lnum, v in pairs(marks) do
      table.insert(marklist, {
        filename = file,
        lnum = tonumber(lnum),
        text = v.m,
        annotation = v.a and get_text(v.a),
      })
    end
  end
  return marklist
end

local format = function(item, picker)
  local file_path = snacks.picker.util.path(item.file) or item.file
  local line_info = string.format("%-5s", tostring(item.pos[1] or ""))

  -- Truncate path exactly like snacks natively handles it
  -- Default truncation length is usually 40 (or dynamically based on window width)
  local smart_path =
    string.format("%30s", Snacks.picker.util.truncpath(file_path, 30, { cwd = picker:cwd() }))

  local annotation = item.value.annotation or ""
  local text = item.text or ""
  text = trim(text)
  if annotation ~= "" then text = annotation .. " | " .. text end
  if #text > 50 then
    text = text:sub(1, 47) .. "..."
  else
    text = string.format("%-50s", text)
  end

  return {
    { smart_path, "SnacksPickerPath" },
    { ":" },
    { line_info, "Comment" },
    { " | ", "SnacksPickerDelim" },
    { text, "SnacksPickerLabel" },
  }
end

function M.BookmarksPicker()
  snacks.picker.pick({
    title = "Bookmarks",
    finder = function()
      local items = {}
      for _, entry in ipairs(get_list()) do
        table.insert(items, {
          text = entry.text,
          file = entry.filename,
          pos = { entry.lnum, 1 },

          -- Retaining the underlying object if needed elsewhere
          value = entry,
        })
      end
      return items
    end,
    actions = {
      delete_mark = function(picker, item)
        if not item then return end
        actions.bookmark_del(item.value.filename, item.value.lnum)
        picker:find()
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "delete_mark", mode = { "n", "i" }, desc = "delete bookmark" },
        },
      },
    },
    format = format,
    layout = {
      layout = {
        backdrop = {
          blend = 40,
        },
        width = 0.8,
        min_width = 80,
        height = 0.6,
        min_height = 10,
        box = "vertical",
        border = "rounded",
        title = " Bookmarks ",
        title_pos = "center",
        { win = "preview", height = 0.5, border = "none" },
        { win = "input", height = 1, border = "top" },
        { win = "list", border = "top" },
      },
    },
  })
end

return M
