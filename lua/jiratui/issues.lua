-- lua/jiratui/issues.lua
local M = {}

local rest_adapter = require("jiratui.rest")
local cache_store = require("jiratui.cache")
local notify = require("jiratui.util").notify
local uv = vim.uv or vim.loop

M.cached_issues = nil
M.cached_status = nil
M._loading = false

local function sort_issues_in_place(issues, sort_key)
  if sort_key == "key" then
    table.sort(issues, function(left, right) return (left.key or "") < (right.key or "") end)
    return
  end
  table.sort(issues, function(left, right)
    local left_updated = left.updated or ""
    local right_updated = right.updated or ""
    if left_updated ~= right_updated then return left_updated > right_updated end
    return (left.key or "") < (right.key or "")
  end)
end

local function deduplicate_by_key(issues)
  local seen = {}
  local unique = {}
  for _, issue in ipairs(issues or {}) do
    local k = issue.key
    if k and not seen[k] then
      seen[k] = true
      unique[#unique + 1] = issue
    end
  end
  return unique
end

local function cache_path_from_options(options)
  local path = options and options.cache and options.cache.path
  if path and path ~= "" then return path end
  return vim.fn.stdpath("cache") .. "/jira/cache.json"
end

local function handle_result(options, issues, error_message, done)
  if error_message then
    M.cached_issues = {}
    M.cached_status = "ERROR"
    vim.schedule(function() notify("REST fetch failed: " .. error_message, vim.log.levels.ERROR) end)
  else
    local filtered = deduplicate_by_key(issues or {})
    sort_issues_in_place(filtered, (options and options.telescope and options.telescope.sort_by) or "updated")
    M.cached_issues = filtered
    M.cached_status = "OK"
    cache_store.write(cache_path_from_options(options), { issues = filtered, last_refresh = uv.now() })
    vim.schedule(function() notify(("Issues refreshed (%d)"):format(#filtered)) end)
  end

  M._loading = false
  if done then vim.schedule(function() done(M.cached_issues, M.cached_status) end) end
end

function M.refresh_issues_async(options, callback)
  notify("Refreshing Jira issues in background...")
  return M.load_issues_async(true, options, callback)
end

function M.load_issues(options, refresh)
  if not refresh and M.cached_issues then return M.cached_issues, M.cached_status end
  M.load_issues_async(true, options)
  return M.cached_issues or {}, M.cached_status
end

function M.load_issues_async(force_refresh, options, callback)
  if M._loading then return end
  if not force_refresh and M.cached_issues then
    if callback then callback(M.cached_issues, M.cached_status) end
    return
  end

  M._loading = true
  rest_adapter.fetch_issues(
    options,
    function(issue_list, error_message) handle_result(options, issue_list or {}, error_message, callback) end
  )
end

function M.load_from_disk(options)
  local path = cache_path_from_options(options)
  local data = cache_store.read(path)
  if data and type(data.issues) == "table" then
    M.cached_issues = data.issues
    M.cached_status = "OK"
  end
end

function M.complete_keys()
  local keys = {}
  for _, issue in ipairs(M.cached_issues or {}) do
    keys[#keys + 1] = issue.key
  end
  return keys
end

return M
