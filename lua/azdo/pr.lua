--- The main "app" code. Displays PRs / work-items / repo-status for Azure DevOps.

local comments = require('azdo.comments')
local az = require('azdo.az')
local state = require('azdo.state')
local util = require('azdo.util')

local M = {}

--- Resolves the current local repo "org/project/repo", blocking up to 5s.
--- @return string?
local function resolve_local_repo()
  local repo
  az.get_repo(function(r)
    repo = r
  end)
  vim.wait(5000, function()
    return not not repo
  end)
  return repo
end

--- @param repo string "org/project/repo"
--- @return string org, string project, string name
local function split_repo(repo)
  return repo:match('^([^/]+)/([^/]+)/(.+)$')
end

--- Finds the first `pr/…` buffer matching the given commit `sha`.
---
--- @param sha string
--- @return integer? pr_id
--- @return integer? commit_idx 1-based index of the matching commit in `pr_data.commits`.
local function find_pr_for_commit_sha(sha)
  for _, pr_buf in pairs(state.bufs.pr or {}) do
    local pr_data = vim.fn.getbufvar(pr_buf, 'azdo', {}).pr_data
    for i, c in ipairs(pr_data and pr_data.commits or {}) do
      if c.oid == sha then
        return pr_data.number, i
      end
    end
  end
end

--- Resolves `(pr_id, repo, commit_idx)` from an :Azdo arg, falling back to `b:azdo` and `resolve_local_repo()`.
---
--- @param opts integer|string|table|nil Table form may be cmdline "args", or explicit `{id=…,repo=…}`.
--- @return Feat? feat `b:azdo.feat`, or nil if `opts` provided an explicit id.
--- @return integer id
--- @return string repo
--- @return integer? commit_idx
local function resolve_pr(opts)
  local b_azdo = vim.b.azdo
  local opts_t = type(opts) == 'table' and opts or {}
  local id = opts_t.id or (opts_t.args and tonumber(opts_t.args)) or tonumber(opts)
  if not id and not b_azdo then
    error('azdo: Not in an azdo:// buffer', 0)
  end

  local commit_idx
  if not id then
    if b_azdo.feat == 'commit' then
      id, commit_idx = find_pr_for_commit_sha(b_azdo.id)
    else
      id = vim._tointeger(b_azdo.id)
    end
  end
  if not id then
    error('azdo: Failed to resolve PR id', 0)
  end

  local repo = opts_t.repo or (b_azdo or {}).repo or resolve_local_repo()
  if not repo then
    error('azdo: Failed to resolve repo', 0)
  end
  return b_azdo and b_azdo.feat or nil, id, repo, commit_idx
end

--- Implements `:Azdo`.
function M.select(opts)
  if not az.get_user() then
    util.msg('Not logged in to Azure CLI. Run: "az login"', vim.log.levels.ERROR)
    return
  end

  local arg = (opts or {}).args or ''

  -- Flash the cWORD if it matches the arg (so `:Azdo <cWORD>` works without a wrapper).
  if arg == vim.fn.expand('<cWORD>') then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local on_blank = vim.api.nvim_get_current_line():sub(col + 1, col + 1):match('%S') == nil
    local _, c = unpack(vim.fn.searchpos([[\v(^|\s)@<=\S]], on_blank and 'cnW' or 'bcnW'))
    util.hl_flash(0, { row - 1, c - 1 }, { row - 1, c - 1 + #arg })
  end

  -- Support command mods (`:vertical Azdo …`). See `:help <mods>`.
  local smods = (opts or {}).smods or {}
  local window_mod = (smods.split or '') ~= '' or smods.vertical or smods.horizontal or (smods.tab or -1) >= 0
  local focus = not window_mod

  local target, repo
  if #arg > 0 then
    target = util.parse_target(arg)
    if not target then
      util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
      return
    end
    repo = target.repo or (vim.b.azdo or {}).repo or resolve_local_repo()
    if not repo then
      util.msg('Failed to get repo info', vim.log.levels.ERROR)
      return
    end
  end

  local function dispatch(is_pr)
    if window_mod then
      vim.cmd(((opts or {}).mods or '') .. ' new')
    end
    if not target then
      M.show_status(focus)
    elseif target.sha then
      M.show_commit(target.sha, repo, focus)
    elseif not target.id then
      M.show_status(focus, repo)
    elseif target.is_pr == true or (target.is_pr == nil and is_pr) then
      M.show_pr(target.id, repo, focus)
    else
      M.show_issue(target.id, repo, focus)
    end
  end

  if target and target.id and target.is_pr == nil and not target.sha then
    -- Probe PR-vs-work-item. Async so the hl_flash() highlight works.
    az.probe_is_pr(repo, target.id, function(is_pr)
      vim.schedule(function()
        dispatch(is_pr)
      end)
    end)
  else
    dispatch(nil)
  end
end

--- Gets commit `sha` (via local `git show`) and displays it as a `gitcommit` buffer.
---
--- @param sha string Commit SHA.
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_commit(sha, repo, focus)
  local done = util.progress(('Loading commit %s...'):format(sha))
  az.get_commit(repo, sha, function(patch, err)
    if not patch then
      done('failed')
      return util.msg(('Failed to load commit %s: %s'):format(sha, err or ''), vim.log.levels.ERROR)
    end
    local full_sha = patch:match('^commit%s+(%x+)') or sha
    local buf = state.init_buf('commit', focus, repo, full_sha, { id = full_sha })
    local lines = vim.split(patch, '\n', { plain = true, trimempty = true })
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    util.set_default_keymaps(buf)
    done('success')
  end)
end

--- Navigates to the next/previous PR commit.
--- @param delta integer +1 for next, -1 for previous.
function M.show_next_commit(delta)
  local _, id, repo, commit_idx = resolve_pr()
  local pr_buf = assert(state.get_buf('pr', repo, id, false))
  local pr_data = vim.fn.getbufvar(pr_buf, 'azdo', {}).pr_data
  local commits = pr_data and pr_data.commits
  if not commits or #commits == 0 then
    error('azdo: No commits found; try refresh (R)', 0)
  end
  local idx = commit_idx or (delta > 0 and 0) or (#commits + 1)
  local next_idx = idx + delta
  if next_idx < 1 or next_idx > #commits then
    return util.msg(('No %s commit'):format(delta > 0 and 'next' or 'previous'))
  end
  M.show_commit(commits[next_idx].oid, repo, true)
end

--- Performs the "review PR" action (sets the signed-in user's vote).
function M.review_pr()
  local _, id, repo = resolve_pr()

  local labels = {
    ['approve'] = { gerund = 'Approving', past = 'Approved' },
    ['comment'] = { gerund = 'Commenting on', past = 'Commented on' },
    ['request-changes'] = { gerund = 'Requesting changes on', past = 'Requested changes on' },
  }

  local function do_action(action)
    local L = labels[action]
    local msg = ('%s PR #%s | ZZ to submit (ZQ to abort)'):format(L.gerund, id)
    local content = action == 'approve' and { '👍' } or { '' }
    comments.edit_comment('review', id, content, { { msg, 'Comment' } }, function(input)
      local body = vim.trim(input)
      local done = util.progress(('%s PR #%s…'):format(L.gerund, id))
      az.review_pr(id, repo, action, body, function(ok, stderr)
        done(ok and 'success' or 'failed')
        if ok then
          util.msg(('%s PR #%s'):format(L.past, id))
        else
          util.msg(('Review failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  local actions = { 'approve', 'request-changes', 'comment' }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    return do_action(actions[count])
  end

  vim.ui.select(actions, { prompt = ('Review PR #%s by:'):format(id) }, function(action)
    if action then
      do_action(action)
    end
  end)
end

--- Refreshes the current `azdo://*` buffer by invoking `:Azdo <bufname>`.
function M.refresh()
  local feat = util.require_b_azdo({ 'feat' })
  if not feat then
    return
  end
  if feat == 'status' then
    return M.show_status(true)
  end
  -- Drop cached pr_data on the `/pr/…` buf so `az.get_pr_data` re-fetches.
  local b = vim.b.azdo or {}
  if b.repo and b.id then
    local pr_buf = state.get_buf('pr', b.repo, b.id, false)
    if pr_buf then
      state.set_b_azdo(pr_buf, { pr_data = nil })
    end
  end
  M.select({ args = vim.api.nvim_buf_get_name(0) })
end

--- Performs the "merge PR" (complete) action.
function M.merge_pr()
  local _, id, repo = resolve_pr()

  local function do_merge(choice, subject, body)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    local done = util.progress(('Completing PR #%s (%s)…'):format(id, choice))
    az.merge_pr(id, repo, method, subject, body, admin, function(ok, stderr)
      done(ok and 'success' or 'failed')
      if ok then
        util.msg(('Completed PR #%s'):format(id))
      else
        util.msg(('Complete failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
      end
    end)
  end

  local function with_choice(choice)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    if method == 'rebase' then
      return do_merge(choice)
    end
    az.get_pr_data(id, repo, nil, function(pr)
      if not pr then
        return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
      end
      vim.schedule(function()
        local subject, body
        if method == 'merge' then
          subject = ('Merge PR #%s: %s'):format(id, pr.title)
          body = pr.body or ''
        elseif method == 'squash' then
          subject = ('%s (#%s)'):format(pr.title, id)
          local cs = pr.commits or {}
          if #cs == 1 and vim.trim(cs[1].messageHeadline) == vim.trim(pr.title) then
            body = cs[1].messageBody
          else
            local parts = {}
            for _, c in ipairs(cs) do
              local entry = ('* %s'):format(c.messageHeadline)
              if c.messageBody ~= '' then
                entry = entry .. '\n\n' .. c.messageBody
              end
              table.insert(parts, entry)
            end
            body = table.concat(parts, '\n\n')
          end
        else
          error(('unknown method: %s'):format(method))
        end
        local text = ('%s\n\n%s'):format(subject, body):gsub('\r', '')
        local content = vim.split(text, '\n', { plain = true })
        local heading = {
          { ('[%s]'):format(choice), admin and 'ErrorMsg' or 'Comment' },
          { ' | First line = subject; rest = body | ZZ to complete (ZQ to abort)', 'Comment' },
        }
        comments.edit_comment('merge', id, content, heading, function(input)
          local subj, b = input:match('^([^\n]*)\n?(.*)$')
          do_merge(choice, subj, vim.trim(b or ''))
        end)
      end)
    end)
  end

  local choices = { 'squash', 'merge', 'rebase', 'squash --admin', 'merge --admin', 'rebase --admin' }
  local count = vim.v.count
  if count >= 1 and count <= #choices then
    return with_choice(choices[count])
  end

  vim.ui.select(choices, { prompt = ('Complete PR #%s by:'):format(id) }, function(choice)
    if choice then
      with_choice(choice)
    end
  end)
end

--- @param focus boolean
--- @param repo? string "org/project/repo"
function M.show_status(focus, repo)
  repo = repo or (vim.b.azdo or {}).repo or resolve_local_repo()
  local buf = state.init_buf('status', focus, nil, 'all', { repo = repo })
  util.set_default_keymaps(buf)
  if not repo then
    util.buf_set_readonly_lines(buf, { 'azdo: could not resolve repo (not an Azure DevOps clone?)' }, 'markdown')
    return
  end
  local done = util.progress('Loading status...')
  az.list_prs(repo, function(prs, err)
    if not prs then
      done('failed')
      util.buf_set_readonly_lines(buf, { ('azdo: failed to list PRs: %s'):format(err or '') }, 'markdown')
      return
    end
    local lines = { ('# %s'):format(repo), '', ('Open PRs (active): %d'):format(#prs), '' }
    for _, p in ipairs(prs) do
      table.insert(lines, ('  #%d  %s%s'):format(p.number, p.isDraft and '(draft) ' or '', p.title))
    end
    table.insert(lines, '')
    table.insert(lines, '<CR> on a #id to open it | g? for help')
    util.buf_set_readonly_lines(buf, lines, 'markdown')
    done('success')
  end)
end

--- Shows a work-item ("issue") via `az boards work-item show`.
--- @param id integer
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_issue(id, repo, focus)
  local org = split_repo(repo)
  local buf = state.init_buf('issue', focus, repo, id)
  local cmd = {
    'az',
    'boards',
    'work-item',
    'show',
    '--id',
    tostring(id),
    '--output',
    'yaml',
    '--organization',
    ('https://dev.azure.com/%s'):format(org),
  }
  util.run_term_cmd(buf, cmd, function()
    util.set_default_keymaps(buf)
  end)
end

--- Renders the PR overview (metadata + description + commits + general discussion) as buffer lines.
--- @param pr PullRequest
--- @return string[]
local function render_overview(pr)
  local function vote_str(v)
    return (v == 10 and '✓approved')
      or (v == 5 and '✓w/suggestions')
      or (v == -5 and '⏳waiting')
      or (v == -10 and '✗rejected')
      or 'no vote'
  end
  local L = {}
  table.insert(L, ('#%s  %s'):format(pr.number, pr.title or ''))
  table.insert(
    L,
    ('%s  [%s]%s  %s → %s'):format(
      (pr.author or {}).login or '?',
      pr.status or '?',
      pr.isDraft and ' (draft)' or '',
      pr.headRefName or '?',
      pr.baseRefName or '?'
    )
  )
  table.insert(L, ('%s · %s'):format(pr.url or '', (pr.createdAt or ''):sub(1, 10)))
  if #(pr.reviews or {}) > 0 then
    local rs = {}
    for _, r in ipairs(pr.reviews) do
      table.insert(rs, ('%s (%s)'):format(r.login or '?', vote_str(r.vote or 0)))
    end
    table.insert(L, 'Reviewers: ' .. table.concat(rs, ', '))
  end
  if #(pr.labels or {}) > 0 then
    local ls = {}
    for _, l in ipairs(pr.labels) do
      table.insert(ls, l.name or l)
    end
    table.insert(L, 'Labels: ' .. table.concat(ls, ', '))
  end
  table.insert(L, '')
  for _, l in ipairs(vim.split(pr.body or '', '\n', { plain = true })) do
    table.insert(L, l)
  end
  table.insert(L, '')
  table.insert(L, ('Commits (%d):'):format(#(pr.commits or {})))
  for _, c in ipairs(pr.commits or {}) do
    table.insert(L, ('  %s  %s  %s'):format((c.oid or ''):sub(1, 12), (c.committedDate or ''):sub(1, 10), c.messageHeadline or ''))
  end
  if #(pr.general or {}) > 0 then
    table.insert(L, '')
    table.insert(L, ('Discussion (%d):'):format(#pr.general))
    for _, c in ipairs(pr.general) do
      table.insert(L, ('  %s  %s'):format(c.user, c.updated_at))
      for _, bl in ipairs(vim.split(c.body or '', '\n', { plain = true })) do
        table.insert(L, '    ' .. bl)
      end
    end
  end
  table.insert(L, '')
  table.insert(L, 'dd diff · cR review · cM complete · cC comment · g? help')
  return L
end

--- Shows PR overview, then loads the diff + comments split.
--- @param id integer
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_pr(id, repo, focus)
  local buf = state.init_buf('pr', focus, repo, id)
  local progress = util.new_progress_report('Loading PR...', buf)
  progress('running')
  az.get_pr_data(id, repo, { force = true }, function(pr)
    if not pr then
      progress('failed')
      return util.buf_set_readonly_lines(buf, { ('azdo: PR #%s not found'):format(id) }, 'markdown')
    end
    util.buf_set_readonly_lines(buf, render_overview(pr), 'markdown')
    util.set_default_keymaps(buf)
    progress('success')
    -- Load the diff + comments split (the pr/ buf becomes prdiff/'s alt-buf).
    vim.schedule(function()
      M.show_pr_diff({ id = id, repo = repo })
    end)
  end)
end

--- Shows PR diff + comments as two 'scrollbind' windows.
function M.show_pr_diff(opts)
  local _, id, repo = resolve_pr(opts)
  local buf = state.init_buf('prdiff', true, repo, id)
  local diff_win = vim.api.nvim_get_current_win()

  local progress = util.new_progress_report('Loading PR diff...', buf)
  progress('running')

  local pr_data --[[@type PullRequest?]]
  local diff_stdout
  local function try_render()
    if not pr_data or not diff_stdout then
      return
    end
    local lines, threads, n_files, n_viewed_threads = comments.render_diff(pr_data, diff_stdout)
    util.log(('comment threads (total: %s)'):format(vim.tbl_count(threads)), threads)
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([[syntax match AzdoWarning /^(viewed)/ containedin=ALL]])
      vim.cmd([[syntax match AzdoWarning /\<\(outdated\|outside\)\ze-\d\+:/ containedin=ALL]])
    end)
    util.set_default_keymaps(buf)
    comments.show_pr_comments(
      id,
      repo,
      diff_win,
      threads,
      pr_data.viewed,
      n_files,
      pr_data.n_threads,
      pr_data.n_resolved,
      n_viewed_threads
    )
    progress('success')
  end

  -- 1. Fetch PR data (cache-friendly; show_pr/refresh prime or clear the cache).
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return progress('failed')
    end
    pr_data = pr
    -- 2. Get the unified diff (local git).
    az.get_pr_diff(repo, pr, function(stdout, err)
      if not stdout then
        progress('failed', nil, err or '')
        diff_stdout = ('# Could not produce diff: %s\n'):format(err or '')
      else
        diff_stdout = stdout
      end
      try_render()
    end)
    try_render()
  end)
end

--- Posts a top-level comment on the current PR or work-item.
local function comment_overview()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'

  comments.edit_comment('comment', id, { '' }, nil, function(input)
    local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
    az.new_overview_comment(kind, id, repo, input, function(ok, stderr)
      if ok then
        progress('success', nil, 'Comment sent.')
      else
        progress('failed', nil, ('Failed to send comment: %s'):format(vim.trim(stderr or '')))
      end
    end)
  end)
end

--- Implements `:AzdoComment`.
--- @param args vim.api.keyset.create_user_command.command_args
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang then
    if (args.range or 0) == 0 then
      return util.msg('AzdoComment!: [range] is required', vim.log.levels.ERROR)
    end
    if args.line1 ~= args.line2 then
      return util.msg('AzdoComment!: [range] must be a single line', vim.log.levels.ERROR)
    end
    return comments.delete_comment(args.line1)
  end
  if (args.range or 0) > 0 and args.line1 == 1 and args.line2 == vim.fn.line('$') then
    return comment_overview()
  end
  if (vim.b.azdo or {}).feat == 'prcomments' then
    return comments.update_comment(args.line1)
  end
  comments.new_comment(args.line1, args.line2)
end

--- Edits PR properties (title/description) in an editable buffer, or opens a work-item in the browser.
function M.edit_pr()
  local feat, id, repo = resolve_pr()
  if feat == 'issue' then
    local org, project = split_repo(repo)
    local url = ('https://dev.azure.com/%s/%s/_workitems/edit/%s'):format(org, project, id)
    util.msg('Opening work item in browser…')
    return vim.ui.open(url)
  end
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    vim.schedule(function()
      local content = vim.split(('%s\n\n%s'):format(pr.title or '', pr.body or ''):gsub('\r', ''), '\n', { plain = true })
      local heading = { { 'First line = title; rest = description | ZZ to save (ZQ to abort)', 'Comment' } }
      comments.edit_comment('edit', id, content, heading, function(input)
        local title, description = input:match('^([^\n]*)\n?(.*)$')
        local progress = util.new_progress_report('Updating PR...', vim.api.nvim_get_current_buf())
        az.update_pr(id, repo, { title = vim.trim(title or ''), description = vim.trim(description or '') }, function(ok, stderr)
          if ok then
            progress('success', nil, 'PR updated.')
          else
            progress('failed', nil, ('Failed: %s'):format(vim.trim(stderr or '')))
          end
        end)
      end)
    end)
  end)
end

--- Shows a menu of CI (pipeline) logs for the PR.
function M.show_ci_logs(opts)
  local _, id, repo = resolve_pr(opts)
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    az.get_pr_ci_jobs_logs(pr, repo, function(jobs, jobs_err)
      if not jobs then
        return util.msg(('failed to list CI jobs: %s'):format(jobs_err or ''), vim.log.levels.WARN)
      end
      jobs = vim.tbl_filter(function(j)
        return j.conclusion ~= 'skipped'
      end, jobs)
      if #jobs == 0 then
        return util.msg(('No (non-skipped) CI jobs for PR #%s'):format(id), vim.log.levels.WARN)
      end

      vim.ui.select(jobs, {
        prompt = ('CI jobs for PR #%s'):format(id),
        format_item = function(j)
          return ('[%s] %s'):format(j.conclusion or j.status or '?', j.name)
        end,
      }, function(picked)
        if not picked then
          return
        end
        az.get_pr_ci_logs(picked.databaseId, repo, function(logs, err)
          if not logs then
            return util.msg(('failed to get CI log: %s'):format(err or ''), vim.log.levels.ERROR)
          end
          local buf = state.init_buf('logs', true, repo, picked.databaseId, { id = id })
          vim.cmd.buffer(buf)
          local chan = vim.api.nvim_open_term(0, {})
          vim.api.nvim_chan_send(chan, logs)
          vim.cmd.norm([[gg0]])
        end)
      end)
    end)
  end)
end

return M
