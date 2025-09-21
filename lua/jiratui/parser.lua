-- jiratui/parser.lua
local M = {}

local function shell_escape_arg(s)
  if not s or s == "" then return "''" end
  -- wrap in single quotes and escape existing single quotes: ' -> '"'"'
  return "'" .. s:gsub("'", [["'"']]) .. "'"
end

function M.read_yaml_table(path)
  if not path or path == "" then return nil, "no path" end
  local f = io.open(path, "r")
  if not f then return nil, "config not found" end
  f:close()

  local cmd = "yq -o=json " .. shell_escape_arg(path)
  local h = io.popen(cmd, "r")
  if not h then return nil, "yq not available or failed to start" end
  local out = h:read("*a")
  h:close()
  if not out or out == "" then return nil, "empty yq output" end

  local ok, tbl = pcall(vim.json.decode, out)
  if not ok or type(tbl) ~= "table" then return nil, "invalid JSON from yq" end
  return tbl, nil
end

function M.extract_predefined_jql_map(root)
  local map = {}
  if type(root) ~= "table" then return map end
  local src = root.pre_defined_jql_expressions
  if type(src) ~= "table" then return map end
  for id_str, rec in pairs(src) do
    local id_num = tonumber(id_str)
    if id_num and type(rec) == "table" then
      local label = rec.label
      local expr = rec.expression
      if type(expr) == "string" and expr ~= "" then map[id_num] = { label = label, expression = expr } end
    end
  end
  return map
end

-- Convert Atlassian ADF description into plain text
local function adf_node_to_text(node, acc)
  if type(node) ~= "table" then return end
  local t = node.type
  if t == "text" and type(node.text) == "string" then
    table.insert(acc, node.text)
  elseif t == "hardBreak" then
    table.insert(acc, "\n")
  elseif node.content and type(node.content) == "table" then
    for _, child in ipairs(node.content) do
      adf_node_to_text(child, acc)
    end
    if t == "paragraph" or t == "heading" then table.insert(acc, "\n") end
  end
end

function M.adf_to_plain_text(value)
  if type(value) == "string" then return value end
  if type(value) ~= "table" then return "" end
  local acc = {}
  adf_node_to_text(value, acc)
  local s = table.concat(acc)
  -- normalize CRLF and collapse excessive blank lines
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("\n\n\n+", "\n\n")
  return s
end

return M
