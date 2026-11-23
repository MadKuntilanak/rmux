local Util = require "rmux.utils"

local Tmpl = {}
Tmpl.__index = Tmpl

local RC_DIR = ".vscode"
local RC_NAME = "tasks.json"
local RC_REL = RC_DIR .. "/" .. RC_NAME

local PLUGIN_ROOT = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

-- Cached tasks.json state (path + mtime) synced with `Constant`,
-- so we can skip re-parsing.
---@type { path: string, sec: integer, nsec: integer }|nil
local loaded_state

function Tmpl:register()
  return setmetatable({}, Tmpl)
end

---@param set_provider table
function Tmpl:set_template(set_provider)
  self.tbl_template_providers = {
    provider = set_provider,
  }
end

---@param path string
---@return string|nil content, string|nil err
local function read_file(path)
  local fd, err = io.open(path, "rb")
  if not fd then
    return nil, err
  end
  local data = fd:read "*a"
  fd:close()
  return data
end

---@param dst string absolute path of the rc file to create
---@return boolean ok, string|nil err
local function create_default_rc(dst)
  local src = vim.fs.joinpath(PLUGIN_ROOT, "fts", "vscode.json")

  local content, rerr = read_file(src)
  if not content then
    return false, "default template is not readable: " .. tostring(rerr)
  end

  local ok, merr = pcall(vim.fn.mkdir, vim.fs.dirname(dst), "p")
  if not ok then
    return false, "cannot create directory: " .. tostring(merr)
  end

  local fd, werr = io.open(dst, "wb")
  if not fd then
    return false, "cannot write " .. dst .. ": " .. tostring(werr)
  end
  fd:write(content)
  fd:close()

  return true
end

--- Pure check. Never creates anything.
---@param project_dir string
---@return boolean
function Tmpl:rc_exists(project_dir)
  return Util.is_file(vim.fs.joinpath(project_dir, RC_REL))
end

---@param project_dir string
---@return string|nil path, boolean|string|nil created_or_err  -- (path, created) | (nil, err)
function Tmpl:ensure_rc(project_dir)
  local dst = vim.fs.joinpath(project_dir, RC_REL)

  if Util.is_file(dst) then
    return dst, false
  end

  local ok, err = create_default_rc(dst)
  if not ok then
    return nil, err
  end

  return dst, true
end

---@return boolean loaded, string|nil err
function Tmpl:is_load()
  local project_dir = vim.fn.getcwd()
  local rc_path = vim.fs.joinpath(project_dir, RC_REL)
  local stat = vim.uv.fs_stat(rc_path)

  if not stat or stat.type ~= "file" then
    loaded_state = nil
    return false
  end

  if
    loaded_state
    and loaded_state.path == rc_path
    and loaded_state.sec == stat.mtime.sec
    and loaded_state.nsec == stat.mtime.nsec
  then
    return true
  end

  local providers = (self.tbl_template_providers or {}).provider or {}
  local last_err

  for _, template in ipairs(providers) do
    local ok, err = template:load(project_dir, RC_REL)
    if ok then
      loaded_state = { path = rc_path, sec = stat.mtime.sec, nsec = stat.mtime.nsec }
      return true
    end
    last_err = err
  end

  loaded_state = nil
  return false, last_err
end

return Tmpl
