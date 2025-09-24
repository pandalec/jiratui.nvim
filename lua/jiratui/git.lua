-- lua/jiratui/git.lua
local M = {}

local notify = require("jiratui.util").notify
local config = require("jiratui.config")
local issues_module = require("jiratui.issues")

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

-- Current branch name
local function current_branch_name()
  local ok, out, err = system_git({ "rev-parse", "--abbrev-ref", "HEAD" })
  if not ok then return nil, (err ~= "" and err or "cannot read current branch") end
  return out, nil
end

local function current_upstream_ref()
  -- returns "origin/main" or nil
  local ok, out = system_git({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  if ok and out ~= "" then return out end
  return nil
end

local function unset_upstream_if_mismatch(branch, remote)
  local up = current_upstream_ref()
  if not up then return end
  local expect = (remote or get_opts().remote) .. "/" .. branch
  if up ~= expect then
    -- remove accidental upstream (e.g. origin/main)
    system_git({ "branch", "--unset-upstream" })
  end
end

-- Extract Jira key like PROJ-123 from branch
function M.extract_issue_key_from_branch(branch_name)
  if type(branch_name) ~= "string" or branch_name == "" then return nil end
  local key = branch_name:match("([A-Z][A-Z0-9]+%-%d+)")
  return key
end

-- Find issue by key in cached issues
local function find_issue_in_cache_by_key(issue_key)
  for _, it in ipairs(issues_module.cached_issues or {}) do
    if it.key == issue_key then return it end
  end
  return nil
end

-- Resolve issue by key using cache/disk, then async refresh if needed
local function resolve_issue_by_key_sync(issue_key, timeout_ms)
  local opts = config.get() or {}
  -- try memory
  local hit = find_issue_in_cache_by_key(issue_key)
  if hit then return hit, nil end
  -- try disk
  issues_module.load_from_disk(opts)
  hit = find_issue_in_cache_by_key(issue_key)
  if hit then return hit, nil end
  -- refresh from REST and wait
  local done = false
  issues_module.refresh_issues_async(opts, function() done = true end)
  vim.wait(timeout_ms or 30000, function() return done end, 50)
  hit = find_issue_in_cache_by_key(issue_key)
  if hit then return hit, nil end
  return nil, "issue " .. issue_key .. " not found in cache"
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
  -- Use --exit-code so a missing branch yields a non-zero exit
  local ok = system_git({ "ls-remote", "--exit-code", "--heads", remote, branch })
  return ok
end

local function git_fetch(remote) system_git({ "fetch", "--prune", remote }) end

local function remote_default_head(remote)
  -- returns e.g. "origin/main" or nil
  local ok, out = system_git({ "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" })
  if ok and out ~= "" then return out end
  return nil
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
  local remote = get_opts().remote
  -- Try to avoid auto-tracking remote base (origin/main) which confuses pushes.
  if base and base ~= "" then
    local created = false

    -- If base looks like a remote ref (e.g. origin/main), first try --no-track.
    if base:match("^[%w._-]+/.+") then
      created = system_git({ "switch", "-c", branch, "--no-track", base })
      if not created then created = system_git({ "checkout", "-b", branch, "--no-track", base }) end
    end

    -- Fallback without --no-track
    if not created then
      created = system_git({ "switch", "-c", branch, base })
      if not created then
        local ok2, out2, err2 = system_git({ "checkout", "-b", branch, base })
        if not ok2 then return ok2, out2, err2 end
        created = ok2
      end
    end

    if created then
      unset_upstream_if_mismatch(branch, remote)
      return true
    end
    -- should not reach here, but keep a safe fallback error
    return false, "", "failed to create branch"
  else
    local ok = system_git({ "switch", "-c", branch })
    if not ok then
      local ok2, out2, err2 = system_git({ "checkout", "-b", branch })
      if not ok2 then return ok2, out2, err2 end
      ok = ok2
    end
    if ok then
      unset_upstream_if_mismatch(branch, remote)
      return true
    end
    return false, "", "failed to create branch"
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
--   base: base ref for creation (default: remote HEAD or current HEAD)
function M.switch_to_issue_branch(issue, opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local o = get_opts()
  local remote = opts.remote or o.remote
  local name = M.compute_branch_name(issue, opts.template)

  if M.branch_exists_local(name) then
    local ok, _, err = git_switch(name)
    if not ok then return nil, "failed to switch to branch: " .. (err or "") end
    return name, nil
  end

  -- refresh remotes before checking
  git_fetch(remote)

  if M.branch_exists_remote(name, remote) then
    local ok, _, err = git_switch_track(name, remote)
    if not ok then return nil, "failed to create tracking branch: " .. (err or "") end
    return name, nil
  end

  if opts.create_if_missing ~= false then
    local base = opts.base
    if not base or base == "" then base = remote_default_head(remote) end
    local ok, _, err = git_create_branch(name, base)
    if not ok then return nil, "failed to create branch: " .. (err or "") end
    return name, nil
  end

  return nil, "branch not found locally or on " .. remote
end

-- Create a new branch (without switching) based on issue
-- opts: template, base, remote
function M.create_issue_branch(issue, opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local o = get_opts()
  local remote = opts.remote or o.remote
  local name = M.compute_branch_name(issue, opts.template)
  if M.branch_exists_local(name) then return name, nil end
  local base = opts.base
  if not base or base == "" then base = remote_default_head(remote) end
  local ok, _, err = git_create_branch(name, base)
  if not ok then return nil, "failed to create branch: " .. (err or "") end
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

-- Build commit message from current branch using cached issues/rest pipeline
function M.get_commit_message_from_branch(opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local br, e1 = current_branch_name()
  if not br then return nil, e1 end
  local key = M.extract_issue_key_from_branch(br)
  if not key then return nil, "no Jira key in branch: " .. br end
  local issue, e2 = resolve_issue_by_key_sync(key, opts.timeout_ms or 30000)
  if not issue then return nil, e2 end
  local msg = M.compute_commit_message({ key = key, summary = issue.summary or "" }, opts.template)
  return msg, nil
end

-- Create a commit using the computed message
function M.commit_from_branch(opts)
  opts = opts or {}
  if not M.is_enabled() then return nil, "git disabled or not available" end
  local msg, err = M.get_commit_message_from_branch(opts)
  if not msg then return nil, err end
  local args = { "commit", "-m", msg }
  if opts.body and opts.body ~= "" then
    table.insert(args, "-m")
    table.insert(args, opts.body)
  end
  local ok, out, e = system_git(args)
  if not ok then return nil, e ~= "" and e or out end
  notify("Committed with message: " .. msg)
  return out, nil
end

-- Helper for headless usage (e.g. from lazygit)
function M.print_commit_message_from_branch()
  local msg, err = M.get_commit_message_from_branch({})
  if not msg then
    io.stderr:write((err or "unknown error") .. "\n")
    return
  end
  io.stdout:write(msg .. "\n")
end

return M
