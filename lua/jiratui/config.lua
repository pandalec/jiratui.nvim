-- jiratui/config.lua
local M = {}

local parser = require("jiratui.parser")
local notify = require("jiratui.util").notify

function M.required_keys_present()
  local path = require("jiratui.util").config_path()
  local yaml_root, parse_error = parser.read_yaml_table(path)
  if type(yaml_root) ~= "table" then return false, parse_error or ("cannot read: " .. tostring(path)) end
  local missing = {}
  if not yaml_root.jira_api_base_url or yaml_root.jira_api_base_url == "" then
    table.insert(missing, "jira_api_base_url")
  end
  if not yaml_root.jira_api_username or yaml_root.jira_api_username == "" then
    table.insert(missing, "jira_api_username")
  end
  if not yaml_root.jira_api_token or yaml_root.jira_api_token == "" then table.insert(missing, "jira_api_token") end
  if #missing > 0 then return false, table.concat(missing, ", ") end
  return true
end

local function read_yaml_config()
  local path = require("jiratui.util").config_path()
  local yaml_root, parse_error = parser.read_yaml_table(path)
  if type(yaml_root) ~= "table" then return {}, parse_error end

  local expressions_map = {}
  if type(yaml_root.pre_defined_jql_expressions) == "table" then
    for id_key, record in pairs(yaml_root.pre_defined_jql_expressions) do
      local numeric_id = tonumber(id_key)
      if numeric_id and type(record) == "table" then
        local label = record.label
        local expression = record.expression
        if type(expression) == "string" and expression ~= "" then
          expressions_map[numeric_id] = { label = label, expression = expression }
        end
      end
    end
  end

  local trimmed_base = (yaml_root.jira_api_base_url or ""):gsub("/+$", "")

  local yaml_view = {
    base_url = trimmed_base,
    email = yaml_root.jira_api_username,
    token = yaml_root.jira_api_token,

    default_project_key_or_id = yaml_root.default_project_key_or_id,
    search_results_per_page = tonumber(yaml_root.search_results_per_page),
    search_issues_default_day_interval = tonumber(yaml_root.search_issues_default_day_interval),

    pre_defined_jql_expressions = expressions_map,
    default_jql_expression_id = tonumber(yaml_root.default_jql_expression_id),
    jql_expression_id_for_work_items_search = tonumber(yaml_root.jql_expression_id_for_work_items_search),

    filters_block = type(yaml_root.filters) == "table" and yaml_root.filters or {},
  }

  return yaml_view, nil
end

M.defaults = {
  disable_startup_notification = false,
  keymaps = true,
  load_on_startup = true,
  debug = false,

  cache = {
    background_refresh = true,
    enabled = true,
    path = nil,
    ttl_minutes = 10,
  },

  git = {
    enabled = true,
    remote = "origin",
    branch_template = "{key}-{slug}",
    commit_template = "{key} {summary}",
  },

  telescope = {
    picker_fields = { "key", "summary", "status", "assignee", "priority", "fixVersions" },
    preview_fields = { "description", "fixVersions" },
    sort_by = "updated",
    group_by = "none",
    group_custom_fields = {},
    show_group_headers = true,
  },

  terminal = {
    float_opts = { border = "rounded", title_pos = "center" },
  },

  filters = {
    project = nil,
    assignee = nil,
    status = nil,
    max_results = 100,
    day_interval = nil,
    default_jql_id = nil,
  },
}

M.options = nil
M._yaml_cache = nil

function M.setup(user_options)
  local base = vim.deepcopy(M.defaults)
  M.options = vim.tbl_deep_extend("force", base, user_options or {})

  local yaml_view, parse_error = read_yaml_config()
  M._yaml_cache = yaml_view or {}

  if not M.options.cache.path then M.options.cache.path = vim.fn.stdpath("cache") .. "/jiratui/cache.json" end

  if M.options.filters.project == nil then
    local project_from_yaml = yaml_view.filters_block and yaml_view.filters_block.project
      or yaml_view.default_project_key_or_id
    M.options.filters.project = project_from_yaml
  end

  if M.options.filters.max_results == nil and yaml_view.search_results_per_page then
    M.options.filters.max_results = yaml_view.search_results_per_page
  end

  if M.options.filters.day_interval == nil and yaml_view.search_issues_default_day_interval then
    M.options.filters.day_interval = yaml_view.search_issues_default_day_interval
  end

  if M.options.filters.default_jql_id == nil and yaml_view.default_jql_expression_id then
    M.options.filters.default_jql_id = yaml_view.default_jql_expression_id
  end

  if M.options.debug and parse_error then
    notify("YAML parse warning: " .. tostring(parse_error), vim.log.levels.WARN)
  end

  return M.options
end

function M.get() return M.options or M.defaults end

function M.get_yaml_config()
  if not M._yaml_cache then M._yaml_cache = select(1, read_yaml_config()) or {} end
  local yaml_view = M._yaml_cache or {}
  return {
    base_url = yaml_view.base_url,
    email = yaml_view.email,
    token = yaml_view.token,
    default_project_key_or_id = yaml_view.default_project_key_or_id,
    search_results_per_page = yaml_view.search_results_per_page,
    search_issues_default_day_interval = yaml_view.search_issues_default_day_interval,
    pre_defined_jql_expressions = yaml_view.pre_defined_jql_expressions or {},
    default_jql_expression_id = yaml_view.default_jql_expression_id,
    jql_expression_id_for_work_items_search = yaml_view.jql_expression_id_for_work_items_search,
  }
end

function M.reload_yaml()
  M._yaml_cache = select(1, read_yaml_config()) or {}
  return M._yaml_cache
end

return M
