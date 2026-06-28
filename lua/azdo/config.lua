--- Configuration for azdo.nvim.
---
--- `require('azdo').setup(opts)` merges `opts` over these defaults; every other
--- module reads `require('azdo.config').options`. There are no `vim.g.*`
--- globals — `setup()` is the single source of truth. |azdo-config|
local M = {}

--- @class azdo.Config
M.defaults = {
  -- Connection / auth -------------------------------------------------------

  --- On-prem Azure DevOps Server collection root, e.g.
  --- "https://tfs.example.com/tfs/MyCollection". nil = cloud dev.azure.com.
  --- @type string?
  base_url = nil,

  --- REST api-version. Older on-prem servers may need e.g. "6.0".
  --- @type string
  api_version = '7.1',

  --- Personal Access Token. A string, or a function returning one (handy for
  --- reading it lazily from a keychain). nil = use `az login` / the
  --- $AZDO_PAT / $AZURE_DEVOPS_EXT_PAT env vars.
  --- @type string|fun():string?|nil
  pat = nil,

  --- Default project "org/project" (or just "project" on-prem) used by
  --- `:Azdo items` when you're not inside an Azure DevOps clone.
  --- @type string?
  project = nil,

  -- Behaviour ---------------------------------------------------------------

  --- Open a newly-created PR in a new tab (vs. the current window).
  --- @type boolean
  create_in_tab = true,

  --- PR comments split width, as a percentage (1-99) of the editor width.
  --- nil keeps Vim's 50% default.
  --- @type number?
  comments_width = nil,

  --- Log REST calls to `stdpath('log')/azdo.log`.
  --- @type boolean
  debug = false,

  --- Editable rich-text sections for the work-item editor, per work-item type.
  --- `{ [type] = { { title, field }, … } }`; "default" applies to unlisted
  --- types. `field` is the Azure reference name. Override a single type to
  --- replace its section list (e.g. add org-specific custom fields).
  workitem_sections = {
    default = {
      { 'Description', 'System.Description' },
      { 'Acceptance Criteria', 'Microsoft.VSTS.Common.AcceptanceCriteria' },
    },
    Bug = {
      { 'Repro Steps', 'Microsoft.VSTS.TCM.ReproSteps' },
      { 'System Info', 'Microsoft.VSTS.TCM.SystemInfo' },
      { 'Acceptance Criteria', 'Microsoft.VSTS.Common.AcceptanceCriteria' },
    },
  },

  -- Mappings ----------------------------------------------------------------

  --- Buffer-local default mappings inside `azdo://` buffers, as
  --- `{ action = lhs }`. Set one entry to `false` to drop just that key; set
  --- `keymaps = false` to disable all defaults. The wiring (which
  --- `<Plug>(azdo-…)` each action fires) lives in util.lua. |azdo-mappings|
  keymaps = {
    refresh = 'R',
    diff_toggle = 'dd',
    logs = 'dl',
    next_commit = ']f',
    prev_commit = '[f',
    web = 'gw',
    link = 'gW',
    help = 'g?',
    comment_overview = 'cC',
    merge = 'cM',
    review = 'cR',
    edit = 'c:',
    comment = 'cc',
    comment_visual = 'c',
    thread = 'cr',
    comment_delete = 'cd',
    comment_update = 'cu',
    open = '<CR>',
    open_split = '<C-W><CR>',
    next_comment = ']c',
    prev_comment = '[c',
    tag_toggle = 't',
  },

  --- Optional global mapping for the `:AzdoMenu` command palette, e.g.
  --- "<leader>a". nil = don't map anything (use `:AzdoMenu` / `<Plug>(azdo-menu)`).
  --- @type string?
  menu = nil,
}

--- The active, merged configuration. Read this everywhere.
--- @type azdo.Config
M.options = vim.deepcopy(M.defaults)

--- Merge `opts` over the defaults. Most keys merge deeply, but the two
--- list-bearing categories are merged one level deep so you can override a
--- single entry without re-specifying the rest:
---  - `workitem_sections`: per work-item type (each type's section list is
---    replaced wholesale, since a deep merge would splice the arrays).
---  - `keymaps`: per action (or `keymaps = false` to disable all).
--- @param opts azdo.Config?
--- @return azdo.Config
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)

  -- workitem_sections values are LISTS; tbl_deep_extend would merge them
  -- element-wise. Replace per work-item type instead.
  if opts.workitem_sections then
    merged.workitem_sections = vim.tbl_extend('force', vim.deepcopy(M.defaults.workitem_sections), opts.workitem_sections)
  end

  M.options = merged
  return M.options
end

--- Resolve the PAT (the `pat` option may be a string or a function).
--- @return string?
function M.pat()
  local p = M.options.pat
  if type(p) == 'function' then
    p = p()
  end
  if type(p) == 'string' and p ~= '' then
    return p
  end
  return nil
end

return M
