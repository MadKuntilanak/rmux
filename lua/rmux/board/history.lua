-- History of the tasks the user ran in a project (newest first).
--
-- Only the NAME and the time are stored. tasks.json stays the single source
-- of truth for the command. The file lives in stdpath("state")/rmux/ and is
-- keyed by the cwd, so every project has its own list.
--
-- Contract: `true` | `nil, "message"`. A broken or missing file is simply an
-- empty history: it is a convenience, never a reason to fail a task run.

local M = {}

local MAX_KEPT = 30

---@type table<string, { name: string, ts: integer }[]>
local cache = {}

---@param cwd string
---@return string dir, string file
local function path_for(cwd)
  local dir = vim.fs.joinpath(vim.fn.stdpath "state", "rmux")
  return dir, vim.fs.joinpath(dir, vim.fn.sha256(cwd):sub(1, 16) .. ".json")
end

---@param cwd string
---@return { name: string, ts: integer }[]
local function load(cwd)
  if cache[cwd] then
    return cache[cwd]
  end

  local entries = {}
  local _, file = path_for(cwd)
  local fd = io.open(file, "rb")
  if fd then
    local raw = fd:read "*a"
    fd:close()

    local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok and type(data) == "table" and type(data.entries) == "table" then
      for _, e in ipairs(data.entries) do
        if type(e.name) == "string" and type(e.ts) == "number" then
          entries[#entries + 1] = { name = e.name, ts = e.ts }
        end
      end
    end
  end

  cache[cwd] = entries
  return entries
end

---@param cwd string
---@return true|nil ok, string|nil err
local function save(cwd)
  local dir, file = path_for(cwd)

  local ok, err = pcall(function()
    vim.fn.mkdir(dir, "p")
    local fd = assert(io.open(file, "wb"))
    fd:write(vim.json.encode { cwd = cwd, entries = cache[cwd] })
    fd:close()
  end)

  if not ok then
    return nil, "cannot save task history: " .. tostring(err)
  end
  return true
end

--- Mark `name` as just run (moves it to the top).
---@param name string
---@return true|nil ok, string|nil err
function M.record(name)
  local cwd = vim.fn.getcwd()
  local entries = load(cwd)

  for i, e in ipairs(entries) do
    if e.name == name then
      table.remove(entries, i)
      break
    end
  end

  table.insert(entries, 1, { name = name, ts = os.time() })
  while #entries > MAX_KEPT do
    table.remove(entries)
  end

  return save(cwd)
end

--- Newest first. When `valid` (a set of task names) is given, entries whose
--- task no longer exists in tasks.json are dropped from the file.
---@param valid? table<string, boolean>
---@return { name: string, ts: integer }[]
function M.list(valid)
  local cwd = vim.fn.getcwd()
  local entries = load(cwd)

  if valid and next(valid) then
    local pruned = false
    for i = #entries, 1, -1 do
      if not valid[entries[i].name] then
        table.remove(entries, i)
        pruned = true
      end
    end
    if pruned then
      save(cwd)
    end
  end

  return vim.list_slice(entries)
end

---@param name string
---@return true|nil ok, string|nil err
function M.forget(name)
  local cwd = vim.fn.getcwd()
  local entries = load(cwd)

  for i, e in ipairs(entries) do
    if e.name == name then
      table.remove(entries, i)
      break
    end
  end

  return save(cwd)
end

return M
