local uv = vim.loop
local M = {}

function M.path_exists(path)
   return vim.loop.fs_stat(path) and true or false
end

local jit_os

if jit then
   jit_os = jit.os:lower()
end

local is_unix = false
if jit_os then
   is_unix = jit_os == "linux" or jit_os == "osx" or jit_os == "bsd"
else
   local binfmt = package.cpath:match "%p[\\|/]?%p(%a+)"
   is_unix = binfmt ~= "dll"
end

function M.dirname(file)
   return file:match(string.format("^(.+)%s[^%s]+", M.path_sep, M.path_sep))
end

function M.file_lines(file)
   local text = {}
   for line in io.lines(file) do
      text[#text + 1] = line
   end
   return text
end

M.path_sep = package.config:sub(1, 1)

function M.buf_lines(bufnr)
   local buftext = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
   if vim.bo[bufnr].fileformat == "dos" then
      for i = 1, #buftext do
         buftext[i] = buftext[i] .. "\r"
      end
   end
   return buftext
end

function M.set_lines(bufnr, start_row, end_row, lines)
   if vim.bo[bufnr].fileformat == "dos" then
      for i = 1, #lines do
         lines[i] = lines[i]:gsub("\r$", "")
      end
   end
   vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, lines)
end

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

function M.readfile(filename)
   local data, ok
   local fh, err, code = io.popen(filename, "r")
   if fh then
      data, err, code = fh:read "*a"
      if data then
         ok, err, code = fh:close()
      else
         fh:close()
      end
   end
   if not ok then
      return err .. code
   end
   return data:gsub("\r", "")
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

function M.dump(o)
   if type(o) == "table" then
      local s = "{ "
      for k, v in pairs(o) do
         if type(k) ~= "number" then
            k = '"' .. k .. '"'
         end
         s = s .. "[" .. k .. "] = " .. M.dump(v) .. ","
      end
      return s .. "} "
   else
      return tostring(o)
   end
end

return M
