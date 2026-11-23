local Config = require "rmux.config"

local M = {}

function M.get_settings()
  return Config.settings
end

function M.get_load_tasks()
  return Config.settings.load_tasks
end

---@return RmuxActiveTasks[]
function M.get_active_tasks()
  return Config.settings.active_tasks
end

---@return string
function M.get_sendID()
  return Config.settings.sendID
end

---@param run_with RmuxRunWith
function M.set_run_with(run_with)
  Config.settings.run_with = run_with
end

function M.get_run_with()
  return M.get_backend() or M.get_settings().run_with
end

---@param tbl_tasks any
function M.load_tasks(tbl_tasks)
  Config.settings.load_tasks = vim.deepcopy(tbl_tasks)
end

---@param opts_task_active RmuxActiveTasks
function M.insert_active_tasks(opts_task_active)
  if not Config.settings.active_tasks then
    Config.settings.active_tasks = {}
  end
  return table.insert(Config.settings.active_tasks, opts_task_active)
end

--Tweaking an item in the active_tasks list
function M.update_active_tasks(fn)
  local active_tasks = M.get_active_tasks()
  for idx, task in pairs(active_tasks) do
    fn(idx, task)
  end
end

function M.remove_from_active_tasks(pane_id)
  local active_tasks = M.get_active_tasks()
  for idx, pane in ipairs(active_tasks) do
    if pane.pane_id == pane_id then
      table.remove(active_tasks, idx)
      break
    end
  end
end

---------------------

function M.set_sendID(send_pane)
  vim.validate { send_pane = { send_pane, "string" } }
  Config.settings.sendID = send_pane
end

---@return integer
function M.get_size_pane()
  return 12
end

---@param is_set boolean
function M.statusline_is_up(is_set)
  local base = M.get_settings()
  base.statusline = is_set
end

---@return boolean
function M.get_statusline_status()
  local base = M.get_settings()
  return base.statusline
end

---@param panes_id string
function M.set_selected_pane(panes_id)
  local base = M.get_settings()
  base.selected_pane = panes_id
end

---@param file_rc string
function M.set_file_rc(file_rc)
  local base = M.get_settings()
  base.file_rc = file_rc
end

---@return string
function M.get_file_rc()
  local base = M.get_settings()
  return base.file_rc
end

---@return string
function M.get_pathdir_rmuxrc()
  local base = M.get_settings()
  return base.rmuxdirrc
end

---@return string
function M.get_selected_pane()
  local base = M.get_settings()
  return base.selected_pane
end

---@param status_watch boolean
function M.set_watcher_status(status_watch)
  local base = M.get_settings()
  base.is_watcher = status_watch
end

function M.get_watcher_status()
  local base = M.get_settings()
  return base.is_watcher
end

---@return RmuxProviders
function M.get_template_provider()
  local base = M.get_settings()
  return base.provider
end

---@param provider_name RmuxProviders
function M.set_template_provider(provider_name)
  local base = M.get_settings()
  base.provider = provider_name
end

function M.open_qf()
  local base = M.get_settings()
  return base.quickfix.copen
end

function M.open_loc()
  local base = M.get_settings()
  return base.quickfix.lopen
end

-- function M.find_state_cmd_on_tbl_opened_panes(state_cmd)
--   local active_tasks = M.get_active_tasks()
--   for _, value in pairs(active_tasks) do
--     if value.state_cmd == state_cmd then
--       return value
--     end
--   end
-- end

--  ╭──────────────────────────────────────────────────────────╮
--  │                         BACKEND                          │
--  ╰──────────────────────────────────────────────────────────╯

-- Check innermost multiplexer first. herdr strips outer $TMUX/$WEZTERM vars,
-- while a tmux session inside herdr sets its own $TMUX.
local BACKENDS = {
  {
    name = "tmux",
    is_active = function()
      return (vim.env.TMUX or "") ~= ""
    end,
  },
  {
    name = "herdr",
    is_active = function()
      return vim.env.HERDR_ENV == "1"
    end,
  },
  {
    name = "wez",
    is_active = function()
      return (vim.env.WEZTERM_EXECUTABLE or "") ~= ""
    end,
  },
}

---@type table<string, boolean>
local available = {}

---@param name string
---@return boolean
local function has_module(name)
  if available[name] == nil then
    local dir = ("lua/rmux/integrations/%s/init.lua"):format(name)
    local file = ("lua/rmux/integrations/%s.lua"):format(name)
    available[name] = #vim.api.nvim_get_runtime_file(dir, false) > 0 or #vim.api.nvim_get_runtime_file(file, false) > 0
  end
  return available[name]
end

---@return string|nil backend, string|nil reason
function M.get_backend()
  local configured = Config.settings.run_with
  if configured and configured ~= "auto" then
    return configured
  end

  for _, backend in ipairs(BACKENDS) do
    if backend.is_active() and has_module(backend.name) then
      return backend.name
    end
  end

  return nil, "No terminal multiplexer detected (tmux / herdr)"
end

return M
