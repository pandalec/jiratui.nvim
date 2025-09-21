-- lua/jiratui/git.lua
local M = {}

local notify = require("jiratui.util").notify
local config = require("jiratui.config")

local function get_opts()
  local opts = config.get() or {}
  opts.git = opts.git or {}
  return {
    enabled = not opts.disable_git_functionality,
    remote = opts.git.remote or "origin",
    branch_template = opts.git.branch_template or "{key}-{slug}",
    commit_template = opts.git.commit_template or "{key} {summary}",
  }
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function system_git(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
  local code = tonumber(res.code or 0) or 0
  local out = trim(res.stdout or "")
  local err = trim(res.stderr or "")
  return code == 0, out, err, code
end

local function git_available() return vim.fn.executable("git") == 1 end

-- slug is used for branch segments
function M.slugify(text)
  text = (text or ""):lower()
  -- common german diacritics
  text = text:gsub("ä", "ae"):gsub("ö", "oe"):gsub("ü", "ue"):gsub("ß", "ss")
  -- spaces/tabs -> hyphen
  text = text:gsub("[%s_]+", "-")
  -- drop anything not safe for branch names
  text = text:gsub("[^a-z0-9%-%.]", "")
  -- collapse multiple hyphens and dots
  text = text:gsub("%-+", "-"):gsub("%.+", ".")
  -- trim leading/trailing separators
  text = text:gsub("^[-%.]+", ""):gsub("[-%.]+$", "")
  -- keep it reasonably short
  if #text > 80 then text = text:sub(1, 80) end
  return (text == "" and "wip") or text
end

local function apply_template(tmpl, issue)
  local map = {
    key = issue.key or "",
    lowerkey = (issue.key or ""):lower(),
    upperkey = (issue.key or ""):upper(),
    summary = issue.summary or "",
    slug = M.slugify(issue.summary or ""),
    type = issue.type or "",
    status = issue.status or "",
    assignee = issue.assignee or "",
    project = issue.project or "",
  }
  -- allow {custom:customfield_12345}
  local function replace_custom(token)
    local id = token:match("^custom:(customfield_%d+)$")
    if not id then return nil end
    local cf = issue.custom_fields or {}
    local val = cf[id]
    if type(val) == "table" then
      if #val == 0 then return "" end
      return tostring(val[1])
    end
    return tostring(val or "")
  end

  local out = tmpl:gsub("{([^}]+)}", function(name)
    local special = replace_custom(name)
    if special ~= nil then return special end
    return map[name] or ("{" .. name .. "}")
  end)
  -- collapse accidental doubles (e.g. ticket//KEY--)
  out = out:gsub("[/]+", "/"):gsub("%-+", "-"):gsub("^[/%-]+", ""):gsub("[/%-]+$", "")
  return out
end

function M.branch_exists_local(branch)
  local ok = system_git({ "show-ref", "--verify", "--quiet", "refs/heads/" .. branch })
  return ok
end

function M.branch_exists_remote(branch, remote)
  remote = remote or get_opts().remote
  local ok = system_git({ "ls-remote", "--heads", remote, branch })
  return ok
end

local function git_switch(branch)
  -- Prefer `git switch` (git >=2.23); fallback to checkout
  local ok = system_git({ "switch", branch })
  if ok then return true end
  return system_git({ "checkout", branch })
end

local function git_switch_track(branch, remote)
  remote = remote or get_opts().remote
  -- Create local tracking branch from remote
  local ok = system_git({ "switch", "-c", branch, "--track", ("%s/%s"):format(remote, branch) })
  if ok then return true end
  return system_git({ "checkout", "-t", ("%s/%s"):format(remote, branch) })
end

local function git_create_branch(branch, base)
  if base and base ~= "" then
    local ok = system_git({ "switch", "-c", branch, base })
    if ok then return true end
    return system_git({ "checkout", "-b", branch, base })
  else
    local ok = system_git({ "switch", "-c", branch })
    if ok then return true end
    return system_git({ "checkout", "-b", branch })
  end
end

function M.is_enabled()
  local o = get_opts()
  return o.enabled and git_available()
end

function M.supported_placeholders()
  return {
    "key",
    "lowerkey",
    "upperkey",
    "summary",
    "slug",
    "type",
    "status",
    "assignee",
    "project",
    "custom:customfield_XXXX",
  }
end

function M.compute_branch_name(issue, template)
  local o = get_opts()
  return apply_template(template or o.branch_template, issue or {})
end

function M.compute_commit_message(issue, template)
  local o = get_opts()
  return apply_template(template or o.commit_template, issue or {})
end

-- Switch to a branch based on issue.
-- opts:
--   template: override branch template
--   remote: override remote name
--   create_if_missing: boolean (default: true)
--   base: base ref for creation (default: current HEAD)
function M.switch_to_issue_branch(issue, opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local o = get_opts()
  local remote = opts.remote or o.remote
  local name = M.compute_branch_name(issue, opts.template)

  if M.branch_exists_local(name) then
    local ok, _, err = git_switch(name)
    if not ok then return nil, "failed to switch to branch: " .. err end
    return name, nil
  end

  if M.branch_exists_remote(name, remote) then
    local ok, _, err = git_switch_track(name, remote)
    if not ok then return nil, "failed to create tracking branch: " .. err end
    return name, nil
  end

  if opts.create_if_missing ~= false then
    local ok, _, err = git_create_branch(name, opts.base)
    if not ok then return nil, "failed to create branch: " .. err end
    return name, nil
  end

  return nil, "branch not found locally or on " .. remote
end

-- Create a new branch (without switching) based on issue
-- opts: template, base
function M.create_issue_branch(issue, opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local name = M.compute_branch_name(issue, opts.template)
  if M.branch_exists_local(name) then return name, nil end
  local ok, _, err = git_create_branch(name, opts.base)
  if not ok then return nil, "failed to create branch: " .. err end
  return name, nil
end

-- Return the commit message string (does not run git)
function M.make_commit_message(issue, template) return M.compute_commit_message(issue, template) end

-- Run `git commit` with message derived from issue.
-- opts:
--   template: override commit template
--   body: optional body text (second -m)
function M.commit_with_issue_message(issue, opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local subject = M.compute_commit_message(issue, opts.template)
  local args = { "commit", "-m", subject }
  if opts.body and opts.body ~= "" then
    table.insert(args, "-m")
    table.insert(args, opts.body)
  end
  local ok, out, err = system_git(args)
  if not ok then return nil, err ~= "" and err or out end
  return out, nil
end

-- Convenience: ensure branch exists and switch to it
function M.ensure_and_switch(issue, opts)
  opts = opts or {}
  local name, err = M.switch_to_issue_branch(
    issue,
    { create_if_missing = true, template = opts.template, remote = opts.remote, base = opts.base }
  )
  if not name then return nil, err end
  notify("Switched to " .. name)
  return name, nil
end

return M
