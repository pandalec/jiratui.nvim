# jiratui.nvim

Telescope-powered Jira picker for Neovim — list, preview, group, and open issues right from your editor.  
Includes optional Git helpers to create/switch branches and craft commit messages from issues.

> ⚠️ **Status**: pre-alpha — I’m actively testing this. APIs and defaults may change.

> 🙌 **Credits**: This plugin is built **on top of** the excellent CLI tool **[whyisdifficult/jiratui](https://github.com/whyisdifficult/jiratui)** and **reuses its configuration**. You must have `jiratui` configured for authentication and predefined JQL.

---

## Features

- **Telescope picker** for Jira issues
  - Configurable **columns** (`picker_fields`) and **preview** (`preview_fields`)
  - Group by **status**, **assignee**, **issue type**, or any **customfield_XXXXX**
  - Optional group **headers**
  - **Per-group value filters** (checkbox UI) that stack (e.g. filter by Status _and_ Components)
  - Open in browser, open the external `jiratui` TUI, refresh, toggle preview

- **Flexible JQL via `jiratui` config**
  - Pick a default JQL by id (`filters.default_jql_id`) from your **jiratui** YAML
  - Merge extra runtime filters (project / assignee / status) while keeping `ORDER BY`
  - Page through results automatically when `max_results == -1` or `> 100`

- **Readable preview**
  - Converts Jira ADF descriptions to plain text
  - Shows FixVersions and any configured custom fields by **friendly name**

- **Caching & background refresh**
  - Cache results on disk with TTL, refresh in background, optional load on startup

- **Optional Git integration**
  - Create/switch branch from an issue (local or remote)
  - Generate commit message from templates
  - Fully configurable and can be disabled

- **Health checks**
  - `:checkhealth jiratui` validates tools & config

---

## Requirements

- **Neovim** ≥ 0.10, tested only with 0.12-dev
- **curl** (HTTP)
- **yq** (reads the YAML used by `jiratui`)
- **telescope.nvim**
- **toggleterm.nvim** (recommended; used to open the external `jiratui` TUI)
- **jiratui** CLI configured (this plugin reads its config)

> This plugin does **not** define its own Jira credentials file; it **reuses** the one from the `jiratui` tool.

---

## Installation

Using **lazy.nvim**:

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

This plugin reads the **same YAML** that `jiratui` uses. Search order:

1. `$JIRA_TUI_CONFIG_FILE`
2. `$XDG_CONFIG_HOME/jiratui/config.yaml`
3. `$HOME/.config/jiratui/config.yaml`

Example (refer to `jiratui`'s README for details):

```yaml
jira_api_base_url: "https://your-company.atlassian.net"
jira_api_username: "you@example.com"
jira_api_token: "atlassian-api-token"

pre_defined_jql_expressions:
  "10":
    label: "My Open Issues"
    expression: "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
  "20":
    label: "Team In Progress"
    expression: 'project = "PROJ" AND status in ("In Progress") ORDER BY updated DESC'
```

Set `default_jql_id` in your `setup()` to one of these ids (string or number).  
At runtime you can add filters like `project`, `assignee`, or a list of `status` values; these get merged into the JQL while preserving `ORDER BY`.

### Plugin `setup()` options (summary)

```lua
-- Defaults:
{
  filters = {
    project = nil,          -- optional hard filter
    assignee = nil,         -- "me" or a Jira username
    status = nil,           -- { "In Progress", "Done" }
    default_jql_id = 10,    -- from jiratui YAML
    max_results = 200,      -- -1 = fetch all
  },
  terminal = {
    float_opts = FloatingTerminalOpts,  -- passed to toggleterm
  },
  debug = false,
  cache = {
    enabled = true,
    ttl_minutes = 10,
    background_refresh = true,
  },
  keymaps = true,
  load_on_startup = true,
  telescope = {
    picker_fields = { "key", "summary", "status", "assignee", "fixVersions" },
    preview_fields = { "description", "fixVersions" },
    sort_by = "updated",
    group_by = "none", -- or "status" | "assignee" | "type" | "customfield_XXXXX"
    group_custom_fields = {
      -- { id = "customfield_XXXXX", name = "Components" },
    },
    show_group_headers = true,
  },
  git = {
    enabled = true,
    remote = "origin",
    branch_template = "{key}-{slug}",
    commit_template = "{key} {summary}",
  },
}
```

#### Template variables

- `{key}` → Jira issue key (`PROJ-123`)
- `{slug}` → URL-safe, lowercase summary (`fix-login-timeout-under-timeout`)
- `{summary}` → Full summary (`Fix login timeout under load`)

Examples:

- Branch: `feature/{key}-{slug}` → `feature/PROJ-123-fix-login-timeout-under-timeout`
- Commit: `{key}: {summary}` → `PROJ-123: Fix login timeout under load`

---

## Usage

### Telescope picker

Open the picker and browse:

- **Columns** (`picker_fields`): `key`, `summary`, `status`, `type`, `assignee`, `priority`, `fixVersions`, and any `customfield_XXXXX`.
- **Preview** (`preview_fields`): `description`, `fixVersions`, any standard field above, and any `customfield_XXXXX`.
- For `fixVersions`, the list is always a table; the list view shows the first (or `first, ...`).

**Built-in keymaps (inside the picker):**

| Key                 | Action                                                        |
| ------------------- | ------------------------------------------------------------- |
| `<CR>`              | Open the external `jiratui` TUI (`jiratui ui [-w <KEY>] ...`) |
| `<C-o>`             | Open issue in browser                                         |
| `<C-r>`             | Refresh issues                                                |
| `<C-i>` / `<Tab>`   | Toggle preview                                                |
| `?`                 | Toggle help overlay                                           |
| `<C-g>` / `<C-S-g>` | Cycle grouping forward/backward                               |
| `<C-f>`             | Open value-filter menu for the **current group**              |
| `<C-b>`             | Create/Switch Git branch from issue (if Git is enabled)       |

**Grouping & value filters**

- `group_by` may be `none`, `status`, `assignee`, `type`, or any `customfield_XXXXX`.
- Press `<C-f>` to open a **checkbox** menu for the current group (e.g. all Status values).  
  Toggle values with **Space/Tab**, press **Enter** to apply.  
  Filters **stack** across multiple groups (e.g. filter by Status and by Components).

> Filters live in memory for the session; persistence across sessions is planned.

---

## Git integration

All logic is in `require("jiratui.git")` and respects `git.enabled`.

From Lua:

```lua
local git = require("jiratui.git")

-- Build strings
git.get_branch_name(issue)        -- => "proj-123-fix-login-timeout" (based on your template)
git.get_commit_message(issue)     -- => "PROJ-123 Fix login timeout under load"

-- Branch operations (returns ok, err)
git.create_branch(issue)              -- create new branch
git.switch_branch(issue)              -- checkout local/remote branch if it exists
git.create_or_switch_branch(issue)    -- do-the-right-thing helper
```

From the **Telescope picker**, press **`<C-b>`** on an issue to create/switch the branch for that issue using your templates.

---

## External `jiratui` TUI

Press `<CR>` on an issue to open the external TUI:

```
jiratui ui [-w <KEY>] [-p <project>] [-j <jql_id>]
```

The plugin launches this in a ToggleTerm floating terminal
via `open_jiratui(key, project, jql_id)`.

---

## Healthcheck

```
:checkhealth jiratui
```

Validates:

- Neovim version
- `yq`, `curl` binaries
- Optional `telescope.nvim`, `toggleterm.nvim`
- Presence and parseability of the **jiratui** YAML config
- Existence of `default_jql_id` in `pre_defined_jql_expressions` (if set)

---

## Troubleshooting

- **`default_jql_id N not found in pre_defined_jql_expressions`**  
  Ensure your **jiratui** YAML defines that id (string or number key) under `pre_defined_jql_expressions`.

- **`E5560: nvim_echo must not be called in a fast event context`**  
  All internal notifications are scheduled. If you add custom `notify` calls, wrap them:

  ```lua
  vim.schedule(function() require("jiratui.util").notify("message") end)
  ```

- **Custom field column empty**  
  Add its id to `telescope.picker_fields` (to list), `telescope.preview_fields` (to preview), and
  give it a friendly name in `telescope.group_custom_fields` so headers/labels are nice.

- **Too many/few issues**  
  `filters.max_results = -1` (or any `> 100`) fetches all pages.  
  Set a lower number to cap results.

---

## Roadmap

- Persist value filters to disk
- More Git actions (PR creation, push, remote tracking setup)
- Inline transitions / assign / comment from Neovim
- Richer preview rendering (markdown tables/code blocks)
- Better error surfacing and retry logic
- Tests

---

## Contributing

PRs and issues welcome! This is my second Neovim plugin and currently pre-alpha — feedback is super helpful.

1. Fork and clone
2. Create a feature branch
3. Keep changes focused and documented
4. Open a PR

---

## License

MIT — see `LICENSE`.

---

## Credits

- **Core CLI**: [whyisdifficult/jiratui](https://github.com/whyisdifficult/jiratui) — this plugin reuses its configuration and launches the TUI.
- Neovim community, Telescope, ToggleTerm ❤️
