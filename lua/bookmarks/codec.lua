local config = require("bookmarks.config").config

local M = {}

--- The wire formats, keyed by config.format. MessagePack is binary: its decoder
--- reads lengths instead of scanning text, so it is faster and the files are
--- smaller. JSON stays the default because the files are readable, diffable and
--- hand-editable, which is most of the point of a scope file that lives in a
--- repository next to the code it describes.
local FORMATS = {
  json = { encode = vim.json.encode, decode = vim.json.decode },
  mpack = { encode = vim.mpack.encode, decode = vim.mpack.decode },
}

local OTHER = { json = "mpack", mpack = "json" }

--- config.format, with anything unrecognised read as json rather than crashing
--- on the first save.
local function name()
  return FORMATS[config.format] and config.format or "json"
end

--- A payload this plugin can actually use. Needed because decoding the wrong
--- format does not always raise: msgpack reads the "{" of a json file as the
--- integer 123, and a bare number must not pass for a bookmarks file.
local function valid(decoded)
  return type(decoded) == "table" and type(decoded.data) == "table"
end

function M.encode(payload)
  return FORMATS[name()].encode(payload)
end

--- Decode `text` as the configured format, falling back to the other one.
--- Switching config.format has to keep reading files written under the old
--- setting -- by another nvim instance, or by this one before the change -- and
--- a decode that fails here reads as "no bookmarks" and is then written back
--- over the file.
function M.decode(text)
  if text == nil or text == "" then
    return nil
  end
  local first = name()
  local ok, decoded = pcall(FORMATS[first].decode, text)
  if ok and valid(decoded) then
    return decoded
  end
  local ok2, decoded2 = pcall(FORMATS[OTHER[first]].decode, text)
  if ok2 and valid(decoded2) then
    return decoded2
  end
  return nil
end

return M
