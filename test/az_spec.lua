-- Self-contained tests for azdo.nvim's pure logic (no network, no Neovim source build).
-- Run with:  nvim -l test/az_spec.lua   (or `make test`)
--
-- These cover the provider-specific parsing that everything else depends on: remote-url parsing,
-- :Azdo argument parsing, and the buffer-uri <-> key roundtrip. The REST/diff layers require a live
-- Azure DevOps org and are exercised manually (see README "Manual smoke test").

vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, 'S').source:sub(2)), ':h:h'))

local az = require('azdo.az')
local util = require('azdo.util')

local n_fail = 0
local function check(label, got, want)
  local g, w = vim.inspect(got), vim.inspect(want)
  if g ~= w then
    n_fail = n_fail + 1
    io.write(('not ok - %s\n   got:  %s\n   want: %s\n'):format(label, g, w))
  else
    io.write(('ok - %s\n'):format(label))
  end
end

-- parse_remote: every Azure DevOps remote-url shape resolves to "org/project/repo".
check('remote https', az.parse_remote('https://dev.azure.com/myorg/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check('remote https .git', az.parse_remote('https://dev.azure.com/myorg/MyProj/_git/myrepo.git'), 'myorg/MyProj/myrepo')
check('remote org@host', az.parse_remote('https://myorg@dev.azure.com/myorg/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check('remote ssh', az.parse_remote('git@ssh.dev.azure.com:v3/myorg/MyProj/myrepo'), 'myorg/MyProj/myrepo')
check('remote visualstudio.com', az.parse_remote('https://myorg.visualstudio.com/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check('remote non-azure', az.parse_remote('https://github.com/owner/repo'), nil)

-- parse_target: URLs, azdo:// URIs, slugs, bare ids/shas.
local pt = util.parse_target
check('pr url', pt('https://dev.azure.com/o/p/_git/r/pullrequest/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('commit url', pt('https://dev.azure.com/o/p/_git/r/commit/a1b2c3d'), { repo = 'o/p/r', sha = 'a1b2c3d' })
check('workitem url', pt('https://dev.azure.com/o/p/_workitems/edit/99'), { id = 99, is_pr = false })
check('repo url', pt('https://dev.azure.com/o/p/_git/r'), { repo = 'o/p/r' })
check('uri pr', pt('azdo://o/p/r/pr/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('uri prdiff', pt('azdo://o/p/r/prdiff/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('uri issue', pt('azdo://o/p/r/issue/7'), { repo = 'o/p/r', id = 7 })
check('uri commit', pt('azdo://o/p/r/commit/abc1234'), { repo = 'o/p/r', sha = 'abc1234' })
check('uri status', pt('azdo://status'), {})
check('slug#id', pt('o/p/r#42'), { repo = 'o/p/r', id = 42 })
check('slug', pt('o/p/r'), { repo = 'o/p/r' })
check('#id', pt('#42'), { id = 42 })
check('bare num', pt('42'), { id = 42 })
check('bare sha', pt('a1b2c3d'), { sha = 'a1b2c3d' })
check('garbage', pt('???'), nil)

if n_fail > 0 then
  io.write(('\n%d test(s) FAILED\n'):format(n_fail))
  os.exit(1)
end
io.write('\nall tests passed\n')
