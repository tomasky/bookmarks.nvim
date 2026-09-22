local api = vim.api
local config = require("bookmarks.config").config

local M = {}

local group_base = "bookmarks_extmark_signs_"

--- Highlight group for the inline annotation text.
local VIRT_HL = "BookMarksVirtText"

function M.new(cfg, name)
  local self = setmetatable({}, { __index = M })
  self.config = cfg
  self.group = group_base .. (name or "")
  self.ns = api.nvim_create_namespace(self.group)
  return self
end

function M:remove(bufnr)
  api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
end

function M:del(bufnr, id)
  api.nvim_buf_del_extmark(bufnr, self.ns, id)
end

--- Map of extmark id -> 0-based row for every sign in the buffer.
--- One API call, no matter how many signs there are.
function M:positions(bufnr)
  local res = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(bufnr, self.ns, 0, -1, {})) do
    res[m[1]] = m[2]
  end
  return res
end

function M:add(bufnr, signs)
  local cfg = self.config
  local line_count = api.nvim_buf_line_count(bufnr)
  for _, s in ipairs(signs) do
    if s.lnum <= line_count then
      local cs = cfg[s.type]
      local virt = s.virt_text and { { s.virt_text, VIRT_HL } } or nil
      api.nvim_buf_set_extmark(bufnr, self.ns, s.lnum - 1, -1, {
        id = s.id,
        sign_text = s.text or cs.text,
        priority = config.sign_priority,
        sign_hl_group = cs.hl,
        number_hl_group = config.numhl and cs.numhl or nil,
        line_hl_group = config.linehl and cs.linehl or nil,
        virt_text = virt,
        virt_text_pos = virt and "eol" or nil,
      })
    end
  end
end

return M
