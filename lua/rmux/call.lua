local Config = require "rmux.config"
local Constant = require "rmux.constant"
local Picker = require "rmux.picker"
local Util = require "rmux.utils"
local tmpl = require "rmux.templates"

local M = {}

-- true  -> fall back to overseer (no backend detected, or no valid tasks.json)
-- false -> run tasks in multiplexer panes (tasks.json loaded and backend available)
local use_default_overseer = true

-- why overseer is used; shown by the board
local overseer_reason = "No .vscode/tasks.json in this project."

local Integs

local function setup_integs()
  if not Integs then
    Integs = require "rmux.integrations"
  end
  return Integs
end

---@param is_select_file? boolean
local edit_config = function(is_select_file)
  if is_select_file then
    Picker.select_and_load_filerc()
    return
  end

  local file_rc = Constant.get_file_rc()

  if not file_rc or not Util.exists(file_rc) then
    local provider = Constant.get_backend() or "overseer"
    Util.warn("Provider '" .. provider .. "' is used, but RC file '" .. tostring(file_rc) .. "' was not found")
    return
  end

  vim.cmd("vsp " .. vim.fn.fnameescape(file_rc))
  vim.cmd "wincmd ="
end

local call_ = {
  grep_err = function()
    if use_default_overseer then
      Util.warn "Cannot process, currently using the default provider (overseer)"
      return
    end
    setup_integs():find_err()
  end,

  run_file = function()
    if use_default_overseer then
      Picker.load_overseer(setup_integs(), true)
      return
    end
    Picker.load_tasks_list(setup_integs())
  end,

  grep_buf = function()
    Picker.grep_buf()
  end,

  send_line = function()
    setup_integs():send_line()
  end,

  send_vline = function()
    setup_integs():send_line_range()
  end,

  send_enter = function()
    setup_integs():send_enter()
  end,

  send_interrupt = function()
    setup_integs():send_signal_interrupt()
  end,

  send_interrupt_all = function()
    setup_integs():send_signal_interrupt_all()
  end,

  show_config = function()
    Util.info(vim.inspect(Constant.get_settings()))
  end,

  board = function()
    require("rmux.board").toggle(setup_integs(), {
      default_overseer = use_default_overseer,
      reason = overseer_reason,
    })
  end,

  -- TODO: the message says "default provider" but the condition fires when the
  -- default provider is NOT used. Decide which one is intended.
  target_pane = function()
    if use_default_overseer then
      Util.warn "Cannot process, currently using the default provider (overseer)"
      return
    end
    setup_integs():select_target_panes()
  end,

  edit_config = function()
    edit_config(false)
  end,

  select_filerc = function()
    edit_config(true)
  end,

  kill_all_panes = function()
    if use_default_overseer then
      vim.cmd.OverseerToggle()
      return
    end
    setup_integs():close_all_panes()
  end,
}

--  ╭──────────────────────────────────────────────────────────╮
--  │                     FACTORY COMMAND                      │
--  ╰──────────────────────────────────────────────────────────╯

local has_shown_notification = false

---@param provider string
local function show_notification_once(provider)
  if has_shown_notification or not Config.settings.setnotif then
    return
  end
  has_shown_notification = true
  Util.info("Using provider: " .. provider)
end

---@class RmuxCommandOpts
---@field load_rc? boolean  load .vscode/tasks.json before running (default true)
---@field create_rc? boolean create .vscode/tasks.json from the default template when missing (default false)

--- Returns `true`, or `false, err` on expected failure.
--- Unhandled errors bubble up to `M.command`.
---@param state_cmd string
---@param opts RmuxCommandOpts
---@return boolean ok, string|nil err
local function run_command(state_cmd, opts)
  local handler = call_[state_cmd]
  if not handler then
    return false, ("unknown command: %s"):format(tostring(state_cmd))
  end

  -- nil when run_with = "auto" and nvim isn't inside tmux or herdr
  local backend, no_backend_reason = Constant.get_backend()

  local taskrc = tmpl:register()
  taskrc:set_template { require "rmux.templates.vscode" }

  if opts.create_rc then
    local path, created = taskrc:ensure_rc(vim.fn.getcwd())
    if not path then
      return false, created -- holds the error message when path is nil
    end
    if created then
      Util.info("Created " .. path)
      vim.cmd("vsp " .. vim.fn.fnameescape(path))
    end
  end

  if opts.load_rc ~= false then
    -- Load rc even without a backend (cached by mtime) so edit/select commands
    -- still locate the file, while execution falls back to overseer.
    local loaded, err = taskrc:is_load()
    if err then
      Util.warn(err) -- warn once before falling back to overseer
    end

    use_default_overseer = not loaded or backend == nil
    if backend == nil and no_backend_reason then
      overseer_reason = no_backend_reason
    else
      overseer_reason = err or "No .vscode/tasks.json in this project."
    end
  end

  show_notification_once(backend or "overseer")

  handler()
  return true
end

---@param e any
---@return string
local function on_error(e)
  if Config.settings.debug then
    return debug.traceback(tostring(e), 2)
  end
  return tostring(e)
end

--- Entry point for running commands; catches and surfaces all errors as notifications.
---@param state_cmd string
---@param opts? RmuxCommandOpts
function M.command(state_cmd, opts)
  local ok, success, err = xpcall(run_command, on_error, state_cmd, opts or {})

  if not ok then
    Util.error(success)
  elseif not success then
    Util.warn(err)
  end
end

return M
