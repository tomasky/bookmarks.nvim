local void = require('gitsigns.async').void
local scheduler = require('gitsigns.async').scheduler
local api = vim.api
local uv = vim.loop
local current_buf = api.nvim_get_current_buf

local M = {}
M.setup = void(function(cfg)

end)

return M
