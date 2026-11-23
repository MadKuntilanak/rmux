local Call = require "rmux.call"
local Config = require "rmux.config"
local Highlight = require "rmux.highlights"

local M = {}

function M.setup(opts)
  Config.update_settings(opts)
  Highlight.setup()
end

-- Commands that do not need tasks.json at all (they only talk to a pane).
local NO_RC = { load_rc = false }

local commands = {
  RmuxRunFile = { "RUN_FILE" },
  RmuxSelectTargetPane = { "RUN_TARGET_PANE" },
  RmuxGrepErr = { "RUN_GRAB_ERR" },
  RmuxGrepBuf = { "RUN_GRAB_BUF" },

  -- the only command that is allowed to create .vscode/tasks.json
  RmuxSetTemplate = { "SELECT_FILERC", { load_rc = false, create_rc = true } },

  RmuxSendline = { "RUN_SEND", NO_RC },
  RmuxSendlineV = { "RUN_VSEND", NO_RC },
  RmuxSendEnter = { "RUN_ENTER", NO_RC },

  RmuxSendInterrupt = { "RUN_INTERRUPT" },
  RmuxSendInterruptAll = { "RUN_INTERRUPT_ALL" },
  RmuxKillAllPanes = { "RUN_KILL_ALL_PANES" },

  RmuxBoard = { "BOARD", nil, "board" },

  RmuxSHOWConfig = { "SHOW_CONFIG" },
  RmuxEDITConfig = { "EDIT_CONFIG" },
  RmuxSelectFilerc = { "SELECT_FILERC" },
}

for name, spec in pairs(commands) do
  local key, opts, default = spec[1], spec[2], spec[3]
  vim.api.nvim_create_user_command(name, function()
    Call.command(Config.settings.cmd_provider[key] or default, opts)
  end, { desc = "rmux: " .. key })
end

return M
