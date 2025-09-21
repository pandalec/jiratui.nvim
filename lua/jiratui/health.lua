-- jiratui/health.lua
local M = {}

local config = require("jiratui.config")
local parser = require("jiratui.parser")
local config_file_exist = require("jiratui.util").config_file_exists()

local function H() return vim.health end

function M.check()
  local h = H()
  h.start("jiratui.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim 0.10+ required")
  end

  if vim.fn.executable("yq") == 1 then
    h.ok("yq found in PATH")
  else
    h.error("yq not found in PATH")
  end

  if vim.fn.executable("curl") == 1 then
    h.ok("curl found in PATH")
  else
    h.error("curl not found in PATH")
  end

  do
    local ok = pcall(require, "toggleterm.terminal")
    if ok then
      h.ok("toggleterm available")
    else
      h.warn("toggleterm not found")
    end
  end

  do
    local ok = pcall(require, "telescope")
    if ok then
      h.ok("telescope available")
    else
      h.warn("telescope not found")
    end
  end

  local path = require("jiratui.util").config_path()
  if not config_file_exist then
    h.warn("config.yaml not found at " .. path)
    return
  end
  h.ok("config.yaml found at " .. path)

  local root, err = parser.read_yaml_table(path)
  if type(root) ~= "table" then
    h.error("failed to parse config.yaml: " .. tostring(err))
    return
  end

  local function empty(x) return x == nil or x == "" end
  local missing = {}
  if empty(root.jira_api_base_url) then table.insert(missing, "jira_api_base_url") end
  if empty(root.jira_api_username) then table.insert(missing, "jira_api_username") end
  if empty(root.jira_api_token) then table.insert(missing, "jira_api_token") end
  if #missing == 0 then
    h.ok("required credentials present")
  else
    h.error("missing required keys: " .. table.concat(missing, ", "))
  end

  local defs = root.pre_defined_jql_expressions or {}
  local opts = config.get()
  local id = opts.filters and opts.filters.default_jql_id or nil
  if id then
    if defs[tostring(id)] or defs[tonumber(id)] then
      h.ok("default_jql_id " .. id .. " present in pre_defined_jql_expressions")
    else
      h.warn("default_jql_id " .. id .. " not found in pre_defined_jql_expressions")
    end
  end
end

return M
