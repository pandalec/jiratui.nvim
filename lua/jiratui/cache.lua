-- lua/jiratui/cache.lua
local M = {}

local uv = vim.uv or vim.loop

local function parent_directory(path) return path:match("^(.*)/[^/]+$") or "." end

local function ensure_directory(path)
  if not path or path == "" then return true end
  local stat = uv.fs_stat(path)
  if stat and stat.type == "directory" then return true end
  local parent = parent_directory(path)
  if parent and parent ~= path then ensure_directory(parent) end
  return uv.fs_mkdir(path, 448) -- 0700
end

function M.read(file_path)
  local handle = io.open(file_path, "r")
  if not handle then return nil end
  local content = handle:read("*a")
  handle:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if ok then return decoded end
  return nil
end

function M.write(file_path, lua_table)
  local ok, encoded = pcall(vim.json.encode, lua_table)
  if not ok then return false end
  ensure_directory(parent_directory(file_path))
  local handle = io.open(file_path, "w")
  if not handle then return false end
  handle:write(encoded)
  handle:close()
  return true
end

return M
