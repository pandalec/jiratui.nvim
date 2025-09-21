-- jiratui/terminal.lua
local M = {}

local Terminal = require("toggleterm.terminal").Terminal
local config = require("jiratui.config")
local notify = require("jiratui.util").notify

local current_term = nil

local function build_cmd(key, project, jql_id)
  local parts = { "jiratui", "ui" }
  if key and key ~= "" then
    parts[#parts + 1] = "-w"
    parts[#parts + 1] = key
  end
  if project and project ~= "" then
    parts[#parts + 1] = "-p"
    parts[#parts + 1] = project
  end
  if jql_id and tostring(jql_id) ~= "" then
    parts[#parts + 1] = "-j"
    parts[#parts + 1] = tostring(jql_id)
  end
  return table.concat(parts, " ")
end

function M.open_jiratui(key, project, jql_id)
  local opts = config.get()
  local proj = project or (opts.filters and opts.filters.project) or nil
  local jql = jql_id or (opts.filters and opts.filters.default_jql_id) or nil
  local cmd = build_cmd(key, proj, jql)

  if current_term and current_term:is_open() then current_term:close() end

  local float_opts = (opts.terminal and opts.terminal.float_opts) or { border = "rounded", title_pos = "center" }
  current_term = Terminal:new({
    cmd = cmd,
    direction = "float",
    close_on_exit = true,
    float_opts = float_opts,
  })

  local ok = pcall(function() current_term:open() end)
  if not ok then notify("failed to open jiratui terminal", vim.log.levels.ERROR) end
end

return M
