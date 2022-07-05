local M = {}
M.config = {}

M.schema = {
   keywords = {
      type = "table",
      default = { ["@t"] = "☑️ ", ["@w"] = "⚠️ ", ["@f"] = "⛏ ", ["@n"] = " " },
   },
   cache = {
      type = "table",
      deep_extend = true,
      default = { data = {} },
   },
   save_file = {
      type = "string",
      default = vim.fn.expand "$HOME/.bookmarks",
   },
   sign_priority = {
      type = "number",
      default = 6,
   },
   signcolumn = {
      type = "boolean",
      default = true,
   },
   numhl = {
      type = "boolean",
      default = false,
   },
   linehl = {
      type = "boolean",
      default = false,
   },
   on_attach = {
      type = "function",
      default = nil,
   },
   signs = {
      type = "table",
      deep_extend = true,
      default = {
         add = { hl = "BookMarksAdd", text = "⚑", numhl = "BookMarksAddNr", linehl = "BookMarksAddLn" },
         ann = { hl = "BookMarksAnn", text = "♥", numhl = "BookMarksAnnNr", linehl = "BookMarksAnnLn" },
      },
   },
}

local function validate_config(config)
   for k, v in pairs(config) do
      local kschema = M.schema[k]
      if kschema == nil then
         warn("bookmarks: Ignoring invalid configuration field '%s'", k)
      elseif kschema.type then
         if type(kschema.type) == "string" then
            vim.validate {
               [k] = { v, kschema.type },
            }
         end
      end
   end
end

local function resolve_default(v)
   if type(v.default) == "function" and v.type ~= "function" then
      return (v.default)()
   else
      return v.default
   end
end

function M.build(user_config)
   user_config = user_config or {}
   validate_config(user_config)
   local config = M.config
   for k, v in pairs(M.schema) do
      if user_config[k] ~= nil then
         if v.deep_extend then
            local d = resolve_default(v)
            config[k] = vim.tbl_deep_extend("force", d, user_config[k])
         else
            config[k] = user_config[k]
         end
      else
         config[k] = resolve_default(v)
      end
   end
end

return M
