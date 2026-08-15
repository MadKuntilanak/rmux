local Call = require "rmux.call"
local Config = require "rmux.config"
local Util = require "rmux.utils"
local Highlight = require "rmux.highlights"

local M = {}

---@return boolean
local function err_loadMsg()
  if Config.settings.load_tasks and #Config.settings.load_tasks == nil then
    Util.warn "Cannot continue: load_tasks is empty"
    return false
  end

  return true
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        BASE SETUP                        │
--  ╰──────────────────────────────────────────────────────────╯

function M.setup(opts)
  Config.update_settings(opts)
  Highlight.setup()
end

local cmds = {
  ["RmuxRunFile"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_FILE)
    end
  end,

  ["RmuxSetTemplate"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.SELECT_FILERC, true)
    end
  end,
  --  ────────────────────────────────────────────────────────────
  ["RmuxSendline"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_SEND, true)
    end
  end,
  ["RmuxSendlineV"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_VSEND, true)
    end
  end,
  ["RmuxSendEnter"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_ENTER, true)
    end
  end,
  ["RmuxSelectTargetPane"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_TARGET_PANE)
    end
  end,
  ["RmuxGrepErr"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_GRAB_ERR)
    end
  end,
  ["RmuxGrepBuf"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_GRAB_BUF)
    end
  end,
  --  ────────────────────────────────────────────────────────────
  ["RmuxSendInterrupt"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_INTERRUPT)
    end
  end,
  ["RmuxSendInterruptAll"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_INTERRUPT_ALL)
    end
  end,
  ["RmuxKillAllPanes"] = function()
    if err_loadMsg() then
      Call.command(Config.settings.cmd_provider.RUN_KILL_ALL_PANES)
    end
  end,
  --  ────────────────────────────────────────────────────────────
  ["RmuxSHOWConfig"] = function()
    Call.command(Config.settings.cmd_provider.SHOW_CONFIG)
  end,
  ["RmuxEDITConfig"] = function()
    Call.command(Config.settings.cmd_provider.EDIT_CONFIG)
  end,
  ["RmuxSelectFilerc"] = function()
    Call.command(Config.settings.cmd_provider.SELECT_FILERC)
  end,
}

for idx_cmd, cmd in pairs(cmds) do
  vim.api.nvim_create_user_command(idx_cmd, function()
    cmd()
  end, {})
end

return M
