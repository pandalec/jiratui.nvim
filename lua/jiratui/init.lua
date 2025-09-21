-- jiratui/init.lua
local M = {}

local config_module = require("jiratui.config")
local notify = require("jiratui.util").notify
local config_file_exist = require("jiratui.util").config_file_exists()

local function lazy_require_modules()
  local telescope_ok, telescope_module = pcall(require, "jiratui.telescope")
  local issues_ok, issues_module = pcall(require, "jiratui.issues")
  local terminal_ok, terminal_module = pcall(require, "jiratui.terminal")
  pcall(require, "jiratui.rest")
  return telescope_ok, telescope_module, issues_ok, issues_module, terminal_ok, terminal_module
end

function M.setup(user_options)
  local want_notifications = not (user_options and user_options.disable_startup_notification)

  if not config_file_exist then
    if want_notifications then notify("jiratui config.yaml not found. Plugin disabled.", vim.log.levels.WARN) end
    return
  end

  local keys_ok, missing_message = config_module.required_keys_present()
  if not keys_ok then
    if want_notifications then
      notify("jiratui config.yaml missing required keys: " .. tostring(missing_message), vim.log.levels.WARN)
    end
    return
  end

  local options = config_module.setup(user_options or {})

  local telescope_ok, telescope_module, issues_ok, issues_module, terminal_ok, terminal_module = lazy_require_modules()

  vim.api.nvim_create_user_command("JiraTasks", function()
    if telescope_ok and telescope_module and telescope_module.pick then
      telescope_module.pick(options)
    else
      notify("telescope integration is unavailable", vim.log.levels.WARN)
    end
  end, { desc = "Open Jira issues picker" })

  vim.api.nvim_create_user_command("JiraTasksRefresh", function()
    if issues_ok and issues_module and issues_module.refresh_issues_async then
      issues_module.refresh_issues_async(options, nil)
    else
      notify("issues module is unavailable", vim.log.levels.WARN)
    end
  end, { desc = "Refresh Jira issues cache" })

  if options.keymaps then
    vim.keymap.set("n", "<leader>jj", function() vim.cmd("JiraTasks") end, { desc = "Jira: pick issue", silent = true })

    vim.keymap.set(
      "n",
      "<leader>jr",
      function() vim.cmd("JiraTasksRefresh") end,
      { desc = "Jira: refresh issues", silent = true }
    )

    vim.keymap.set("n", "<leader>jt", function()
      if terminal_ok and terminal_module and terminal_module.open_jiratui then
        local project_key = options.filters and options.filters.project or nil
        local jql_id = options.filters and options.filters.default_jql_id or nil
        terminal_module.open_jiratui(nil, project_key, jql_id)
      else
        notify("terminal integration is unavailable", vim.log.levels.WARN)
      end
    end, { desc = "Jira: open jiratui for project", silent = true })
  end

  local augroup_id = vim.api.nvim_create_augroup("JiraTuiInit", { clear = true })
  if options.load_on_startup then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = augroup_id,
      callback = function()
        if want_notifications then notify("jiratui.nvim loaded", vim.log.levels.INFO) end
        if
          options.cache.enabled
          and options.cache.background_refresh
          and issues_ok
          and issues_module
          and issues_module.refresh_issues_async
        then
          vim.schedule(function() issues_module.refresh_issues_async(options, nil) end)
        end
      end,
    })
  end
end

return M
