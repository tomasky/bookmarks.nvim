local config = require("bookmarks.config").config
local schema = require("bookmarks.config").schema
local codec = require("bookmarks.codec")
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
local scope_cache = {} -- [dir] = scope root | false (known to have none)
local scope_of = {} -- [file] = scope root | false
local loaded = {} -- [root] = true, its scope file is in the cache
local reading = {} -- [root] = true, a read of its scope file is in flight
local dirty = false -- true when config.cache.data holds changes not yet written
local digests = {} -- [path] = hash of the text last written there

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

--- Copy a file's marks without the transient extmark ids, so the on-disk JSON
--- format stays exactly as it was before the extmark refactor.
local function strip_marks(marks)
  local copy = {}
  for lnum, v in pairs(marks) do
    copy[lnum] = { m = v.m, a = v.a }
  end
  return copy
end

--- Directory of the scope a file belongs to, or nil when it is in none. Walks
--- up from the file's directory looking for a scope file and stops at the
--- first hit -- nearest wins, with no special cases.
---
--- Both levels are memoized, so the cost is one stat for a directory never
--- seen before and one table lookup after that:
---   scope_cache[dir] answers "nearest scope at or above dir", including
---   `false` for "none", which stops unscoped files from re-walking to the
---   filesystem root on every call. scope_of[file] then skips even the
---   dirname() string work that flush() and bookmark_list() would otherwise
---   repeat for every file on every call.
local function scope_root(file)
  local hit = scope_of[file]
  if hit ~= nil then
    return hit or nil
  end

  local visited = {}
  local result = false
  local path = utils.dirname(file)
  while path do
    local cached = scope_cache[path]
    if cached ~= nil then
      result = cached
      break
    end
    if utils.path_exists(path .. "/" .. config.scope_file) then
      result = path
      break
    end
    visited[#visited + 1] = path
    path = utils.dirname(path)
  end

  for _, p in ipairs(visited) do
    scope_cache[p] = result
  end
  scope_of[file] = result
  return result or nil
end

--- Forget everything memoized about scopes. Needed whenever scope files appear
--- or disappear, and before re-reading the global file: a cached "no scope
--- here" would stick forever, and a scope still marked loaded after the cache
--- was replaced wholesale would be written back as empty.
local function clear_scope_cache()
  scope_cache = {}
  scope_of = {}
  loaded = {}
  reading = {}
end

local resync
local attach_to_buffer
local ensure_scope

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
  dirty = true
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
  dirty = true
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
  dirty = true
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
  if file and config.cache.data[file] then
    config.cache.data[file] = nil
    dirty = true
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
      -- Scope bookmarks belong to the project you are actually in, so they are
      -- listed first. Memoized, so this is a table lookup per file.
      local scoped = scope_root(file) ~= nil
      for lnum, v in pairs(marks) do
        table.insert(marklist, {
          filename = file,
          lnum = tonumber(lnum),
          text = v.m .. "|" .. (v.a or ""),
          scoped = scoped,
        })
      end
    end
    table.sort(marklist, function(a, b)
      if a.scoped ~= b.scoped then
        return a.scoped
      end
      if a.filename ~= b.filename then
        return a.filename < b.filename
      end
      return a.lnum < b.lnum
    end)
    -- scoped was only there to drive the sort; keep the items to the fields
    -- setqflist() actually understands.
    for _, entry in ipairs(marklist) do
      entry.scoped = nil
    end
    utils.setqflist(marklist, {
      close_on_select = config.auto_close_list,
      position = config.qf_position,
    })
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

--- Read the extmarks back and rewrite `config.cache.data` line numbers and line
--- text from them. Extmarks already moved themselves during the edit, so one
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
  local changed = false
  for lnum, m in pairs(marks) do
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
        -- `m` is the line's text, kept so the list and the picker can show
        -- something. The line may have been rewritten since it was bookmarked,
        -- so re-read it: a bookmark follows its line, text included.
        local text = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        if key ~= lnum or text ~= m.m then
          changed = true
        end
        m.m = text
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
  if changed then
    dirty = true
  end
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
  -- First time we see a file inside a scope, pull that scope's bookmarks in.
  -- Memoized, so this is a table lookup once the directory is known.
  local root = scope_root(file)
  if root and not loaded[root] then
    ensure_scope(root)
  end
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
        if removed then
          dirty = true
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

--- Paint every loaded buffer, pull in the scopes that were read before the
--- global file, then run the prune/save pass when asked. Deferred via
--- vim.schedule because every caller runs inside a libuv callback, where the
--- buffer API is off limits.
--- @param roots string[] scopes that held marks in the cache that was just
---   replaced and therefore have to be read again.
local function after_load(prune_and_save, roots)
  vim.schedule(function()
    -- The read is async, so any buffer opened before it finished (the file
    -- nvim started with, or anything read during startup) is still blank.
    -- paint() rather than refresh(): the cache was replaced wholesale, so
    -- there is nothing meaningful to read back from the old extmarks.
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(bufnr) then
        local file = file_of(bufnr)
        if file then
          paint(bufnr, file)
        end
      end
    end

    -- A scope file is the more specific store, so scopes are read after the
    -- global one and win for any path both mention. The current buffer's scope
    -- goes first so what the user is looking at is complete, then any scope
    -- that was already read once and lost its marks to the global read.
    local order = {}
    local seen = {}
    local file = file_of(current_buf())
    local root = file and scope_root(file)
    if root then
      seen[root] = true
      order[#order + 1] = root
    end
    for _, r in ipairs(roots or {}) do
      if not seen[r] then
        seen[r] = true
        order[#order + 1] = r
      end
    end

    local function finish()
      if prune_and_save then
        -- The prune lives on this path only (bookmark_reload), never on the
        -- exit path. Its sign cleanup also removes the signs just painted for
        -- the dead files.
        M.saveBookmarks({ prune = true })
      end
    end

    local pending = #order
    if pending == 0 then
      finish()
      return
    end
    local function step()
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end
    for _, r in ipairs(order) do
      ensure_scope(r, step)
    end
  end)
end

--- Read the bookmarks file and repaint every loaded buffer.
--- @param opts table|nil `prune_and_save` additionally drops entries whose
---   file is gone and writes the cleaned cache back. Only bookmark_reload
---   sets it: doing that at startup would read an unmounted drive as a mass
---   deletion.
function M.loadBookmarks(opts)
  local prune_and_save = opts and opts.prune_and_save

  local function read_global(data)
    if data then
      config.cache = codec.decode(data) or { data = {} }
      -- What is on disk is what the cache now holds, so the next save must not
      -- rewrite this file just because it was loaded. Seeding the digest means
      -- calling vim.fn, which this libuv callback is not allowed to do, so it
      -- happens on the main loop -- any time before the next save is soon
      -- enough.
      vim.schedule(function()
        digests[config.save_file] = vim.fn.sha256(data)
      end)
      -- The cache was replaced wholesale, so drop every cached tick: the
      -- positions on screen no longer correspond to what is in memory.
      synced_tick = {}
    end
    -- A scope read that landed before this one merged its marks into the cache
    -- that has just been thrown away, while leaving the scope marked as
    -- loaded. Writing it back from here would truncate its file to the handful
    -- of marks left in memory, so forget the scope bookkeeping and read those
    -- scopes again.
    local roots = {}
    for root in pairs(loaded) do
      roots[#roots + 1] = root
    end
    clear_scope_cache()
    after_load(prune_and_save, roots)
  end

  if not utils.path_exists(config.save_file) then
    -- No global file yet, but the project may still carry a scope file: a
    -- fresh clone, or someone who keeps only project-local bookmarks.
    read_global(nil)
    return
  end
  utils.read_file(config.save_file, read_global)
end

--- Re-read the bookmarks file, drop entries whose file is gone, repaint the
--- loaded buffers and write the cleaned cache back. Picks up changes made
--- outside this nvim instance (another instance, a manual edit, a git
--- checkout) and cleans up after a renamed or moved directory. Does nothing
--- if the save file is missing.
function M.bookmark_reload()
  -- Write what this session has first. The read below replaces the cache with
  -- what is on disk, so a bookmark deleted here but not yet saved would simply
  -- come back. With nothing pending this is free, and the reload still picks
  -- up changes made outside nvim.
  M.saveBookmarks()
  -- loadBookmarks replaces the cache wholesale, so it re-reads every scope
  -- that was already loaded and forgets the memoized scope lookups -- which is
  -- also what rediscovers scope files added or removed outside this nvim
  -- instance.
  M.loadBookmarks({ prune_and_save = true })
end

--- Path of the scope file belonging to `root`.
local function scope_path(root)
  return root .. "/" .. config.scope_file
end

--- Read a scope's file into the cache the first time we touch it. The read is
--- async, so `cb` fires once the cache holds it and the loaded buffers have
--- been repainted.
ensure_scope = function(root, cb)
  if loaded[root] or reading[root] then
    if cb then
      cb()
    end
    return
  end
  local path = scope_path(root)
  if not utils.path_exists(path) then
    if cb then
      cb()
    end
    return
  end
  -- Marked as loaded only once the read lands. A scope still being read must
  -- not be treated as loaded by flush(), or quitting mid-read would rewrite
  -- its file as empty and throw its bookmarks away.
  reading[root] = true
  utils.read_file(path, function(data)
    -- Hop back to the main loop before touching the cache or the buffer API.
    -- The scope may also have been switched off while the read was in flight,
    -- in which case reading[root] is gone and the result is dropped.
    vim.schedule(function()
      if not reading[root] then
        if cb then
          cb()
        end
        return
      end
      reading[root] = nil
      -- A scope file created by hand may be empty; treat that as "no
      -- bookmarks" rather than blowing up on a decode error.
      local decoded = codec.decode(data) or { data = {} }
      -- Scope entries win over the global file for the same path: a file
      -- inside a scope keeps all of its bookmarks there.
      for rel, marks in pairs(decoded.data) do
        config.cache.data[root .. "/" .. rel] = marks
      end
      -- Same reason as the global file: these marks came off the disk, so the
      -- next save has nothing to write here unless something changes.
      digests[path] = vim.fn.sha256(data)
      loaded[root] = true
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) then
          local file = file_of(bufnr)
          if file then
            paint(bufnr, file)
          end
        end
      end
      if cb then
        cb()
      end
    end)
  end)
end

--- Write one bookmarks file, unless it already holds this content. The
--- comparison is what keeps a save from touching files it has no business
--- touching: changing one project's bookmarks must not rewrite every other
--- project's scope file.
---
--- A hash stands in for the text itself, so the guard costs a few dozen bytes
--- per file instead of a second copy of everything. `dirty` cannot do this job
--- -- it is one bit for the whole cache, and answers a different question
--- ("is there anything to write at all").
local function write_one(path, data)
  local encoded = codec.encode({ data = data })
  local digest = vim.fn.sha256(encoded)
  if digests[path] ~= digest then
    utils.write_file(path, encoded)
    digests[path] = digest
  end
end

--- Write the cache out, split between the global file and one file per scope.
--- Routing is recomputed on every flush, which is what makes turning a scope
--- on or off move its bookmarks with no migration code.
---
--- Where a bookmark goes is decided by scope_root() alone. Nothing is ever
--- relayed through the global file, so a mark made inside a scope is in that
--- scope's file the next time it is written, whether or not this session had
--- read the scope before.
---
--- A flush with nothing pending returns immediately. `dirty` is cleared at the
--- end of a flush, so it means "config.cache.data holds changes not yet
--- written", and a session that only looked at its bookmarks -- the common one
--- -- never encodes or writes anything at all.
local function flush()
  if not dirty then
    return
  end

  local global = {}
  local scopes = {}
  for file, marks in pairs(config.cache.data) do
    local root = scope_root(file)
    if root then
      local bucket = scopes[root]
      if not bucket then
        bucket = {}
        scopes[root] = bucket
      end
      -- Paths are stored relative to the scope root, so a scope file survives
      -- its project being moved.
      bucket[file:sub(#root + 2)] = strip_marks(marks)
    else
      global[file] = strip_marks(marks)
    end
  end

  write_one(config.save_file, global)

  -- Every loaded scope gets written, not just the ones still holding marks: a
  -- scope whose bookmarks were all deleted has to be blanked rather than left
  -- with stale entries. A scope file deleted outside nvim is dropped instead
  -- of being recreated.
  for root in pairs(loaded) do
    scopes[root] = scopes[root] or {}
  end
  for root, bucket in pairs(scopes) do
    local path = scope_path(root)
    if not utils.path_exists(path) then
      loaded[root] = nil
      digests[path] = nil
    elseif loaded[root] then
      -- Read into this session, so the cache is the whole story for this
      -- scope and the file can be replaced outright -- which is how a deleted
      -- bookmark stays deleted.
      write_one(path, bucket)
    else
      -- Never read into this session, so the cache only knows about the files
      -- this session touched. Everything else has to come from the file:
      -- replacing it would truncate the scope down to whatever happens to be
      -- in memory. Per file, memory wins -- it is what the user has been
      -- looking at -- and the file fills in the files memory has never seen.
      local disk = utils.read_file_sync(path)
      if disk then
        local decoded = codec.decode(disk)
        for rel, marks in pairs(decoded and decoded.data or {}) do
          if bucket[rel] == nil then
            bucket[rel] = marks
          end
        end
        write_one(path, bucket)
      end
    end
  end
  -- Cleared last, so a flush that blows up halfway leaves the changes pending
  -- instead of losing them.
  dirty = false
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
  dirty = true
  for bufnr in pairs(tracked) do
    signs:remove(bufnr)
  end
  M.saveBookmarks()
end

--- Turn a project-local scope on or off for the current buffer's directory.
---
--- On: create the scope file. The next flush routes this directory's bookmarks
--- into it, so bookmarks that were global move across on their own.
--- Off: drop the scope's bookmarks and delete its file.
function M.toggle_scope()
  -- With no file open there is no buffer directory to work from, so fall back
  -- to nvim's working directory: started in a directory that already carries a
  -- scope file, `:BookmarkScope` turns that scope off; anywhere else it creates
  -- one.
  local file = file_of(current_buf())
  local root = file and utils.dirname(file) or uv.cwd()
  if not root then
    utils.warn("bookmarks: cannot scope %s", file or "the current directory")
    return
  end
  local path = scope_path(root)

  if not utils.path_exists(path) then
    -- Create the file for real, and synchronously: scope_root() has to see it
    -- before flush() can route anything into it.
    local empty = codec.encode({ data = {} })
    local ok, err = utils.write_file_sync(path, empty)
    if not ok then
      utils.warn("bookmarks: cannot create %s (%s)", path, err or "unknown error")
      return
    end
    clear_scope_cache()
    loaded[root] = true
    digests[path] = vim.fn.sha256(empty)
    -- Routing changed, so this is a write even though no bookmark did.
    dirty = true
    flush()
    utils.warn("bookmarks: created %s", path)
    return
  end

  -- Collect before clearing the cache: afterwards we can no longer tell which
  -- files belonged to this root.
  local dropped = nil
  for f in pairs(config.cache.data) do
    if scope_root(f) == root then
      dropped = dropped or {}
      dropped[f] = true
    end
  end
  if dropped then
    for f in pairs(dropped) do
      config.cache.data[f] = nil
    end
    for bufnr in pairs(tracked) do
      local buf_file = file_of(bufnr)
      if buf_file and dropped[buf_file] then
        signs:remove(bufnr)
      end
    end
  end

  clear_scope_cache()
  -- Clearing the cache above also cancels any read still in flight, so its
  -- result is dropped instead of resurrecting the bookmarks we just discarded.
  -- A scope is turned off by deleting its file, so its bookmarks go with it.
  utils.remove_file(path)
  digests[path] = nil
  -- The dropped bookmarks are a change like any other, and the routing moved.
  dirty = true
  flush()
  utils.warn("bookmarks: deleted %s", path)
end

return M
