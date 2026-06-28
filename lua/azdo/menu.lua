--- Command palette for azdo.nvim.
---
--- A small |vim.ui.select()| launcher for the plugin's top-level entry points,
--- so you don't have to remember command names. The same handful of actions is
--- shown everywhere — it is a launcher, not a per-buffer keymap list (use `g?`
--- inside an `azdo://` buffer for that). Bound to `:AzdoMenu` and
--- `<Plug>(azdo-menu)`.
---
--- Each action is `{ id, label, desc, run }`, exposed via `available()` so a
--- custom picker (e.g. a Telescope previewer showing each `desc`) can reuse the
--- same list. |azdo-menu-api|
local M = {}

--- The actions shown in the palette (source of truth for `:AzdoMenu`).
--- @return table[]
local function catalog()
  return {
    {
      id = 'status',
      label = 'Status/Pull Requests',
      desc =
      'Open the status dashboard for the current repo: your open PRs and the PRs awaiting your review. (`:Azdo`)',
      run = function()
        vim.cmd('Azdo')
      end,
    },
    {
      id = 'items',
      label = 'Work Items',
      desc =
      'Open the work-items dashboard for items assigned to you. Needs the `project` option to work outside a repo. (`:Azdo items`)',
      run = function()
        vim.cmd('Azdo items')
      end,
    },
    {
      id = 'create',
      label = 'Create Pull Request',
      desc =
      'Create a PR from the current branch — prompts for target branch, then title/body. (`:AzdoCreate`)',
      run = function()
        vim.cmd('AzdoCreate')
      end,
    },
    {
      id = 'open',
      label = 'Open by (ID, URL, or SHA)',
      desc =
      'Prompt for a PR/work-item id, an Azure DevOps URL, or a commit sha, then open it. (`:Azdo <target>`)',
      run = function()
        vim.ui.input({ prompt = 'Azdo target (#id, URL, or sha): ' }, function(target)
          if target and vim.trim(target) ~= '' then
            vim.cmd.Azdo(vim.trim(target))
          end
        end)
      end,
    },
  }
end

--- The actions available in the palette.
--- @return table[]
function M.available()
  return catalog()
end

--- Run an action.
--- @param action table|nil
function M.exec(action)
  if action and action.run then
    action.run()
  end
end

--- Open the command palette via `vim.ui.select` (so it flows through whatever
--- `vim.ui.select` handler is installed — Telescope, fzf-lua, snacks, or the
--- builtin). Bound to `:AzdoMenu` and `<Plug>(azdo-menu)`.
function M.open()
  local items = M.available()
  if #items == 0 then
    return
  end
  vim.ui.select(items, {
    prompt = 'Azdo',
    format_item = function(a)
      return a.label
    end,
  }, function(choice)
    M.exec(choice)
  end)
end

return M
