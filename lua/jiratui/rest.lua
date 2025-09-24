-- lua/jiratui/rest.lua
local M = {}

local config = require("jiratui.config")
local notify = require("jiratui.util").notify

local function cfg() return config.get(), config.get_yaml_config() end
local function to_lua_value(value)
  if value == vim.NIL then return nil end
  return value
end

local function table_or_nil(value)
  value = to_lua_value(value)
  return type(value) == "table" and value or nil
end

local function extract_fix_versions_from_fields(fields_table)
  local list = {}
  local fix_versions_field = table_or_nil(fields_table.fixVersions)
  if type(fix_versions_field) == "table" then
    for _, one in ipairs(fix_versions_field) do
      local as_table = table_or_nil(one)
      local name = as_table and (as_table.name or as_table.label or as_table.id) or to_lua_value(one)
      if name and name ~= "" then table.insert(list, tostring(name)) end
    end
  end
  return list
end

local function extract_custom_fields_from_fields(fields_table, requested_custom_ids)
  local result = {}
  for custom_id, _ in pairs(requested_custom_ids or {}) do
    local raw_value = to_lua_value(fields_table[custom_id])
    if raw_value ~= nil then
      if type(raw_value) == "table" then
        if raw_value[1] ~= nil then
          local array_values = {}
          for _, element in ipairs(raw_value) do
            local element_table = table_or_nil(element)
            if element_table then
              array_values[#array_values + 1] = element_table.name
                or element_table.value
                or element_table.displayName
                or element_table.key
                or vim.inspect(element_table)
            else
              array_values[#array_values + 1] = tostring(to_lua_value(element))
            end
          end
          result[custom_id] = array_values
        else
          local single_table = table_or_nil(raw_value)
          if single_table then
            result[custom_id] = tostring(
              single_table.name
                or single_table.value
                or single_table.displayName
                or single_table.key
                or vim.inspect(single_table)
            )
          end
        end
      else
        result[custom_id] = tostring(raw_value)
      end
    end
  end
  return result
end
local function base_url()
  local _, ycfg = cfg()
  return ((ycfg.base_url or ""):gsub("/+$", ""))
end

local function credentials_ok()
  local _, ycfg = cfg()
  if not ycfg.base_url or ycfg.base_url == "" then return false, "JIRA_BASE_URL missing" end
  if not ycfg.email or ycfg.email == "" or not ycfg.token or ycfg.token == "" then
    return false, "email/token missing from config YAML"
  end
  return true
end

local function pick_requested_fields(opts)
  local requested = {
    key = true,
    summary = true,
    description = true,
    issuetype = true,
    status = true,
    assignee = true,
    priority = true,
    updated = true,
    project = true,
    fixVersions = true,
  }

  local function add_field(name)
    if type(name) ~= "string" then return end
    if name:match("^customfield_%d+$") then
      requested[name] = true
    elseif requested[name] ~= nil then
      requested[name] = true
    end
  end

  local tel = opts.telescope or {}
  for _, n in ipairs(tel.picker_fields or {}) do
    add_field(n)
  end
  for _, n in ipairs(tel.preview_fields or {}) do
    add_field(n)
  end
  for _, rec in ipairs(tel.group_custom_fields or {}) do
    if type(rec) == "table" and rec.id then add_field(rec.id) end
  end

  local list = {}
  for name, _ in pairs(requested) do
    table.insert(list, name)
  end
  table.sort(list)
  return list
end

local function urlencode_jql(s)
  s = tostring(s or "")
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_order_clause(jql)
  if not jql or jql == "" then return nil, nil end
  local where, order = jql:match("^(.-)%s+[Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy]%s+(.+)$")
  if where and where:match("%S") then return where, order end
  local only = jql:match("^[Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy]%s+(.+)$")
  if only and only:match("%S") then return nil, only end
  return jql, nil
end

local function compose_jql(opts)
  local _, yaml_cfg = cfg()
  local expr = nil
  local wanted_id = opts.filters and opts.filters.default_jql_id or nil
  local map = yaml_cfg.pre_defined_jql_expressions or {}

  if wanted_id and map[wanted_id] and map[wanted_id].expression then
    expr = map[wanted_id].expression
  elseif wanted_id then
    vim.schedule(
      function()
        notify(
          ("default_jql_id %s not found in pre_defined_jql_expressions"):format(tostring(wanted_id)),
          vim.log.levels.WARN
        )
      end
    )
  end

  local where, order = split_order_clause(expr)

  local extras = {}
  if opts.filters and opts.filters.project then
    table.insert(extras, ('project = "%s"'):format(opts.filters.project))
  end
  if opts.filters and opts.filters.assignee then
    local who = opts.filters.assignee == "me" and "currentUser()" or opts.filters.assignee
    table.insert(extras, ("assignee = %s"):format(who))
  end
  if opts.filters and type(opts.filters.status) == "table" and #opts.filters.status > 0 then
    table.insert(extras, ('status in ("%s")'):format(table.concat(opts.filters.status, '","')))
  end

  local parts = {}
  if where and where:match("%S") then parts[#parts + 1] = "(" .. where .. ")" end
  if #extras > 0 then parts[#parts + 1] = table.concat(extras, " AND ") end

  local merged = table.concat(parts, " AND ")
  if order and order:match("%S") then
    if merged == "" then
      return "ORDER BY " .. order
    else
      return merged .. " ORDER BY " .. order
    end
  end
  return merged
end

local function curl_json(url, body_tbl, cb)
  local _, ycfg = cfg()
  local ok, err = credentials_ok()
  if not ok then return cb(nil, err) end

  local body = vim.json.encode(body_tbl or {})
  local cmd = {
    "curl",
    "-sS",
    "-u",
    string.format("%s:%s", ycfg.email, ycfg.token),
    "-H",
    "Accept: application/json",
    "-H",
    "Content-Type: application/json",
    "-X",
    "POST",
    url,
    "--data-binary",
    "@" .. "-",
  }

  vim.system(cmd, { text = true, stdin = body }, function(res)
    local raw = res.stdout or ""
    local okj, decoded = pcall(vim.json.decode, raw)
    if okj and type(decoded) == "table" then
      if type(decoded.errorMessages) == "table" and #decoded.errorMessages > 0 then
        return cb(nil, table.concat(decoded.errorMessages, "; "))
      end
      return cb(decoded, nil)
    end
    if res.code ~= 0 then
      local msg = (res.stderr and res.stderr ~= "" and res.stderr) or raw or "curl error"
      return cb(nil, ("curl failed (%d): %s"):format(res.code, msg))
    end
    return cb(nil, "Invalid JSON from Jira")
  end)
end

local function normalize_issue(raw_issue, requested_custom_ids)
  local fields = table_or_nil(raw_issue and raw_issue.fields) or {}

  local fixversions = extract_fix_versions_from_fields(fields)
  local custom_fields = extract_custom_fields_from_fields(fields, requested_custom_ids)

  local assignee_table = table_or_nil(fields.assignee)
  local priority_table = table_or_nil(fields.priority)
  local status_table = table_or_nil(fields.status)
  local issuetype_table = table_or_nil(fields.issuetype)
  local project_table = table_or_nil(fields.project)

  local description_value = to_lua_value(fields.description)

  return {
    key = to_lua_value(raw_issue.key),
    summary = to_lua_value(fields.summary) or "",
    description = description_value,
    type = (issuetype_table and issuetype_table.name) or "",
    status = (status_table and status_table.name) or "",
    assignee = assignee_table and (assignee_table.displayName or assignee_table.name) or "",
    priority = priority_table and priority_table.name or "",
    updated = to_lua_value(fields.updated) or "",
    project = project_table and (project_table.key or project_table.name) or "",
    url = string.format("%s/browse/%s", base_url(), to_lua_value(raw_issue.key) or ""),

    fixversions = fixversions,
    custom_fields = custom_fields,
  }
end

local function requested_custom_id_set(opts)
  local ids = {}
  local tel = opts.telescope or {}
  for _, n in ipairs(tel.picker_fields or {}) do
    if type(n) == "string" and n:match("^customfield_%d+$") then ids[n] = true end
  end
  for _, n in ipairs(tel.preview_fields or {}) do
    if type(n) == "string" and n:match("^customfield_%d+$") then ids[n] = true end
  end
  for _, rec in ipairs(tel.group_custom_fields or {}) do
    if type(rec) == "table" and rec.id then ids[rec.id] = true end
  end
  return ids
end

local function search_page(opts, next_token, page_size, cb)
  local debug_on = opts.debug == true
  local jql = compose_jql(opts)
  local fields = pick_requested_fields(opts)

  local url = string.format("%s/rest/api/3/search/jql", base_url())
  local body = {
    fields = fields,
    maxResults = page_size,
  }
  if jql and jql ~= "" then body.jql = urlencode_jql(jql) end
  if next_token and next_token ~= "" then body.nextPageToken = next_token end

  if debug_on then
    local jql_display = (body.jql and body.jql ~= "" and body.jql) or "<none>"
    vim.schedule(
      function()
        notify(
          ("POST /search/jql maxResults=%d nextPageToken=%s jql=%s"):format(
            page_size,
            tostring(next_token or "nil"),
            jql_display
          )
        )
      end
    )
  end

  curl_json(url, body, cb)
end

function M.fetch_issues(opts, cb)
  local options = opts or {}
  local custom_ids = requested_custom_id_set(options)

  local target = (options.filters and options.filters.max_results) or 100
  local should_paginate = (target == -1) or (target and target > 100)
  local page_size = (not should_paginate) and (target or 100) or 100

  if not should_paginate then
    search_page(options, nil, page_size, function(json, err)
      if err then return cb(nil, err) end
      local out = {}
      for _, raw in ipairs(json.issues or {}) do
        out[#out + 1] = normalize_issue(raw, custom_ids)
      end
      cb(out, nil)
    end)
    return
  end

  local collected, next_token = {}, nil

  local function step()
    search_page(options, next_token, page_size, function(json, err)
      if err then return cb(nil, err) end

      for _, raw in ipairs(json.issues or {}) do
        collected[#collected + 1] = normalize_issue(raw, custom_ids)
      end

      next_token = json.nextPageToken
      local is_last = json.isLast == true or not next_token
      local have_enough = (target ~= -1) and (#collected >= target)

      if is_last or have_enough then
        if target ~= -1 and #collected > target then
          while #collected > target do
            table.remove(collected)
          end
        end
        return cb(collected, nil)
      else
        step()
      end
    end)
  end

  step()
end

return M
