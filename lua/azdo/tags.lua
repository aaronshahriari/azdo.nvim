--- Local "tagged" (pinned) work items, persisted to disk and keyed by project.
--- Work-item ids are project-scoped, so tags are stored under a per-project key
--- (the project label, e.g. "KnowledgebasePlatform"). State lives in
--- `stdpath('data')/azdo/tags.json` as `{ [project] = { id, id, … } }` (tag order
--- preserved).

local M = {}

local function path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'azdo', 'tags.json')
end

--- @type table<string, integer[]>?
local cache

local function load()
  if cache then
    return cache
  end
  cache = {}
  local p = path()
  if vim.fn.filereadable(p) == 1 then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(p), '\n'))
    end)
    if ok and type(data) == 'table' then
      cache = data
    end
  end
  return cache
end

local function save()
  local p = path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode(cache or {}) }, p)
end

--- Tagged ids for `project`, in tag order.
--- @param project string
--- @return integer[]
function M.list(project)
  local t = load()[project]
  return (type(t) == 'table' and t) or {}
end

--- @param project string
--- @param id integer
--- @return boolean
function M.is_tagged(project, id)
  for _, v in ipairs(M.list(project)) do
    if v == id then
      return true
    end
  end
  return false
end

--- Toggles a tag and persists. Returns the new state (true = now tagged).
--- @param project string
--- @param id integer
--- @return boolean now_tagged
function M.toggle(project, id)
  local data = load()
  data[project] = data[project] or {}
  local lst = data[project]
  for i, v in ipairs(lst) do
    if v == id then
      table.remove(lst, i)
      save()
      return false
    end
  end
  table.insert(lst, id)
  save()
  return true
end

return M
