# jiratui.nvim

Telescope-powered Jira picker for Neovim — list, preview, group, and open issues from your editor. Optional Git helpers let you create/switch branches and craft commit messages from issues.

> ⚠️ **Status**: pre-alpha. APIs and defaults may change.

> 🙌 **Credits**: Built on the CLI **[whyisdifficult/jiratui](https://github.com/whyisdifficult/jiratui)** and reuses its YAML configuration (credentials and predefined JQL).

---

## Features

- **Telescope picker**
  - Configurable **columns** (`telescope.picker_fields`) and **preview** (`telescope.preview_fields`)
  - Group by **status**, **assignee**, **issue type**, or any **customfield_XXXXX**
  - Optional group **headers**
  - **Per-group value filters** with checkbox UI; filters stack across groups
  - Open in browser, open external **jiratui** TUI, refresh, toggle preview

- **Flexible JQL via `jiratui` YAML**
  - Use `filters.default_jql_id` to select a predefined JQL by id
  - Set `filters.default_jql_id = -1` to **auto-select by current repo name** matching a YAML label
  - Merge extra filters (`project`, `assignee`, `status`, `day_interval`) while preserving `ORDER BY`
  - `filters.max_results = -1` or `> 100` triggers automatic pagination

- **Readable preview**
  - Jira ADF → plain text
  - `fixVersions` handled as a list; list view shows the first value

- **Caching & background refresh**
  - On-disk cache with TTL minutes
  - Optional background refresh on startup

- **Optional Git integration**
  - Create/switch branches and craft commit messages from issues
  - Templates: `{key}`, `{slug}`, `{summary}`
  - Remote configurable (default `"origin"`)

- **Health checks**
  - `:checkhealth jiratui` validates tools, config, and environment

- **Conditional activation**
  - `load_on_found_jql_id = true` activates the plugin **only** when the current Git repo name matches a JQL label in the YAML
  - `disable_startup_notification` controls whether a “disabled” notice is shown

---

## Requirements

- Neovim ≥ 0.10
- curl
- yq
- nvim-lua/plenary.nvim
- nvim-telescope/telescope.nvim
- akinsho/toggleterm.nvim (recommended)
- whyisdifficult/jiratui CLI installed and configured

This plugin reuses the jiratui CLI YAML for credentials and predefined JQL.

---

## Installation

> Note: The Lazy.nvim example below is untested.  
> Requires Neovim 0.12+ nightly for the `vim.pack` method.

### Neovim 0.12 nightly — via `vim.pack`

```lua
vim.pack.add({
  { src = "https://github.com/nvim-lua/plenary.nvim" },
  { src = "https://github.com/nvim-telescope/telescope.nvim" },
  { src = "https://github.com/akinsho/toggleterm.nvim" },
  { src = "https://github.com/pandalec/jiratui.nvim" },
})

-- Configure after add()
require("jiratui").setup({})
```

### Using lazy.nvim (untested)

```lua
{
  "pandalec/jiratui.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    "akinsho/toggleterm.nvim",
  },
  config = function()
    require("jiratui").setup({})
  end,
}
```

---

## Configuration

### jiratui (CLI) YAML

> Uses the same YAML as [jiratui](https://jiratui.readthedocs.io/en/latest/users/configuration/index.html).
> Search order:
>
> 1. $JIRA_TUI_CONFIG_FILE
> 2. $XDG_CONFIG_HOME/jiratui/config.yaml
> 3. $HOME/.config/jiratui/config.yaml

```yaml
# Required authentication
jira_api_base_url: https://your-company.atlassian.net
jira_api_username: you@example.com
jira_api_token: atlassian-token

# Predefined JQL expressions
pre_defined_jql_expressions:
  10:
    label: My Open Issues
    expression: assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC
  20:
    label: Project PROJ
    expression: project = "PROJ" ORDER BY updated DESC
  30:
    label: repository-name # use as default if name matches repository with default_jql_id = -1
    expression: project = "PROJ" ORDER BY updated DESC
```

Refer to

### Plugin `setup()` options (defaults)

```lua
{
  debug = false,                         -- enable verbose logging and parse warnings
  disable_startup_notification = false,  -- show "disabled" notifications on startup
  keymaps = true,                        -- register default keymaps
  load_on_found_jql_id = false,          -- enable plugin only if repo name matches a JQL label in YAML
  load_on_startup = true,                -- refresh cache on VimEnter if enabled

  cache = {
    background_refresh = true,           -- refresh issues in background on startup
    enabled = true,                      -- use on-disk cache
    path = nil,                          -- custom cache path; defaults to stdpath("cache")/jiratui/cache.json
    ttl_minutes = 10,                    -- cache TTL in minutes
  },

  git = {
    branch_template = "{key}-{slug}",    -- branch name template
    commit_template = "{key} {summary}", -- commit message template
    enabled = true,                      -- enable Git helpers
    remote = "origin",                   -- default remote for branch discovery
  },

  telescope = {
    group_by = "none",                   -- "none"|"status"|"assignee"|"type"|"customfield_XXXXX"
    group_custom_fields = {},            -- { { id = "customfield_XXXXX", name = "Custom" }, ... }
    picker_fields = { "key", "summary", "status", "assignee", "priority", "fixVersions" }, -- columns
    preview_fields = { "description", "fixVersions" }, -- preview sections
    show_group_headers = true,           -- show headers for groups
    sort_by = "updated",                 -- sort field in picker
  },

  terminal = {
    float_opts = { border = "rounded", title_pos = "center" }, -- passed to ToggleTerm
  },

  filters = {
    assignee = nil,                      -- "me" or Jira username
    day_interval = nil,                  -- integer; limits search by updated date
    default_jql_id = nil,                -- number from YAML; set -1 to auto-select by current repo name
    max_results = 100,                   -- -1 all results; >100 triggers pagination
    project = nil,                       -- project key/id hard filter
    status = nil,                        -- { "In Progress", "Done" } etc.
  },
}
```

#### Notes

- `load_on_found_jql_id = true`: plugin activates only if the **current Git repository name** equals a **JQL label** from `pre_defined_jql_expressions`.
- `filters.default_jql_id = -1`: auto-resolve JQL id by matching the current repo name to a YAML label.
- `fixVersions` is treated as a list everywhere; the list view shows the first value.

---

## Usage

### Commands

- `:JiraTasks` — open the Telescope picker.
- `:JiraTasksRefresh` — refresh the issues cache in the background.

> If `load_on_found_jql_id = true` and no matching JQL label for the current Git repo is found, the plugin is disabled and these commands are not created. Set `disable_startup_notification = true` to suppress the notice.

### Default keymaps (if `keymaps = true`)

- Normal mode:
  - `<leader>jj` — `:JiraTasks`
  - `<leader>jr` — `:JiraTasksRefresh`
  - `<leader>jt` — open external `jiratui` TUI for the configured `project` and `default_jql_id`

- Inside the picker:
  - `<CR>` — open external `jiratui` TUI for the selected issue
  - `<C-o>` — open issue in browser
  - `<C-r>` — refresh issues
  - `<C-i>` / `<C-p>` — toggle preview
  - `?` — help overlay
  - `<C-g>` / `<C-S-g>` — cycle grouping forward/backward
  - `<C-f>` — open value-filter menu for the **current group**
  - `<C-b>` — create/switch Git branch from selected issue

### Grouping and value filters

- `telescope.group_by`: `none`, `status`, `assignee`, `type`, or any `customfield_XXXXX`.
- When grouping by a multi-value custom field, an issue appears under each value.
- `<C-f>` opens a checkbox menu of values for the current group. Selections stack across groups and persist for the current Neovim session.

### External `jiratui` TUI

- Picker `<CR>` or normal-mode `<leader>jt` runs:

  ```
  jiratui ui [-w <KEY>] [-p <project>] [-j <jql_id>]
  ```

- From Lua:

```lua
  require("jiratui.terminal").open_jiratui(key, project, jql_id)
```

### Auto-select JQL by repo

- If `filters.default_jql_id = -1`, the plugin matches the **current Git repo name** to a **label** in `pre_defined_jql_expressions` and uses that id.
- If `load_on_found_jql_id = true` and no label matches, the plugin stays disabled.

---

## Git integration

- Enabled by default. See `git` block in defaults.
- Templates:
  - `{key}` → issue key (e.g. `PROJ-123`)
  - `{slug}` → URL‑safe, lowercase summary (e.g. `fix-login-timeout`)
  - `{summary}` → full summary text

### Defaults

```lua
git = {
  branch_template = "{key}-{slug}",
  commit_template = "{key} {summary}",
  enabled = true,
  remote = "origin",
}
```

### Lua API

```lua
local git = require("jiratui.git")

-- Strings
local branch = git.get_branch_name(issue)
local commit = git.get_commit_message(issue)

-- Actions: return ok, err
local ok1, err1 = git.create_branch(issue)
local ok2, err2 = git.switch_branch(issue)
local ok3, err3 = git.create_or_switch_branch(issue)
```

From the picker: `<C-b>` creates/switches a branch using the current issue.

## Healthcheck

```
:checkhealth jiratui
```

Validates:

- Neovim version
- `curl`, `yq` binaries
- Optional `telescope.nvim`, `toggleterm.nvim`
- Presence and parseability of the jiratui CLI YAML
- `filters.default_jql_id` existence in YAML (if set)
- Cache path writability

## Troubleshooting

- **Plugin disabled at startup**
  - Cause: `load_on_found_jql_id = true` and no YAML label matches the current Git repo name.
  - Fix: Disable the option or add a matching label in `pre_defined_jql_expressions`.
  - Suppress notice: set `disable_startup_notification = true`.

- **`default_jql_id` not found**
  - Cause: `filters.default_jql_id` does not exist in YAML `pre_defined_jql_expressions`.
  - Fix: Define the id in YAML or set `filters.default_jql_id = -1` to auto‑select by repo name.

- **Auto‑select JQL failed**
  - Cause: `filters.default_jql_id = -1` but no YAML label equals the repo name.
  - Fix: Add a label equal to the repo directory name or set a concrete id.

- **No results / too many results**
  - Adjust `filters.project`, `filters.assignee`, `filters.status`, or `filters.day_interval`.
  - `filters.max_results = -1` or `> 100` enables pagination to fetch all.

- **YAML not found or missing keys**
  - Ensure the jiratui CLI YAML exists and has `jira_api_base_url`, `jira_api_username`, `jira_api_token`.

- **Picker columns empty for custom fields**
  - Put the field id in `telescope.picker_fields` and/or `telescope.preview_fields`.
  - For readable headers, add to `telescope.group_custom_fields`.

- **UI echo error**
  - Wrap custom notifications in `vim.schedule(function() ... end)`.

## Roadmap

- Persist value filters to disk
- Inline transitions and assignments
- PR creation and remote tracking helpers
- Richer preview rendering
- Retry and error surfacing
- Tests and CI

## Contributing

1. Fork and clone
2. Create a focused feature branch
3. Keep changes small and documented
4. Open a PR

## License

MIT. See `LICENSE`.

## Credits

- Core CLI: `whyisdifficult/jiratui` (configuration and external TUI)
- Neovim ecosystem: Telescope and ToggleTerm
