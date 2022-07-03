local api = vim.api
local config = require("bookmarks.config").config

local M = {}

local group_base = "bookmarks_extmark_signs_"

function M.new(cfg, name)
   local self = setmetatable({}, { __index = M })
   self.config = cfg
   self.group = group_base .. (name or "")
   self.ns = api.nvim_create_namespace(self.group)
   return self
end

function M:on_lines(buf, last_new)
   self:remove(buf, last_new + 1)
end

function M:remove(bufnr, start_lnum)
   if start_lnum then
      api.nvim_buf_clear_namespace(bufnr, self.ns, start_lnum - 1, start_lnum)
   else
      api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
   end
end

function M:add(bufnr, signs)
   local cfg = self.config

   for _, s in ipairs(signs) do
      if not self:contains(bufnr, s.lnum) then
         local cs = cfg[s.type]
         local text = cs.text

         api.nvim_buf_set_extmark(bufnr, self.ns, s.lnum - 1, -1, {
            id = s.lnum,
            sign_text = text,
            priority = config.sign_priority,
            sign_hl_group = cs.hl,
            number_hl_group = config.numhl and cs.numhl or nil,
            line_hl_group = config.linehl and cs.linehl or nil,
         })
      end
   end
end

function M:contains(bufnr, start)
   local marks = api.nvim_buf_get_extmarks(bufnr, self.ns, { start - 1, 0 }, { start, 0 }, { limit = 1 })
   return #marks > 0
end

function M:reset()
   for _, buf in ipairs(api.nvim_list_bufs()) do
      self:remove(buf)
   end
end

local signs

M.setup = function()
   signs = M.new(config.signs)
end

M.detach = function(bufnr, keep_signs)
   if not keep_signs then
      signs:remove(bufnr)
   end
end

return M
