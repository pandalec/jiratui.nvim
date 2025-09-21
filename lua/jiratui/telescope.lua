-- lua/jiratui/telescope.lua
local M = {}

local telescope_ok = pcall(require, "telescope")
if not telescope_ok then return M end

local terminal = require("jiratui.terminal")
local issues_store = require("jiratui.issues")
local config_module = require("jiratui.config")
local notify = require("jiratui.util").notify
local parser = require("jiratui.parser")
local git = require("jiratui.git")

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local config_values = require("telescope.config").values
local actions = require("telescope.actions")
local actions_state = require("telescope.actions.state")
local actions_layout = require("telescope.actions.layout")
local previewers = require("telescope.previewers")

-- Helpers
local function is_group_header(entry_value) return type(entry_value) == "table" and entry_value.__group_header == true end

local function derive_values_for_issue(issue, field_id)
  if field_id == "status" then
    return { issue.status or "∅" }
  elseif field_id == "assignee" then
    local v = (issue.assignee and issue.assignee ~= "" and issue.assignee) or "Unassigned"
    return { v }
  elseif field_id == "type" then
    return { issue.type or "∅" }
  else
    local raw = issue.custom_fields and issue.custom_fields[field_id]
    if raw == nil then return { "∅" } end
    if type(raw) == "table" then
      if #raw == 0 then return { "∅" } end
      local out = {}
      for _, v in ipairs(raw) do
        out[#out + 1] = tostring(v)
      end
      return out
    end
    local t = tostring(raw)
    if t == "" then return { "∅" } end
    return { t }
  end
end

local function apply_all_value_filters(issues, opts)
  local filters = (opts and opts.telescope and opts.telescope.value_filter) or {}
  if not next(filters) then return issues end

  local filtered = issues
  for field_id, enabled_set in pairs(filters) do
    if enabled_set ~= nil then
      local tmp = {}
      for _, issue in ipairs(filtered or {}) do
        if is_group_header(issue) then
          tmp[#tmp + 1] = issue
        else
          local keep = false
          for _, v in ipairs(derive_values_for_issue(issue, field_id)) do
            if enabled_set[v] then
              keep = true
              break
            end
          end
          if keep then tmp[#tmp + 1] = issue end
        end
      end
      filtered = tmp
    end
  end
  return filtered
end

-- Single source of truth for groupable fields (built-ins + custom)
local function configured_groups(opts)
  local tel = (opts and opts.telescope) or {}
  local groups_by_id, order, seen = {}, {}, {}

  local function add(id, name)
    if not id or seen[id] then return end
    seen[id] = true
    groups_by_id[id] = { id = id, name = name or id }
    order[#order + 1] = id
  end

  local builtin = tel.group_fields or { "status", "assignee", "type" }
  for _, id in ipairs(builtin) do
    add(id, id)
  end

  for _, cf in ipairs(tel.group_custom_fields or {}) do
    add(cf.id, cf.name or cf.id)
  end

  return groups_by_id, order
end

local function current_group_label(opts)
  local group_by = (opts and opts.telescope and opts.telescope.group_by) or "none"
  if group_by == "none" then return "none" end
  local by_id = (configured_groups(opts))
  local rec = by_id[group_by]
  return (rec and rec.name) or group_by
end

local function list_custom_group_cycle(opts)
  local _, order = configured_groups(opts)
  local cycle = { "none" }
  for _, id in ipairs(order) do
    cycle[#cycle + 1] = id
  end
  return cycle
end

local function cycle_group_mode(plugin_options, backwards)
  local order = list_custom_group_cycle(plugin_options)
  local current = plugin_options.telescope.group_by or "none"
  local idx = 1
  for i, name in ipairs(order) do
    if name == current then
      idx = i
      break
    end
  end
  if backwards then
    idx = (idx - 2) % #order + 1
  else
    idx = (idx % #order) + 1
  end
  plugin_options.telescope.group_by = order[idx]
end

local function map_custom_id_to_name(plugin_options)
  local out = {}
  local custom_fields = (plugin_options.telescope and plugin_options.telescope.group_custom_fields) or {}
  for _, field in ipairs(custom_fields) do
    if field.id and field.name then out[field.id] = field.name end
  end
  return out
end

local function get_issue_field_for_column(issue, column_name)
  if column_name == "key" then return issue.key or "" end
  if column_name == "summary" then return issue.summary or "" end
  if column_name == "status" then return issue.status or "" end
  if column_name == "type" then return issue.type or "" end
  if column_name == "assignee" then return issue.assignee or "" end
  if column_name == "priority" then return issue.priority or "" end
  if column_name == "fixVersions" then
    local list = issue.fixversions or {}
    if #list == 0 then return "" end
    if #list == 1 then return tostring(list[1]) end
    return tostring(list[1]) .. ", ..."
  end
  if issue.custom_fields and issue.custom_fields[column_name] ~= nil then
    local value = issue.custom_fields[column_name]
    if type(value) == "table" then
      if #value == 0 then return "" end
      if #value == 1 then return tostring(value[1]) end
      return tostring(value[1]) .. ", ..."
    end
    return tostring(value)
  end
  return ""
end

local function group_key_for_issue(issue, plugin_options)
  local group_by = plugin_options and plugin_options.telescope and plugin_options.telescope.group_by or "none"
  if group_by == "none" then return nil end

  if group_by == "status" then
    return issue.status or "∅"
  elseif group_by == "assignee" then
    return (issue.assignee and issue.assignee ~= "" and issue.assignee) or "Unassigned"
  elseif group_by == "type" or group_by == "issuetype" then
    return issue.type or "∅"
  elseif tostring(group_by):match("^customfield_%d+$") then
    local raw = (issue.custom_fields or {})[group_by]
    if raw == nil then return "∅" end
    if type(raw) == "table" then
      if #raw == 0 then return "∅" end
      return tostring(raw[1] or "∅")
    end
    local text = tostring(raw)
    return (text == "" and "∅") or text
  else
    local val = issue[group_by]
    if val == nil then return "∅" end
    if type(val) == "table" then
      if val[1] ~= nil then return tostring(val[1] or "∅") end
      return "∅"
    end
    local s = tostring(val)
    return (s == "" and "∅") or s
  end
end

-- Filter menu (checkbox UI for current group)
local function open_filter_menu(plugin_options, base_items, after_apply)
  local group_by = plugin_options.telescope and plugin_options.telescope.group_by or "none"
  if group_by == "none" then
    notify("No active grouping to filter", vim.log.levels.WARN)
    return
  end

  local counts = {}
  for _, issue in ipairs(base_items or {}) do
    for _, val in ipairs(derive_values_for_issue(issue, group_by)) do
      counts[val] = (counts[val] or 0) + 1
    end
  end

  plugin_options.telescope.value_filter = plugin_options.telescope.value_filter or {}
  local enabled_set = plugin_options.telescope.value_filter[group_by]

  local choices = {}
  for value, cnt in pairs(counts) do
    local checked = (enabled_set == nil) and true or (enabled_set[value] == true)
    table.insert(choices, { label = value, count = cnt, checked = checked })
  end
  table.sort(choices, function(a, b) return tostring(a.label) < tostring(b.label) end)

  local function make_finder()
    return finders.new_table({
      results = choices,
      entry_maker = function(choice)
        local mark = choice.checked and "[x]" or "[ ]"
        local txt = string.format("%s  %s  (%d)", mark, tostring(choice.label), choice.count or 0)
        return { value = choice, display = txt, ordinal = tostring(choice.label):lower() }
      end,
    })
  end

  pickers
    .new({}, {
      prompt_title = "Filter: " .. (current_group_label(plugin_options) or group_by),
      sorter = config_values.generic_sorter({}),
      finder = make_finder(),
      attach_mappings = function(prompt_bufnr, map)
        local function refresh_picker_keep_row(row)
          local picker = actions_state.get_current_picker(prompt_bufnr)
          picker:refresh(make_finder(), { reset_prompt = false })
          if row ~= nil then vim.schedule(function() pcall(picker.set_selection, picker, row) end) end
        end

        local function toggle_current()
          local picker = actions_state.get_current_picker(prompt_bufnr)
          local row = picker:get_selection_row()
          local entry = actions_state.get_selected_entry()
          if not entry or not entry.value then return end
          entry.value.checked = not entry.value.checked
          refresh_picker_keep_row(row)
        end

        map("n", "<Space>", toggle_current)
        map("i", "<Tab>", toggle_current)
        map("i", "<Space>", toggle_current)

        actions.select_default:replace(function()
          local new_set, any_unchecked = {}, false
          for _, c in ipairs(choices) do
            if c.checked then
              new_set[c.label] = true
            else
              any_unchecked = true
            end
          end
          if any_unchecked then
            plugin_options.telescope.value_filter[group_by] = new_set
          else
            plugin_options.telescope.value_filter[group_by] = nil
          end
          actions.close(prompt_bufnr)
          if after_apply then vim.schedule(after_apply) end
        end)

        map("n", "q", function() actions.close(prompt_bufnr) end)
        map("n", "<Esc>", function() actions.close(prompt_bufnr) end)
        return true
      end,
    })
    :find()
end

local function expand_items_for_grouping(issues, plugin_options)
  local group_by = plugin_options and plugin_options.telescope and plugin_options.telescope.group_by or "none"
  if group_by == "none" or not tostring(group_by):match("^customfield_%d+$") then return issues end

  local expanded = {}
  for _, issue in ipairs(issues or {}) do
    local values = {}
    local custom_map = issue.custom_fields or {}
    local raw = custom_map[group_by]
    if type(raw) == "table" then
      for _, v in ipairs(raw) do
        values[#values + 1] = tostring(v)
      end
    elseif raw ~= nil then
      values = { tostring(raw) }
    else
      values = { "∅" }
    end
    if #values == 0 then values = { "∅" } end
    for _, label in ipairs(values) do
      local copy = vim.deepcopy(issue)
      copy.__group_value = (label ~= "" and label) or "∅"
      expanded[#expanded + 1] = copy
    end
  end
  return expanded
end

local function make_grouped_sequence(issues, plugin_options, hidden_groups)
  local group_by = plugin_options and plugin_options.telescope and plugin_options.telescope.group_by or "none"
  if group_by == "none" then return issues end

  local buckets = {}
  for _, issue in ipairs(issues or {}) do
    local key = group_key_for_issue(issue, plugin_options)
    if key == nil and issue.__group_value then key = issue.__group_value end
    key = key or "∅"
    buckets[key] = buckets[key] or {}
    table.insert(buckets[key], issue)
  end

  local keys_sorted = {}
  for k in pairs(buckets) do
    keys_sorted[#keys_sorted + 1] = k
  end
  table.sort(keys_sorted, function(a, b) return tostring(a) < tostring(b) end)

  local combined = {}
  local show_headers = plugin_options.telescope.show_group_headers ~= false
  for _, key in ipairs(keys_sorted) do
    local is_hidden = hidden_groups and hidden_groups[key] or false
    if show_headers then
      combined[#combined + 1] = {
        __group_header = true,
        __group_title = key,
        __group_hidden = is_hidden,
        display = (is_hidden and "▸ " .. key .. " (hidden)") or ("▸ " .. key),
      }
    end
    if not is_hidden then
      for _, issue in ipairs(buckets[key]) do
        combined[#combined + 1] = issue
      end
    end
  end
  return combined
end

local function compute_column_widths(issues, column_names)
  local widths = {}
  for _, name in ipairs(column_names) do
    widths[name] = math.max(3, vim.fn.strdisplaywidth(name))
  end

  local function bump(name, value)
    local as_string = tostring(value or "")
    local length = vim.fn.strdisplaywidth(as_string)
    if length > (widths[name] or 0) then widths[name] = length end
  end

  for _, issue in ipairs(issues or {}) do
    if not is_group_header(issue) then
      for _, name in ipairs(column_names) do
        local value = get_issue_field_for_column(issue, name)
        bump(name, value)
      end
    end
  end

  for name, w in pairs(widths) do
    widths[name] = w + 2
  end

  local has_summary = false
  for _, name in ipairs(column_names) do
    if name == "summary" then
      has_summary = true
      break
    end
  end
  if has_summary then
    local ui = vim.api.nvim_list_uis()[1]
    local ui_width = (ui and ui.width) or 120
    local sep_width = vim.fn.strdisplaywidth(" │ ") * (#column_names - 1)
    local fixed = 0
    for _, name in ipairs(column_names) do
      if name ~= "summary" then fixed = fixed + (widths[name] or 0) end
    end
    widths.summary = math.max(20, ui_width - fixed - sep_width - 4)
  end

  return widths
end

local function build_displayer(column_names, widths)
  local items = {}
  for _, name in ipairs(column_names) do
    table.insert(items, { width = widths[name] })
  end
  local create = require("telescope.pickers.entry_display").create
  return create({ separator = " │ ", items = items })
end

local function truncate_to_width(text, max_width)
  local value = text or ""
  if vim.fn.strdisplaywidth(value) <= max_width then return value end
  return vim.fn.strcharpart(value, 0, math.max(0, max_width - 1)) .. "…"
end

local function format_entry(issue, column_names, widths)
  local cells = {}
  for _, name in ipairs(column_names) do
    local cell_value = get_issue_field_for_column(issue, name)
    if name == "summary" then
      cell_value = (cell_value or ""):gsub("%s+", " ")
      cell_value = truncate_to_width(cell_value, widths.summary or 40)
    end
    table.insert(cells, { cell_value })
  end
  return cells
end

local function build_preview_lines(issue, preview_field_names, custom_id_to_name)
  local lines = {}

  for _, field_name in ipairs(preview_field_names or {}) do
    if field_name == "description" then
      local text = parser.adf_to_plain_text(issue.description)
      local description_lines = vim.split(text or "", "\n", { plain = true })
      if #description_lines == 0 then description_lines = { "(no description)" } end
      for _, line in ipairs(description_lines) do
        lines[#lines + 1] = (line or ""):gsub("\r", "")
      end
      lines[#lines + 1] = ""
    elseif field_name == "fixVersions" then
      lines[#lines + 1] = "FixVersions:"
      local list = issue.fixversions or {}
      if #list == 0 then
        lines[#lines + 1] = "  - (none)"
      else
        for _, name in ipairs(list) do
          lines[#lines + 1] = "  - " .. tostring(name)
        end
      end
      lines[#lines + 1] = ""
    elseif issue.custom_fields and issue.custom_fields[field_name] ~= nil then
      local display_name = custom_id_to_name[field_name] or field_name
      local raw = issue.custom_fields[field_name]
      if type(raw) == "table" then
        lines[#lines + 1] = display_name .. ":"
        if #raw == 0 then
          lines[#lines + 1] = "  - (none)"
        else
          for _, v in ipairs(raw) do
            lines[#lines + 1] = "  - " .. tostring(v)
          end
        end
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = string.format("%s: %s", display_name, tostring(raw))
      end
    elseif type(field_name) == "string" and field_name:match("^customfield_%d+$") then
      local display_name = custom_id_to_name[field_name] or field_name
      lines[#lines + 1] = string.format("%s: (none)", display_name)
    else
      local plain_value = tostring(get_issue_field_for_column(issue, field_name) or "")
      lines[#lines + 1] = string.format("%s: %s", field_name, plain_value)
    end
  end

  if #lines == 0 then lines = { "(no preview fields configured)" } end
  return lines
end

local function build_picker_title(plugin_options)
  local group_by = plugin_options and plugin_options.telescope and plugin_options.telescope.group_by or "none"
  if group_by == "none" then return "Jira Issues  [? help]" end
  return "Jira Issues  [group: " .. current_group_label(plugin_options) .. "]  [? help]"
end

-- Help overlay
local help_state = { win = nil, buf = nil }

local function close_help_window()
  if help_state.win and vim.api.nvim_win_is_valid(help_state.win) then
    pcall(vim.api.nvim_win_close, help_state.win, true)
  end
  if help_state.buf and vim.api.nvim_buf_is_valid(help_state.buf) then
    pcall(vim.api.nvim_buf_delete, help_state.buf, { force = true })
  end
  help_state.win, help_state.buf = nil, nil
end

local function toggle_help_overlay(prompt_bufnr)
  if help_state.win and vim.api.nvim_win_is_valid(help_state.win) then
    close_help_window()
    return
  end

  local lines = {
    "jiratui.nvim — Telescope",
    "",
    "Keymaps:",
    "<CR>      Open in jiratui (-w <KEY>)",
    "<C-b>     Create/switch Git branch for selection",
    "<C-g>     Cycle grouping forward",
    "<C-S-g>   Cycle grouping backward",
    "<C-i>     Toggle preview",
    "<C-o>     Open in browser",
    "<C-r>     Refresh issues",
    "<C-f>     Filter current group (checkboxes)",
    "?         Toggle help",
  }

  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.max(width + 2, 56)
  local height = #lines

  local help_win = vim.api.nvim_open_win(help_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    border = "rounded",
    style = "minimal",
    title = "Help",
    title_pos = "center",
    focusable = false,
    zindex = 200,
  })

  help_state.win, help_state.buf = help_win, help_buf

  local function refocus_picker()
    if prompt_bufnr and vim.api.nvim_buf_is_valid(prompt_bufnr) then
      local picker = actions_state.get_current_picker(prompt_bufnr)
      if picker and picker.prompt_win and vim.api.nvim_win_is_valid(picker.prompt_win) then
        vim.api.nvim_set_current_win(picker.prompt_win)
        vim.cmd("startinsert")
      end
    end
  end

  local function close_and_refocus()
    pcall(vim.api.nvim_win_close, help_win, true)
    vim.schedule(refocus_picker)
  end

  vim.keymap.set("n", "q", close_and_refocus, { buffer = help_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close_and_refocus, { buffer = help_buf, nowait = true, silent = true })

  if prompt_bufnr and vim.api.nvim_buf_is_valid(prompt_bufnr) then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = prompt_bufnr,
      once = true,
      callback = function() close_help_window() end,
    })
  end
end

-- Picker
function M.pick(plugin_options)
  local function open_picker_with_items(issue_items)
    if not issue_items or #issue_items == 0 then
      notify("No issues", vim.log.levels.WARN)
      return
    end

    local picker_columns = (plugin_options.telescope and plugin_options.telescope.picker_fields)
      or { "key", "summary", "status", "assignee", "priority", "fixVersions" }

    local base_items = issue_items
    local filtered_base = apply_all_value_filters(base_items, plugin_options)
    local expanded_items = expand_items_for_grouping(filtered_base, plugin_options)
    local grouped_items = make_grouped_sequence(expanded_items, plugin_options)

    local column_widths = compute_column_widths(grouped_items, picker_columns)
    local title_text = build_picker_title(plugin_options)
    local displayer = build_displayer(picker_columns, column_widths)
    local custom_id_to_name = map_custom_id_to_name(plugin_options)
    local preview_field_names = (plugin_options.telescope and plugin_options.telescope.preview_fields)
      or { "description", "fixVersions" }

    pickers
      .new({}, {
        prompt_title = title_text,
        sorting_strategy = "ascending",
        finder = finders.new_table({
          results = grouped_items,
          entry_maker = function(issue_or_header)
            if is_group_header(issue_or_header) then
              return {
                value = issue_or_header,
                display = issue_or_header.display,
                ordinal = ("grp:%s:header"):format(issue_or_header.__group_title or ""),
              }
            end
            return {
              value = issue_or_header,
              display = function(entry)
                local row = entry.value
                local cells = format_entry(row, picker_columns, column_widths)
                return displayer(cells)
              end,
              ordinal = table
                .concat({
                  issue_or_header.key or "",
                  issue_or_header.summary or "",
                  issue_or_header.status or "",
                  issue_or_header.assignee or "",
                  issue_or_header.priority or "",
                  issue_or_header.url or "",
                }, " ")
                :lower(),
            }
          end,
        }),
        sorter = config_values.generic_sorter({}),
        previewer = previewers.new_buffer_previewer({
          title = "Preview",
          define_preview = function(self, entry)
            local entry_value = entry.value
            local preview_lines = {}
            if not is_group_header(entry_value) then
              preview_lines = build_preview_lines(entry_value, preview_field_names, custom_id_to_name)
            end
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
            vim.api.nvim_set_option_value("filetype", "markdown", { buf = self.state.bufnr })
          end,
        }),
        attach_mappings = function(prompt_bufnr, map)
          vim.schedule(function() actions_layout.toggle_preview(prompt_bufnr) end)

          actions.select_default:replace(function()
            local selected = actions_state.get_selected_entry()
            if not selected or is_group_header(selected.value) then return end
            local issue_key = selected.value.key
            local project_key = plugin_options.filters and plugin_options.filters.project or nil
            local jql_id = plugin_options.filters and plugin_options.filters.default_jql_id or nil
            actions.close(prompt_bufnr)
            vim.schedule(function() terminal.open_jiratui(issue_key, project_key, jql_id) end)
          end)

          local function open_in_browser()
            local selected = actions_state.get_selected_entry()
            if not selected or is_group_header(selected.value) then return end
            local url = selected.value.url
            if not url or url == "" then return end
            local opener = vim.fn.has("mac") == 1 and "open" or (vim.fn.has("unix") == 1 and "xdg-open" or nil)
            if opener then vim.fn.jobstart({ opener, url }, { detach = true }) end
          end
          map("i", "<C-o>", open_in_browser)
          map("n", "<C-o>", open_in_browser)

          local function do_refresh()
            local current = prompt_bufnr
            issues_store.refresh_issues_async(plugin_options, function()
              actions.close(current)
              vim.schedule(function() M.pick(plugin_options) end)
            end)
          end
          map("i", "<C-r>", do_refresh)
          map("n", "<C-r>", do_refresh)

          map("i", "<C-i>", actions_layout.toggle_preview)
          map("n", "<C-i>", actions_layout.toggle_preview)
          map("i", "<C-p>", actions_layout.toggle_preview)
          map("n", "<C-p>", actions_layout.toggle_preview)

          map("i", "?", function() toggle_help_overlay(prompt_bufnr) end)
          map("n", "?", function() toggle_help_overlay(prompt_bufnr) end)

          local function cycle_forward()
            cycle_group_mode(plugin_options, false)
            actions.close(prompt_bufnr)
            vim.schedule(function() M.pick(plugin_options) end)
          end
          local function cycle_backward()
            cycle_group_mode(plugin_options, true)
            actions.close(prompt_bufnr)
            vim.schedule(function() M.pick(plugin_options) end)
          end
          map("i", "<C-g>", cycle_forward)
          map("n", "<C-g>", cycle_forward)
          map("i", "<C-S-g>", cycle_backward)
          map("n", "<C-S-g>", cycle_backward)

          -- Git: create/switch branch for selection(s)
          local function create_branches_for_selection()
            if not git.is_enabled() then
              notify("Git functionality disabled or git not available", vim.log.levels.WARN)
              return
            end

            local picker = actions_state.get_current_picker(prompt_bufnr)
            local multi = (picker and picker:get_multi_selection()) or {}
            local targets = {}

            if #multi > 0 then
              for _, e in ipairs(multi) do
                if e and e.value and not is_group_header(e.value) then targets[#targets + 1] = e.value end
              end
            else
              local sel = actions_state.get_selected_entry()
              if sel and sel.value and not is_group_header(sel.value) then targets[#targets + 1] = sel.value end
            end

            if #targets == 0 then
              notify("No issue selected", vim.log.levels.WARN)
              return
            end

            for _, issue in ipairs(targets) do
              local name, err = git.switch_to_issue_branch(issue, { create_if_missing = true })
              if name then
                notify("Branch ready: " .. name)
              else
                notify("Git: " .. (err or "unknown error"), vim.log.levels.ERROR)
              end
            end

            -- Keep picker open so user can continue; do not close it
          end

          map("i", "<C-b>", create_branches_for_selection)
          map("n", "<C-b>", create_branches_for_selection)

          -- Open value-filter UI
          local function open_filters_ui()
            local parent_bufnr = prompt_bufnr
            actions.close(parent_bufnr)
            vim.schedule(function()
              open_filter_menu(plugin_options, issue_items, function() M.pick(plugin_options) end)
            end)
          end
          map("i", "<C-f>", open_filters_ui)
          map("n", "<C-f>", open_filters_ui)

          return true
        end,
      })
      :find()
  end

  local items = issues_store.cached_issues
  if not items or #items == 0 then
    issues_store.load_from_disk(config_module.get())
    items = issues_store.cached_issues
  end
  if not items or #items == 0 then
    issues_store.refresh_issues_async(config_module.get(), function(new_items)
      vim.schedule(function() open_picker_with_items(new_items or issues_store.cached_issues or {}) end)
    end)
  else
    open_picker_with_items(items)
  end
end

return M
