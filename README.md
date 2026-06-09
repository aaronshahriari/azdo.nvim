# azdo.nvim

> [!NOTE]
> Work with Azure DevOps pull requests in Neovim. WIP/beta — PRs/feedback welcome!

azdo.nvim is a port of [guh.nvim](https://github.com/justinmk/guh.nvim) (by justinmk) from
GitHub to **Azure DevOps**. It keeps guh's minimalist workflow and its UI machinery — diff
comments in a 'scrollbind' split, `vim.diagnostic`, and the quickfix list — but swaps the
backend: instead of the GitHub `gh` CLI it shells out to the **Azure CLI** (`az rest` for the
Azure DevOps REST API) plus local `git` for diffs.

The only provider-specific module is [`lua/azdo/az.lua`](./lua/azdo/az.lua); everything else
(`comments.lua`, `state.lua`, `util.lua`) is shared, agnostic UI code.

## Usage

Run `:Azdo` to see status (open PRs for the current repo):

    :Azdo

Run `:Azdo 42` to view PR/work-item 42 (it probes: a PR id opens the PR; otherwise a work item).
Also accepts an Azure DevOps URL, an `org/project/repo#42` slug, or a commit SHA:

    :Azdo 42
    :Azdo a1b2c3d
    :Azdo https://dev.azure.com/myorg/MyProject/_git/myrepo/pullrequest/42
    :Azdo myorg/MyProject/myrepo#42
    :Azdo azdo://myorg/MyProject/myrepo/pr/42
    :Azdo https://dev.azure.com/myorg/MyProject/_workitems/edit/1234

Inside any `azdo://` buffer, press `<Enter>` to run `:Azdo` on the target at cursor. Hit `g?` to
review the keymaps.

When viewing a PR:

- Diff comments are presented (1) in a 'scrollbind' split, (2) as "diagnostics" (`vim.diagnostic`),
  (3) loaded in quickfix.
- `cc` (or visual `c`) comments on a diff line/range; `cr` replies-to or resolves a thread.
- `cR` reviews the PR (approve / request-changes / comment → reviewer **vote**).
- `cM` completes (merges) the PR (squash / merge / rebase, optional `--admin` bypass).
- `c:` edits the PR title/description (or opens a work item in the browser).
- `dl` shows the most-recent **pipeline** logs for the build on the PR.

Editable buffers (comments, merge/complete message, PR edit) confirm on write-and-close (`ZZ`
submits, `ZQ` discards).

Keymaps are provided as `<Plug>(azdo-…)`. To customize, define a mapping to the relevant
`<Plug>(azdo-…)` and azdo will skip its default. See the [help file](./doc/azdo.txt).

## Install

```lua
vim.pack.add{ 'https://github.com/<you>/azdo.nvim' }
```

Requirements:

- Nvim 0.13+
- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az`) — authenticated via `az login`.
- The [azure-devops](https://learn.microsoft.com/azure/devops/cli/) extension
  (`az extension add --name azure-devops`) — used for work-item views.
- A **local clone** of the repo (the PR diff is produced with local `git`; see below).
- (Optional) For highlighting diffs, a plugin such as [diffs.nvim](https://github.com/barrettruth/diffs.nvim).

## How it differs from guh.nvim / GitHub

Azure DevOps' data model isn't identical to GitHub's, so a few behaviors are mapped:

| guh / GitHub                | azdo / Azure DevOps                                            |
| --------------------------- | ------------------------------------------------------------- |
| Issues                      | **Work items** (`az boards work-item`, project-level)         |
| PR review comments          | PR **threads** (`/pullRequests/{id}/threads`)                 |
| Approve / request-changes   | Reviewer **vote** (`+10` / `-10`)                             |
| Merge                       | **Complete** PR (squash / noFastForward / rebase strategy)    |
| Checks / Actions logs       | **Pipelines** builds + timeline logs                          |
| per-file "Viewed" state     | Not exposed by the API → nothing is collapsed                 |

Notable limitations:

- **The PR diff requires a local clone** whose `origin` is the PR's repo. azdo fetches
  `refs/pull/<id>/merge` and runs `git diff` locally — Azure DevOps has no unified-diff REST
  endpoint like `gh pr diff`. Comments still load over REST even if the diff can't be produced.
- Auth comes from `az login` (every REST call passes `--resource <Azure DevOps GUID>`). No PAT
  is required.

## Manual smoke test

The automated tests cover only the pure parsing logic (`make test`). To exercise the REST/diff
paths, from a local Azure DevOps clone:

    :Azdo                  " list open PRs
    :Azdo <pr-id>          " open a PR: overview + diff + comments
    " on a diff line: cc to comment, cr to reply/resolve, cR to vote, cM to complete

## Credits

Forked from [guh.nvim](https://github.com/justinmk/guh.nvim) by justinmk, which was itself
rewritten from [ghlite.nvim](https://github.com/daliusd/ghlite.nvim) by Dalius Dobravolskas.
