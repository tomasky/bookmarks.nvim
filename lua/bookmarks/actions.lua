local config = require("bookmarks.config").config
local schema = require("bookmarks.config").schema
local uv = vim.loop
local Signs = require("bookmarks.signs")
local utils = require("bookmarks.util")
local api = vim.api
local current_buf = api.nvim_get_current_buf
local M = {}
local signs

-- Per-session state. None of this is persisted.
local next_id = 0
local path_cache = {} -- [bufnr] = realpath | false (known to have none)
local synced_tick = {} -- [bufnr] = changedtick at the last resync
local tracked = {} -- [bufnr] = true, buffers whose signs we manage

local function alloc_id()
  next_id = next_id + 1
  return next_id
end

--- Realpath of a buffer's file, memoized per buffer. Replaces a synchronous
--- fs_realpath syscall on every operation. Invalidated by invalidate_path().
local function file_of(bufnr)
  local cached = path_cache[bufnr]
  if cached ~= nil then
    return cached or nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  local path = name ~= "" and uv.fs_realpath(name) or nil
  path_cache[bufnr] = path or false
  return path
end

function M.invalidate_path(bufnr)
  path_cache[bufnr] = nil
end

--- Icon to show for an annotation. An annotation starting with "@" uses the
--- configured keyword table ("@t" -> checkbox, ...); anything else gives up
--- its first character, so plain letters and emoji both work as icons.
--- Returns nil to mean "use the default sign text".
local function ann_icon(ann)
  if not ann or ann == "" then
    return nil
  end
  if ann:sub(1, 1) == "@" then
    return config.keywords[ann:sub(1, 2)]
  end
  local first = vim.fn.strcharpart(ann, 0, 1)
  if first == "" or first == " " then
    return nil
  end
  return first
end

M.ann_icon = ann_icon

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Inline text to show next to a bookmarked line, or nil when there is
--- nothing worth showing. A keyword annotation renders as its icon followed
--- by the annotation without the "@x" prefix ("@t buy milk" -> "☑️ buy
--- milk"). Anything else is shown as typed, because its first character is
--- already the icon, so repeating it would just duplicate a letter.
local function ann_text(ann)
  if not ann or ann == "" then
    return nil
  end
  if ann:sub(1, 1) == "@" and config.keywords[ann:sub(1, 2)] then
    local icon = trim(config.keywords[ann:sub(1, 2)])
    local body = trim(ann:sub(3))
    return body == "" and icon or icon .. " " .. body
  end
  local body = trim(ann)
  return body == "" and nil or body
end

--- Build the sign descriptor for a mark. The mark's id is stable, so the
--- extmark keeps its identity and Neovim moves it automatically on edits.
local function sign_of(lnum, mark)
  return {
    id = mark.id,
    lnum = lnum,
    type = mark.a and "ann" or "add",
    text = ann_icon(mark.a),
    virt_text = config.virt_text and ann_text(mark.a) or nil,
  }
end

--- Copy the cache without the transient extmark ids, so the on-disk JSON
--- format stays exactly as it was before this refactor.
local function strip_ids(cache)
  local out = { data = {} }
  for file, marks in pairs(cache.data or {}) do
    local copy = {}
    for lnum, v in pairs(marks) do
      copy[lnum] = { m = v.m, a = v.a }
    end
    out.data[file] = copy
  end
  return out
end

local resync
local attach_to_buffer

M.setup = function()
  signs = Signs.new(config.signs)
end

M.detach = function(bufnr, keep_signs)
  if not keep_signs then
    signs:remove(bufnr)
  end
end

local function set_mark(bufnr, lnum, mark, ann)
  local file = file_of(bufnr)
  if not file then
    return
  end
  local data = config.cache.data
  local marks = data[file]
  if not marks then
    marks = {}
    data[file] = marks
  end
  local key = tostring(lnum)
  local m = marks[key]
  if m then
    m.m = mark
    m.a = ann
    if m.id == nil then
      m.id = alloc_id()
    end
  else
    m = { m = mark, a = ann, id = alloc_id() }
    marks[key] = m
  end
  signs:add(bufnr, { sign_of(lnum, m) })
end

local function del_mark(bufnr, lnum)
  local file = file_of(bufnr)
  if not file then
    return
  end
  local marks = config.cache.data[file]
  if not marks then
    return
  end
  local key = tostring(lnum)
  local m = marks[key]
  if not m then
    return
  end
  marks[key] = nil
  if m.id then
    signs:del(bufnr, m.id)
  end
  if next(marks) == nil then
    config.cache.data[file] = nil
  end
end

--- Delete a bookmark given a file path and line number, for callers that are
--- not sitting in the bookmark's buffer (e.g. the telescope picker). Also
--- drops the sign from any loaded buffer showing that file.
function M.bookmark_del(filename, lnum)
  local marks = config.cache.data[filename]
  if not marks then
    return
  end
  local key = tostring(lnum)
  local m = marks[key]
  if not m then
    return
  end
  marks[key] = nil
  if next(marks) == nil then
    config.cache.data[filename] = nil
  end
  if m.id then
    for bufnr in pairs(tracked) do
      if file_of(bufnr) == filename then
        signs:del(bufnr, m.id)
      end
    end
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

--- Show or hide bookmark annotations as inline virtual text. With no argument,
--- flips the current setting. Repaints every tracked buffer so the change
--- applies to all open windows at once.
M.toggle_virt_text = function(value)
  if value ~= nil then
    config.virt_text = value
  else
    config.virt_text = not config.virt_text
  end
  for bufnr in pairs(tracked) do
    M.refresh(bufnr)
  end
  return config.virt_text
end

M.bookmark_toggle = function()
  local bufnr = current_buf()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local file = file_of(bufnr)
  if not file then
    return
  end
  local marks = config.cache.data[file]
  if marks and marks[tostring(lnum)] then
    del_mark(bufnr, lnum)
  else
    local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    set_mark(bufnr, lnum, line, nil)
  end
end

M.bookmark_clean = function()
  local bufnr = current_buf()
  local file = file_of(bufnr)
  if file then
    config.cache.data[file] = nil
  end
  signs:remove(bufnr)
  synced_tick[bufnr] = api.nvim_buf_get_changedtick(bufnr)
end

M.bookmark_line = function(lnum, bufnr)
  bufnr = bufnr or current_buf()
  resync(bufnr)
  local file = file_of(bufnr)
  local marks = file and config.cache.data[file] or nil
  marks = marks or {}
  return lnum and marks[tostring(lnum)] or marks
end

M.bookmark_ann = function()
  local bufnr = current_buf()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local mark = M.bookmark_line(lnum, bufnr)
  vim.ui.input({ prompt = "Edit:", default = mark.a }, function(answer)
    if answer == nil then
      return
    end
    local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    set_mark(bufnr, lnum, line, answer)
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
  M.sync_all()
  -- prune_dead is async, so build the list only once the dead entries are
  -- actually gone.
  M.prune_dead(function()
    local marklist = {}
    for file, marks in pairs(config.cache.data) do
      for lnum, v in pairs(marks) do
        table.insert(marklist, { filename = file, lnum = lnum, text = v.m .. "|" .. (v.a or "") })
      end
    end
    utils.setqflist(marklist, { close_on_select = config.auto_close_list })
  end)
end

attach_to_buffer = function(bufnr)
  if tracked[bufnr] then
    return
  end
  tracked[bufnr] = true
  api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      tracked[bufnr] = nil
      synced_tick[bufnr] = nil
      path_cache[bufnr] = nil
    end,
  })
end

--- Read the extmarks back and rewrite `config.cache.data` line numbers from
--- them. Extmarks already moved themselves during the edit, so one
--- nvim_buf_get_extmarks call tells us where every bookmark ended up.
--- @return boolean true if the positions were read back successfully, false
--- if the signs are missing/out of sync and the caller must rebuild.
local function try_resync(bufnr)
  local tick = api.nvim_buf_get_changedtick(bufnr)
  local file = file_of(bufnr)
  local marks = file and config.cache.data[file] or nil
  if not marks then
    synced_tick[bufnr] = tick
    return true
  end

  local count = 0
  for _ in pairs(marks) do
    count = count + 1
  end

  local positions = signs:positions(bufnr)
  local new_marks = {}
  local matched = 0
  local duplicates = nil
  for _, m in pairs(marks) do
    local row = m.id and positions[m.id]
    if row then
      matched = matched + 1
      local key = tostring(row + 1)
      if new_marks[key] then
        -- Two bookmarks collapsed onto one line (e.g. a line join). Keep the
        -- first and drop the redundant extmark so signs match the data.
        duplicates = duplicates or {}
        duplicates[#duplicates + 1] = m.id
      else
        new_marks[key] = m
      end
    end
  end

  if matched ~= count then
    return false
  end

  if duplicates then
    for _, id in ipairs(duplicates) do
      signs:del(bufnr, id)
    end
  end

  config.cache.data[file] = new_marks
  synced_tick[bufnr] = tick
  return true
end

--- Bring `config.cache.data` line numbers back in sync with the buffer.
--- Guarded by changedtick, so repeated calls with no edits are free.
resync = function(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if synced_tick[bufnr] == api.nvim_buf_get_changedtick(bufnr) then
    return
  end
  if not try_resync(bufnr) then
    -- try_resync just established the signs are gone, so tell refresh to skip
    -- its own read-back and rebuild straight from the cached positions.
    M.refresh(bufnr, true)
  end
end

--- Render the cached marks for `file` into `bufnr` as signs. Assumes the
--- cache is already current, so it does not read the extmarks back first.
local function paint(bufnr, file)
  local marks = config.cache.data[file]
  signs:remove(bufnr)
  if marks then
    local signlines = {}
    for k, v in pairs(marks) do
      if v.id == nil then
        v.id = alloc_id()
      end
      signlines[#signlines + 1] = sign_of(tonumber(k), v)
    end
    signs:add(bufnr, signlines)
  end
  attach_to_buffer(bufnr)
  synced_tick[bufnr] = api.nvim_buf_get_changedtick(bufnr)
end

M.refresh = function(bufnr, skip_resync)
  bufnr = bufnr or current_buf()
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local file = file_of(bufnr)
  if not file then
    return
  end
  -- Fold in any edits the extmarks already absorbed before rebuilding, so we
  -- never redraw signs at stale line numbers. If the signs are gone (buffer
  -- was reloaded) this fails and we rebuild from the cached positions.
  -- skip_resync is set by resync, which has already made that attempt.
  if not skip_resync and synced_tick[bufnr] ~= api.nvim_buf_get_changedtick(bufnr) then
    try_resync(bufnr)
  end
  paint(bufnr, file)
end

--- How long prune_dead waits for its async existence checks before giving up.
--- A stat that never returns (a hung network mount) must not block the caller
--- forever. Paths we could not check are kept: we only ever delete what is
--- positively confirmed gone.
local PRUNE_TIMEOUT_MS = 500

--- Drop bookmarks whose file is gone from disk and clear their signs from any
--- buffer still showing them. A renamed or moved directory therefore loses its
--- bookmarks silently -- there is no path remapping.
---
--- The existence checks run on the libuv thread pool, so a slow mount cannot
--- freeze the caller, and a timeout bounds the wait so an unreachable mount
--- cannot stall it either. `cb(removed)` fires once every path has been
--- checked or the timeout expires, with the cache already cleaned.
function M.prune_dead(cb)
  local files = {}
  for file in pairs(config.cache.data) do
    files[#files + 1] = file
  end
  if #files == 0 then
    if cb then
      cb(false)
    end
    return
  end

  local pending = #files
  local dead = nil
  local finished = false
  local timer = uv.new_timer()

  local function finish()
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    -- The stats land inside libuv callbacks, where the buffer API is off
    -- limits (E5560). Hop back to the main loop before touching signs.
    vim.schedule(function()
      local data = config.cache.data
      local removed = false
      if dead then
        for file in pairs(dead) do
          if data[file] ~= nil then
            data[file] = nil
            removed = true
          end
        end
        for bufnr in pairs(tracked) do
          local file = file_of(bufnr)
          if file and dead[file] then
            signs:remove(bufnr)
          end
        end
      end
      if cb then
        cb(removed)
      end
    end)
  end

  if timer then
    timer:start(PRUNE_TIMEOUT_MS, 0, finish)
  end

  for _, file in ipairs(files) do
    utils.path_missing_async(file, function(missing)
      if missing then
        dead = dead or {}
        dead[file] = true
      end
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end)
  end
end

--- Resync every tracked buffer. Call this before reading the cache from
--- outside the edit path (list, telescope, save) so the line numbers are
--- current rather than whatever they were at the last edit.
function M.sync_all()
  for bufnr in pairs(tracked) do
    resync(bufnr)
  end
end

--- Read the bookmarks file and repaint every loaded buffer.
--- @param opts table|nil `prune_and_save` additionally drops entries whose
---   file is gone and writes the cleaned cache back. Only bookmark_reload
---   sets it: doing that at startup would read an unmounted drive as a mass
---   deletion.
function M.loadBookmarks(opts)
  local prune_and_save = opts and opts.prune_and_save
  if not utils.path_exists(config.save_file) then
    return
  end
  utils.read_file(config.save_file, function(data)
    config.cache = vim.json.decode(data)
    config.marks = data
    -- The cache was replaced wholesale, so drop every cached tick: the
    -- positions on screen no longer correspond to what is in memory.
    synced_tick = {}
    -- The read is async, so any buffer that was opened before it finished
    -- (the file nvim started with, or anything read during startup) is still
    -- blank. Paint them all now that the cache is actually populated.
    -- paint() rather than refresh(): the cache was just replaced wholesale,
    -- so there is nothing meaningful to read back from the old extmarks.
    -- Deferred via vim.schedule: this callback runs inside a libuv callback,
    -- which is not a safe place to call the buffer API.
    vim.schedule(function()
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) then
          local file = file_of(bufnr)
          if file then
            paint(bufnr, file)
          end
        end
      end
      if prune_and_save then
        -- The prune lives on this path only (bookmark_reload), never on the
        -- exit path. Its sign cleanup also removes the signs just painted for
        -- the dead files.
        M.saveBookmarks({ prune = true })
      end
    end)
  end)
end

--- Re-read the bookmarks file, drop entries whose file is gone, repaint the
--- loaded buffers and write the cleaned cache back. Picks up changes made
--- outside this nvim instance (another instance, a manual edit, a git
--- checkout) and cleans up after a renamed or moved directory. Does nothing
--- if the save file is missing.
function M.bookmark_reload()
  M.loadBookmarks({ prune_and_save = true })
end

--- Write the cache out, skipping the write when nothing changed.
local function flush()
  local data = vim.json.encode(strip_ids(config.cache))
  if config.marks ~= data then
    utils.write_file(config.save_file, data)
    config.marks = data
  end
end

--- Persist the cache. `opts.prune` additionally drops entries whose file is
--- gone and rewrites the cache if that removed anything. The first write is
--- deliberately not gated on the prune: the prune is a best-effort cleanup
--- that can be cut short, and a stat that never returns must never cost us the
--- save. Only bookmark_reload asks for pruning -- on the exit path it would
--- read an unmounted drive as a mass deletion.
function M.saveBookmarks(opts)
  M.sync_all()
  flush()
  if opts and opts.prune then
    M.prune_dead(function(removed)
      if removed then
        flush()
      end
    end)
  end
end

function M.bookmark_clear_all()
  config.cache = vim.deepcopy(schema.cache.default)
  synced_tick = {}
  for bufnr in pairs(tracked) do
    signs:remove(bufnr)
  end
  M.saveBookmarks()
end

return M
