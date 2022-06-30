local M = {}

function M.autocmd(event, opts)
   vim.api.nvim_create_autocmd(event, opts)
end

function M.augroup(name, opts)
   vim.api.nvim_create_augroup(name, opts or {})
end

local callbacks = {}

function M._exec(id, ...)
   callbacks[id](...)
end

local F = M

function M.set(fn, is_expr, args)
   local id

   if jit then
      id = "cb" .. string.format("%p", fn)
   else
      id = "cb" .. tostring(fn):match "function: (.*)"
   end

   if is_expr then
      F[id] = fn
      return string.format("v:lua.require'bookmarks.nvim.callbacks'." .. id)
   else
      if args then
         callbacks[id] = fn
         return string.format('lua require("bookmarks.nvim.callbacks")._exec("%s", %s)', id, args)
      else
         callbacks[id] = function()
            fn()
         end
         return string.format('lua require("bookmarks.nvim.callbacks")._exec("%s")', id)
      end
   end
end

function M.command(name, fn, opts)
   vim.api.nvim_create_user_command(name, fn, opts)
end

function M.highlight(group, opts)
   vim.api.nvim_set_hl(0, group, opts)
end
