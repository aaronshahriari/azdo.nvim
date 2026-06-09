--- Azure DevOps transport + data layer.
---
--- This module is the *only* provider-specific layer of azdo.nvim. It shells out to the Azure CLI
--- (`az rest` for arbitrary REST, plus local `git` for diffs/commits) and marshals the responses into
--- the provider-agnostic `PullRequest`/`Comment` shapes that the rest of the plugin consumes. Keeping
--- the mapping here means `comments.lua`/`state.lua`/`util.lua` never learn that the backend is Azure.
---
--- Auth: relies on `az login`. Every `az rest` call passes `--resource <Azure DevOps GUID>` so the token
--- audience targets dev.azure.com.

local state = require('azdo.state')
local util = require('azdo.util')

require('azdo.types')

local f = string.format

local M = {}

--- Azure DevOps resource id (token audience for `az rest --resource`).
local AZDO_RESOURCE = '499b84ac-1321-427f-aa17-267ca6975798'
--- REST api-version used throughout. 7.1 is GA on Azure DevOps Services.
local API = '7.1'
--- Azure comment ids are per-thread (1..n), not globally unique. We synthesize a globally-unique
--- id as `thread_id * MULT + comment_id` so the agnostic thread-grouping in comments.lua works, and
--- decode it back to (thread_id, comment_id) for the per-thread REST routes.
local COMMENT_MULT = 1000000

local function composite_id(thread_id, comment_id)
  return thread_id * COMMENT_MULT + comment_id
end

--- @return integer thread_id, integer comment_id
local function decode_id(cid)
  return math.floor(cid / COMMENT_MULT), cid % COMMENT_MULT
end

local function parse_or_default(str, default)
  local ok, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if ok then
    return result
  end
  return default
end

--- Percent-encodes a single URL path segment (so org/project/repo names with spaces work).
local function urlencode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return f('%%%02X', c:byte())
  end))
end

--- @param repo string "org/project/repo"
--- @return string? org, string? project, string? name
local function parse_repo(repo)
  return tostring(repo):match('^([^/]+)/([^/]+)/(.+)$')
end

--- Base REST url for a repo's git resource: `.../_apis/git/repositories/<repo>`.
local function repo_base(repo)
  local org, project, name = parse_repo(repo)
  if not org then
    return nil
  end
  return f(
    'https://dev.azure.com/%s/%s/_apis/git/repositories/%s',
    urlencode(org),
    urlencode(project),
    urlencode(name)
  )
end

--- Project-level REST base: `.../<org>/<project>/_apis`.
local function project_base(repo)
  local org, project = parse_repo(repo)
  if not org then
    return nil
  end
  return f('https://dev.azure.com/%s/%s/_apis', urlencode(org), urlencode(project))
end

--- Human-facing web url for a PR.
local function pr_web_url(repo, prnum)
  local org, project, name = parse_repo(repo)
  return f('https://dev.azure.com/%s/%s/_git/%s/pullrequest/%s', org, project, name, prnum)
end

--- Appends `api-version` (and any extra query) to a url.
local function with_api(url, extra)
  local sep = url:find('?', 1, true) and '&' or '?'
  return url .. sep .. 'api-version=' .. API .. (extra and ('&' .. extra) or '')
end

--- Async `az rest`. Calls `cb(decoded|nil, stderr, code)`.
---
--- @param method 'get'|'post'|'patch'|'put'|'delete'
--- @param url string Full request url (including api-version).
--- @param body? table JSON body for write methods.
--- @param cb fun(resp: table?, stderr: string, code: integer)
local function az_rest(method, url, body, cb)
  local cmd = { 'az', 'rest', '--method', method:lower(), '--url', url, '--resource', AZDO_RESOURCE }
  if body ~= nil then
    vim.list_extend(cmd, { '--headers', 'Content-Type=application/json' })
    vim.list_extend(cmd, { '--body', vim.json.encode(body) })
  end
  util.log('az_rest ' .. method, url)
  util.system(cmd, function(stdout, stderr, code)
    if code ~= 0 then
      util.log('az_rest error', { url = url, stderr = stderr })
      return cb(nil, stderr or '', code)
    end
    cb(parse_or_default(stdout, {}), stderr or '', code)
  end)
end

--- Write helper shaped like the rest of the plugin expects: `cb(resp)` where `resp.errors == nil`
--- means success. (comments.lua keys success off `resp.errors == nil`.)
---
--- @param logname string
--- @param method 'post'|'patch'|'put'|'delete'
--- @param url string
--- @param body? table
--- @param cb fun(resp: table)
local function az_write(logname, method, url, body, cb)
  az_rest(method, url, body, function(resp, stderr, code)
    util.log(logname .. ' resp', { code = code, resp = resp })
    if code ~= 0 or resp == nil then
      cb({ errors = { vim.trim(stderr or 'request failed') } })
    else
      cb(resp)
    end
  end)
end

---------------------------------------------------------------------------
-- Repo + user resolution
---------------------------------------------------------------------------

--- Resolves the local repo "org/project/repo" by parsing the `origin` remote url. Supports
--- `https://dev.azure.com/org/project/_git/repo`, the `org@dev.azure.com` and ssh
--- (`git@ssh.dev.azure.com:v3/org/project/repo`) variants, and legacy `org.visualstudio.com`.
---
--- @param cb fun(repo?: string)
function M.get_repo(cb)
  local progress = util.new_progress_report('Resolving repo...', 0)
  progress('running')
  util.system({ 'git', 'remote', 'get-url', 'origin' }, function(stdout, _, code)
    if code ~= 0 then
      progress('failed')
      return cb(nil)
    end
    local repo = M.parse_remote(vim.trim(stdout))
    progress(repo and 'success' or 'failed')
    cb(repo)
  end)
end

--- Parses an Azure DevOps remote url into "org/project/repo". Exposed for tests.
--- @return string? repo
function M.parse_remote(url)
  url = (url or ''):gsub('%.git$', '')
  -- https://dev.azure.com/org/project/_git/repo  (also https://org@dev.azure.com/...)
  local org, project, name = url:match('https?://[^/]*dev%.azure%.com/([^/]+)/([^/]+)/_git/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  -- ssh: git@ssh.dev.azure.com:v3/org/project/repo
  org, project, name = url:match('ssh%.dev%.azure%.com:v3/([^/]+)/([^/]+)/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  -- legacy: https://org.visualstudio.com/project/_git/repo
  org, project, name = url:match('https?://([^%.]+)%.visualstudio%.com/([^/]+)/_git/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  return nil
end

local cached_user, cached_user_id

--- Loads the signed-in Azure DevOps profile (displayName + id) via the vssps profile API.
--- Synchronous; cached for the session. No-op if already loaded or not logged in.
local function load_profile()
  if cached_user then
    return
  end
  local url = with_api('https://app.vssps.visualstudio.com/_apis/profile/profiles/me')
  local r =
    vim.system({ 'az', 'rest', '--method', 'get', '--url', url, '--resource', AZDO_RESOURCE }, { text = true }):wait()
  if r.code == 0 and vim.trim(r.stdout or '') ~= '' then
    local p = parse_or_default(r.stdout, {})
    cached_user = p.displayName or p.emailAddress
    cached_user_id = p.id
  end
end

--- @return string? displayName
function M.get_user()
  load_profile()
  return cached_user
end

--- @return string? identity id (for reviewer-vote routes)
function M.get_user_id()
  load_profile()
  return cached_user_id
end

---------------------------------------------------------------------------
-- PR data (metadata + commits + comment threads)
---------------------------------------------------------------------------

--- @param votes integer[] reviewer votes
local function review_decision(votes)
  local approved, rejected = false, false
  for _, v in ipairs(votes) do
    if v == -10 then
      rejected = true
    elseif v == 10 or v == 5 then
      approved = true
    end
  end
  if rejected then
    return 'CHANGES_REQUESTED'
  elseif approved then
    return 'APPROVED'
  end
  return 'REVIEW_REQUIRED'
end

--- Azure thread.status values that mean "resolved" (dropped from the diff view, like gh resolved threads).
local RESOLVED_STATUS = { fixed = true, closed = true, wontFix = true, byDesign = true }

--- Flattens Azure PR threads into the flat `Comment[]` list the UI expects.
---
--- - Drops resolved threads (counts them).
--- - Keeps only file-anchored threads with at least one human ("text") comment — general threads
---   surface in the PR overview, not the diff.
---
--- @return Comment[] comments, integer n_threads, integer n_resolved
local function flatten_threads(threads, web_url)
  local out = {}
  local n_threads, n_resolved = 0, 0
  for _, thread in ipairs((threads or {}).value or {}) do
    local ctx = thread.threadContext
    local text_comments = {}
    for _, c in ipairs(thread.comments or {}) do
      if not c.isDeleted and (c.commentType == nil or c.commentType == 'text' or c.commentType == 'codeChange') then
        table.insert(text_comments, c)
      end
    end
    if ctx and ctx.filePath and #text_comments > 0 then
      n_threads = n_threads + 1
      if RESOLVED_STATUS[thread.status] then
        n_resolved = n_resolved + 1
      else
        local path = (ctx.filePath:gsub('^/', ''))
        local side, start_line, end_line
        if ctx.rightFileStart then
          side = 'RIGHT'
          start_line = ctx.rightFileStart.line
          end_line = (ctx.rightFileEnd or ctx.rightFileStart).line
        elseif ctx.leftFileStart then
          side = 'LEFT'
          start_line = ctx.leftFileStart.line
          end_line = (ctx.leftFileEnd or ctx.leftFileStart).line
        end
        -- Synthetic single-line diff-hunk so threads anchored *off* the current diff
        -- ("outdated"/"outside") still render. Azure returns no hunk snippet like GitHub does.
        local diff_hunk = side == 'LEFT' and f('@@ -%d,1 +0,0 @@\n-', end_line or 0)
          or f('@@ -0,0 +%d,1 @@\n+', end_line or 0)
        if end_line and path then
          local head_id = text_comments[1].id
          for _, c in ipairs(text_comments) do
            local reply_to
            if c.parentCommentId and c.parentCommentId ~= 0 and c.id ~= head_id then
              reply_to = composite_id(thread.id, c.parentCommentId)
            end
            table.insert(out, {
              id = composite_id(thread.id, c.id),
              comment_id = c.id, -- real per-thread id (for REST routes)
              thread_id = thread.id,
              thread_node_id = tostring(thread.id),
              html_url = web_url,
              user = { login = (c.author or {}).displayName or '?' },
              body = c.content or '',
              diff_hunk = diff_hunk,
              path = path,
              start_line = start_line,
              end_line = end_line,
              side = side,
              updated_at = (c.lastUpdatedDate or c.publishedDate or ''):sub(1, 16):gsub('T', ' '),
              in_reply_to_id = reply_to,
              outdated = false,
            })
          end
        end
      end
    end
  end
  return out, n_threads, n_resolved
end

--- Collects general (non-file-anchored) discussion comments for the PR overview.
--- @return { user: string, updated_at: string, body: string }[]
local function general_threads(threads)
  local out = {}
  for _, thread in ipairs((threads or {}).value or {}) do
    if not thread.threadContext and not RESOLVED_STATUS[thread.status] then
      for _, c in ipairs(thread.comments or {}) do
        if not c.isDeleted and (c.commentType == nil or c.commentType == 'text') and vim.trim(c.content or '') ~= '' then
          table.insert(out, {
            user = (c.author or {}).displayName or '?',
            updated_at = (c.lastUpdatedDate or c.publishedDate or ''):sub(1, 16):gsub('T', ' '),
            body = c.content or '',
          })
        end
      end
    end
  end
  return out
end

--- @return PullRequest
local function to_pr(detail, threads, commits_resp, repo)
  local web_url = pr_web_url(repo, detail.pullRequestId)

  local commits = {}
  for _, c in ipairs((commits_resp or {}).value or {}) do
    local msg = c.comment or ''
    table.insert(commits, {
      oid = c.commitId,
      committedDate = ((c.committer or c.author or {}).date or ''),
      messageHeadline = msg:match('^([^\n]*)') or '',
      messageBody = (msg:match('^[^\n]*\n+(.*)$') or ''),
    })
  end

  local votes, reviewers = {}, {}
  for _, r in ipairs(detail.reviewers or {}) do
    table.insert(votes, r.vote or 0)
    table.insert(reviewers, { login = r.displayName, vote = r.vote })
  end

  local raw_comments, n_threads, n_resolved = flatten_threads(threads, web_url)

  return {
    author = { login = (detail.createdBy or {}).displayName },
    baseRefName = (detail.targetRefName or ''):gsub('^refs/heads/', ''),
    baseRefOid = (detail.lastMergeTargetCommit or {}).commitId,
    body = detail.description or '',
    changedFiles = 0,
    commits = commits,
    createdAt = detail.creationDate,
    headRefName = (detail.sourceRefName or ''):gsub('^refs/heads/', ''),
    headRefOid = (detail.lastMergeSourceCommit or {}).commitId,
    isDraft = detail.isDraft or false,
    labels = detail.labels or {},
    number = detail.pullRequestId,
    reviewDecision = review_decision(votes),
    reviews = reviewers,
    status = detail.status,
    title = detail.title,
    url = web_url,
    raw_comments = raw_comments,
    general = general_threads(threads),
    viewed = {}, -- Azure has no reliable per-file "viewed" state via API.
    n_threads = n_threads,
    n_resolved = n_resolved,
  }
end

--- Gets PR data: metadata + commits + comment threads, marshaled into `PullRequest`.
---
--- Mirrors the gh impl's cache contract: caches on the `pr/…` buffer unless `opts.force`.
---
--- @param prnum string|integer
--- @param repo string "org/project/repo"
--- @param opts? { force?: boolean }
--- @param cb fun(pr?: PullRequest)
function M.get_pr_data(prnum, repo, opts, cb)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local pr_buf = state.get_buf('pr', repo, prnum, false)
    local pr_data = pr_buf and (vim.b[pr_buf].azdo or {}).pr_data
    if pr_data then
      return cb(pr_data)
    end
  end
  local base = repo_base(repo)
  if not base then
    util.log('get_pr_data invalid repo', repo)
    return cb(nil)
  end

  local detail, threads, commits, pending = nil, nil, nil, 3
  local failed = false
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if failed or not detail then
      return cb(nil)
    end
    local pr = to_pr(detail, threads, commits, repo)
    state.set_b_azdo(assert(state.get_buf('pr', repo, prnum)), { pr_data = pr })
    util.log('get_pr_data ok', { comments = #pr.raw_comments, commits = #pr.commits })
    cb(pr)
  end

  az_rest('get', with_api(f('%s/pullRequests/%s', base, prnum)), nil, function(resp, _, code)
    if code ~= 0 or not resp then
      failed = true
    else
      detail = resp
    end
    done()
  end)
  az_rest('get', with_api(f('%s/pullRequests/%s/threads', base, prnum)), nil, function(resp)
    threads = resp or {}
    done()
  end)
  az_rest('get', with_api(f('%s/pullRequests/%s/commits', base, prnum)), nil, function(resp)
    commits = resp or {}
    done()
  end)
end

--- Probes whether `id` is a PR in `repo` (else treat as a work item). @param cb fun(is_pr: boolean)
function M.probe_is_pr(repo, id, cb)
  az_rest('get', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), nil, function(_, _, code)
    cb(code == 0)
  end)
end

---------------------------------------------------------------------------
-- Comment write actions
---------------------------------------------------------------------------

--- Replies to a thread. `reply_to` is the composite id of any comment in the thread.
function M.reply_to_comment(prnum, body, reply_to, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, parent = decode_id(reply_to)
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments', repo_base(repo), prnum, thread_id))
  az_write('reply_to_comment', 'post', url, { content = body, parentCommentId = parent, commentType = 1 }, cb)
end

--- Creates a new file-anchored comment thread.
function M.new_comment(pr, body, path, start_line, line, side, repo, cb)
  vim.validate('repo', repo, 'string')
  side = side or 'RIGHT'
  local anchor = side == 'LEFT' and 'leftFile' or 'rightFile'
  local thread_context = {
    filePath = '/' .. path:gsub('^/', ''),
    [anchor .. 'Start'] = { line = start_line, offset = 1 },
    [anchor .. 'End'] = { line = line, offset = 1 },
  }
  local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), pr.number))
  az_write('new_comment', 'post', url, {
    comments = { { content = body, commentType = 1 } },
    status = 1, -- active
    threadContext = thread_context,
  }, cb)
end

--- Posts a top-level (non-file-anchored) comment on a PR, or a work-item discussion comment.
--- @param kind 'pr'|'issue'
--- @param cb fun(ok: boolean, stderr?: string)
function M.new_overview_comment(kind, id, repo, body, cb)
  if kind == 'issue' then
    local url = with_api(f('%s/wit/workItems/%s/comments', project_base(repo), id))
    return az_rest('post', url, { text = body }, function(_, stderr, code)
      cb(code == 0, stderr)
    end)
  end
  local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), id))
  az_rest('post', url, { comments = { { content = body, commentType = 1 } }, status = 1 }, function(_, stderr, code)
    cb(code == 0, stderr)
  end)
end

function M.update_comment(comment_id, body, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, cid = decode_id(comment_id)
  local prnum = (vim.b.azdo or {}).id
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments/%d', repo_base(repo), prnum, thread_id, cid))
  az_write('update_comment', 'patch', url, { content = body }, cb)
end

function M.delete_comment(comment_id, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, cid = decode_id(comment_id)
  local prnum = (vim.b.azdo or {}).id
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments/%d', repo_base(repo), prnum, thread_id, cid))
  az_write('delete_comment', 'delete', url, nil, cb)
end

--- Resolves a comment thread (sets status=closed). `thread_node_id` is the Azure thread id (string).
function M.resolve_thread(thread_node_id, cb)
  vim.validate('thread_node_id', thread_node_id, 'string')
  local b = vim.b.azdo or {}
  local repo, prnum = b.repo, b.id
  if not repo or not prnum then
    return cb({ errors = { 'not in an azdo:// buffer' } })
  end
  local url = with_api(f('%s/pullRequests/%s/threads/%s', repo_base(repo), prnum, thread_node_id))
  -- status 4 = closed (resolved).
  az_write('resolve_thread', 'patch', url, { status = 4 }, cb)
end

---------------------------------------------------------------------------
-- PR-level actions: review (vote), merge (complete)
---------------------------------------------------------------------------

--- Submits a review by setting the signed-in user's reviewer vote (+ optional comment thread).
--- @param action 'approve'|'request-changes'|'comment'
--- @param cb fun(ok: boolean, stderr: string)
function M.review_pr(id, repo, action, body, cb)
  vim.validate('repo', repo, 'string')
  local uid = M.get_user_id()
  if not uid then
    return cb(false, 'Not logged in to az (run: az login)')
  end
  local vote = (action == 'approve' and 10) or (action == 'request-changes' and -10) or 0
  local function set_vote()
    local url = with_api(f('%s/pullRequests/%s/reviewers/%s', repo_base(repo), id, uid))
    az_rest('put', url, { vote = vote }, function(_, stderr, code)
      cb(code == 0, stderr or '')
    end)
  end
  -- For comment/request-changes with a body, post the body as a general thread first.
  if body and body ~= '' and action ~= 'approve' then
    local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), id))
    az_rest('post', url, { comments = { { content = body, commentType = 1 } }, status = 1 }, set_vote)
  else
    set_vote()
  end
end

--- Completes (merges) a PR.
--- @param method 'merge'|'squash'|'rebase'
--- @param cb fun(ok: boolean, stderr: string)
function M.merge_pr(id, repo, method, subject, body, admin, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  local strategy = (method == 'squash' and 'squash') or (method == 'rebase' and 'rebase') or 'noFastForward'
  -- Need the source commit id to complete; fetch fresh PR detail.
  az_rest('get', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), nil, function(detail, stderr, code)
    if code ~= 0 or not detail then
      return cb(false, stderr or 'failed to load PR')
    end
    local completion = {
      mergeStrategy = strategy,
      deleteSourceBranch = false,
      bypassPolicy = admin or false,
    }
    if admin then
      completion.bypassReason = 'azdo.nvim --admin'
    end
    if method ~= 'rebase' and subject and subject ~= '' then
      completion.mergeCommitMessage = vim.trim(subject .. '\n\n' .. (body or ''))
    end
    local payload = {
      status = 'completed',
      lastMergeSourceCommit = { commitId = (detail.lastMergeSourceCommit or {}).commitId },
      completionOptions = completion,
    }
    az_rest('patch', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), payload, function(_, e, c)
      cb(c == 0, e or '')
    end)
  end)
end

--- Patches PR properties (e.g. `{ title = ..., description = ... }`).
--- @param cb fun(ok: boolean, stderr: string)
function M.update_pr(id, repo, fields, cb)
  vim.validate('repo', repo, 'string')
  az_rest('patch', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), fields, function(_, stderr, code)
    cb(code == 0, stderr or '')
  end)
end

---------------------------------------------------------------------------
-- Diff + commit (local git; Azure has no unified-diff REST endpoint)
---------------------------------------------------------------------------

--- Produces a git unified diff for a PR by fetching the Azure refs and diffing
--- merge-base(target, source)..source. Requires a local clone whose `origin` is this repo.
---
--- @param pr PullRequest
--- @param cb fun(diff?: string, err?: string)
function M.get_pr_diff(repo, pr, cb)
  local id = pr.number
  -- Fetch the PR merge ref + both branch tips so the commits are present locally, then 3-dot diff.
  local script = table.concat({
    f('git fetch --no-tags --quiet origin "refs/pull/%s/merge" "%s" "%s" 2>/dev/null', id, pr.headRefName, pr.baseRefName),
    f('git diff --no-color "%s...%s"', pr.baseRefOid or 'HEAD', pr.headRefOid or 'HEAD'),
  }, '; ')
  util.system({ 'sh', '-c', script }, function(stdout, stderr, code)
    if code ~= 0 or vim.trim(stdout or '') == '' then
      return cb(nil, vim.trim(stderr or 'git diff failed (is the cwd a local clone of the PR repo?)'))
    end
    cb(stdout)
  end)
end

--- Shows a commit as a patch (via local `git show`).
--- @param cb fun(patch?: string, err?: string)
function M.get_commit(repo, sha, cb)
  local script = f('git fetch --no-tags --quiet origin "%s" 2>/dev/null; git show --no-color "%s"', sha, sha)
  util.system({ 'sh', '-c', script }, function(stdout, stderr, code)
    if code ~= 0 or vim.trim(stdout or '') == '' then
      return cb(nil, vim.trim(stderr or 'git show failed'))
    end
    cb(stdout)
  end)
end

---------------------------------------------------------------------------
-- Status (list of open PRs)
---------------------------------------------------------------------------

--- @param cb fun(prs?: { number: integer, title: string, isDraft: boolean, status: string }[], err?: string)
function M.list_prs(repo, cb)
  local url = with_api(f('%s/pullRequests', repo_base(repo)), 'searchCriteria.status=active&$top=50')
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr)
    end
    local prs = {}
    for _, p in ipairs(resp.value or {}) do
      table.insert(prs, { number = p.pullRequestId, title = p.title, isDraft = p.isDraft, status = p.status })
    end
    cb(prs)
  end)
end

---------------------------------------------------------------------------
-- Work items ("issues")
---------------------------------------------------------------------------

--- @param cb fun(wi?: table, err?: string)
function M.get_workitem(repo, id, cb)
  local url = with_api(f('%s/wit/workItems/%s', project_base(repo), id), '$expand=all')
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr)
    end
    cb(resp)
  end)
end

---------------------------------------------------------------------------
-- CI / Pipelines
---------------------------------------------------------------------------

--- Lists pipeline-build jobs for the latest build on the PR's merge ref.
--- `databaseId` encodes `buildId * MULT + logId` for `get_pr_ci_logs`.
---
--- @param pr PullRequest
--- @param cb fun(jobs?: table[], error?: string)
function M.get_pr_ci_jobs_logs(pr, repo, cb)
  local progress = util.new_progress_report('Loading CI builds', 0)
  progress('running')
  local pbase = project_base(repo)
  local url = with_api(
    f('%s/build/builds', pbase),
    f('branchName=refs/pull/%s/merge&$top=5&queryOrder=finishTimeDescending', pr.number)
  )
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp or #(resp.value or {}) == 0 then
      progress('failed')
      return cb(nil, vim.trim(stderr or '') ~= '' and stderr or f('No pipeline builds for PR #%s', pr.number))
    end
    local build = resp.value[1] -- latest
    az_rest('get', with_api(f('%s/build/builds/%s/timeline', pbase, build.id)), nil, function(tl, terr, tcode)
      if tcode ~= 0 or not tl then
        progress('failed')
        return cb(nil, terr)
      end
      local jobs = {}
      for _, rec in ipairs(tl.records or {}) do
        if (rec.type == 'Job' or rec.type == 'Task') and rec.log and rec.log.id then
          table.insert(jobs, {
            databaseId = build.id * COMMENT_MULT + rec.log.id,
            name = rec.name,
            conclusion = rec.result,
            status = rec.state,
            startedAt = rec.startTime or '',
            url = build._links and build._links.web and build._links.web.href,
          })
        end
      end
      if #jobs == 0 then
        progress('failed')
        return cb(nil, f('No logs for build %s', build.id))
      end
      table.sort(jobs, function(a, b)
        local as, bs = a.conclusion or a.status or '?', b.conclusion or b.status or '?'
        if as ~= bs then
          return as < bs
        end
        return (a.name or '') < (b.name or '')
      end)
      progress('success')
      cb(jobs)
    end)
  end)
end

--- @param job_id integer encodes `buildId * MULT + logId`.
--- @param cb fun(log?: string, error?: string)
function M.get_pr_ci_logs(job_id, repo, cb)
  local progress = util.new_progress_report('Loading CI log', 0)
  progress('running')
  local build_id, log_id = decode_id(job_id)
  -- The logs endpoint returns plain text, not JSON; fetch raw via vim.system.
  local url = with_api(f('%s/build/builds/%d/logs/%d', project_base(repo), build_id, log_id))
  util.system({ 'az', 'rest', '--method', 'get', '--url', url, '--resource', AZDO_RESOURCE }, function(raw, stderr, code)
    if code ~= 0 or vim.trim(raw or '') == '' then
      progress('failed')
      return cb(nil, vim.trim(stderr or 'log unavailable'))
    end
    progress('success')
    cb(vim.trim(raw))
  end)
end

return M
