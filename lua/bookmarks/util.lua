local uv = vim.loop
local M = {}

function M.path_exists(path)
  return vim.loop.fs_stat(path) and true or false
end

--- Async existence check. Calls cb(true) only when the path is definitely
--- gone (ENOENT). Any other stat failure -- EACCES, ESTALE, an unreachable
--- network mount -- is reported as "still there", so a transient error never
--- erases bookmarks. The stat runs on the libuv thread pool, so a hung mount
--- cannot stall the caller.
function M.path_missing_async(path, cb)
  uv.fs_stat(path, function(err)
    cb(err ~= nil and err:find("ENOENT", 1, true) ~= nil)
  end)
end

local jit_os

if jit then
  jit_os = jit.os:lower()
end

local is_unix = false
if jit_os then
  is_unix = jit_os == "linux" or jit_os == "osx" or jit_os == "bsd"
else
  local binfmt = package.cpath:match("%p[\\|/]?%p(%a+)")
  is_unix = binfmt ~= "dll"
end

--- Precompiled by the assignment below path_sep, so the scope walk's
--- per-directory dirname() does not rebuild the same pattern every time.
local dirname_pat

function M.dirname(file)
  return file:match(dirname_pat)
end

function M.file_lines(file)
  local text = {}
  for line in io.lines(file) do
    text[#text + 1] = line
  end
  return text
end

M.path_sep = package.config:sub(1, 1)
dirname_pat = "^(.+)" .. M.path_sep .. "[^" .. M.path_sep .. "]+"

function M.tmpname()
  if is_unix then
    return os.tmpname()
  end
  return vim.fn.tempname()
end

function M.copy_array(x)
  local r = {}
  for i, e in ipairs(x) do
    r[i] = e
  end
  return r
end

function M.strip_cr(xs0)
  for i = 1, #xs0 do
    if xs0[i]:sub(-1) ~= "\r" then
      return xs0
    end
  end

  local xs = vim.deepcopy(xs0)
  for i = 1, #xs do
    xs[i] = xs[i]:sub(1, -2)
  end
  return xs
end

function M.emptytable()
  return setmetatable({}, {
    __index = function(t, k)
      t[k] = {}
      return t[k]
    end,
  })
end

function M.clear_prompt()
  vim.api.nvim_command("normal! :")
end

function M.prompt_yes_no(prompt, callback, prompt_no_cr)
  prompt = string.format("%s [y/N] ", prompt)
  if prompt_no_cr then -- use getchar so no <cr> is required
    print(prompt)
    local ans = vim.fn.nr2char(vim.fn.getchar())
    local is_confirmed = ans:lower():match("^y")
    M.clear_prompt()
    callback(is_confirmed)
  else -- use vim.ui.input
    vim.ui.input({ prompt = prompt }, function(answer)
      callback(vim.tbl_contains({ "y", "yes" }, answer and answer:lower()))
    end)
  end
end

M.write_file = function(path, content)
  uv.fs_open(path, "w", 438, function(open_err, fd)
    assert(not open_err, open_err)
    uv.fs_write(fd, content, -1, function(write_err)
      assert(not write_err, write_err)
      uv.fs_close(fd, function(close_err)
        assert(not close_err, close_err)
      end)
    end)
  end)
end

--- Delete a file, ignoring "it was not there". Used when a scope is turned off.
--- Synchronous on purpose: the flush that runs immediately afterwards has to
--- see the file gone, or it would treat the scope as still existing and write
--- its bookmarks straight back.
function M.remove_file(path)
  uv.fs_unlink(path)
end

--- Write `content` to `path`, synchronously. Used when a scope is switched on:
--- the routing that runs immediately afterwards has to see the file on disk,
--- and an async write would not have landed yet.
function M.write_file_sync(path, content)
  local fd, err = uv.fs_open(path, "w", 438)
  if not fd then
    return false, err
  end
  uv.fs_write(fd, content, -1)
  uv.fs_close(fd)
  return true
end

--- Read `path`, synchronously. Returns its contents, "" for an empty file, or
--- nil when it could not be read. Used by flush() to pull in a scope file that
--- was never read into this session: the merge has to happen before the write,
--- and there is no async way to guarantee that ordering.
function M.read_file_sync(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local data = ""
  if stat.size > 0 then
    data = uv.fs_read(fd, stat.size, 0)
    if not data then
      uv.fs_close(fd)
      return nil
    end
  end
  uv.fs_close(fd)
  return data
end

M.read_file = function(path, callback)
  uv.fs_open(path, "r", 438, function(err, fd)
    assert(not err, err)
    uv.fs_fstat(fd, function(err, stat)
      assert(not err, err)
      uv.fs_read(fd, stat.size, 0, function(err, data)
        assert(not err, err)
        uv.fs_close(fd, function(err)
          assert(not err, err)
          callback(data)
        end)
      end)
    end)
  end)
end

function M.warn(...)
  vim.notify(string.format(...), vim.log.levels.WARN)
end

function M.error(...)
  vim.notify(string.format(...), vim.log.levels.ERROR)
end

function M.lazy(fn)
  local cached
  return function(...)
    if cached == nil then
      cached = fn(...)
      assert(cached ~= nil, "lazy: fn returned nil")
    end
    return cached
  end
end

--- Where the quickfix window is opened. Anything unrecognized opens at the
--- bottom.
local QF_OPEN = {
  bottom = "botright copen",
  right = "vertical botright copen",
}

function M.setqflist(content, opts)
  if type(opts) == "string" then
    opts = { cwd = opts }
    if opts.cwd:sub(1, 4) == "cwd=" then
      opts.cwd = opts.cwd:sub(5)
    end
  end
  opts = opts or {}
  opts.open = (opts.open ~= nil) and opts.open or true
  vim.fn.setqflist({}, " ", { title = "Bookmarks", id = "$", items = content })
  if not opts.open then
    return
  end
  -- copen only honours its position modifiers when it has to create the
  -- window, so an already-open one is closed first.
  vim.cmd([[silent! cclose]])
  vim.cmd(QF_OPEN[opts.position] or QF_OPEN.bottom)
  if opts.close_on_select then
    local winid = vim.fn.getqflist({ winid = true }).winid
    local bufnr = winid ~= 0 and vim.api.nvim_win_get_buf(winid) or nil
    if bufnr then
      -- Jump to the entry as usual, then close the list. remap = true so the
      -- <CR> on the right goes through the quickfix window's own <CR>
      -- handling (the qf window has no <CR> mapping, it is built in).
      vim.keymap.set("n", "<CR>", "<CR><Cmd>cclose<CR>", {
        buffer = bufnr,
        silent = true,
        remap = true,
      })
    end
  end
end

return M
