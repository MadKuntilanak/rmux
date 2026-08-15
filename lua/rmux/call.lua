local Config = require "rmux.config"
local Constant = require "rmux.constant"
local Picker = require "rmux.picker"
local Util = require "rmux.utils"

local M = {}

local use_default_overseer = true

local Integs

local function setup_integs()
  if Integs then
    return Integs
  end

  Integs = require "rmux.integrations"
  return Integs
end

---@param is_select_file? boolean
local edit_config = function(is_select_file)
  is_select_file = is_select_file or false

  if is_select_file then
    Picker.select_and_load_filerc()
    return
  end

  local file_rc = Constant.get_file_rc()

  if not Util.exists(file_rc) then
    local run_with = Constant.get_run_with()
    Util.warn("Provider '" .. run_with .. "' is used, but RC file '" .. file_rc .. "' was not found")
    return
  end

  vim.cmd("vsp " .. file_rc)
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

  target_pane = function()
    if not use_default_overseer then
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

-- Run only once
local has_shown_notification = false

---@param provider RmuxRunWith
local function notification_popup(provider)
  Util.info("Using the default provider: " .. provider)
end

---@param provider string
local function show_notification_once(provider)
  if not has_shown_notification and Config.settings.setnotif then
    has_shown_notification = true
    notification_popup(provider)
  end
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                     FACTORY COMMAND                      │
--  ╰──────────────────────────────────────────────────────────╯

local tmpl = require "rmux.templates"

---@param Settings RmuxDefaultsConfig
local function setup_run_with(Settings)
  local run_with = Settings.run_with
  if run_with == "auto" then
    local wezterm = Util.get_env "WEZTERM_EXECUTABLE"
    if wezterm then
      run_with = "wez"
    end

    local tmux = Util.get_env "TMUX"
    if tmux then
      run_with = "mux"
    end
  end
  Settings.run_with = run_with
end

---@param state_cmd string
---@param is_dont_set_rc boolean?
function M.command(state_cmd, is_dont_set_rc)
  local taskrc = tmpl:register()
  is_dont_set_rc = is_dont_set_rc or false

  local vscode = require "rmux.templates.vscode"
  taskrc:set_template { vscode }

  if is_dont_set_rc then
    local strip_filerc_path = { ".vscode", "tasks.json" }
    local file_rc = table.concat(strip_filerc_path, "/")
    tmpl:is_file_rc_exists(file_rc, strip_filerc_path)
    call_[state_cmd]()
    return
  end

  if taskrc:is_load() then
    use_default_overseer = false
  else
    use_default_overseer = true
  end

  setup_run_with(Config.settings)
  show_notification_once(Config.settings.run_with)

  local function _cmd()
    local cmd
    for _, provider_cmd in pairs(Config.settings.cmd_provider) do
      if state_cmd == provider_cmd then
        cmd = provider_cmd
      end
    end
    return cmd
  end

  local call = call_[_cmd()]

  -- Prevent the user from editing or updating the current buffer temporarily by
  -- disabling user input and entering command-line mode.
  vim.api.nvim_input "<Cmd>"

  call()

  -- Return to normal mode after the command is finished
  vim.api.nvim_input "<Esc>"
end

return M
