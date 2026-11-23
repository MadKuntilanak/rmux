local M = {}

---@type RmuxDefaultsConfig
M.settings = {
  rmuxdirrc = vim.fn.stdpath "cache" .. "/runmux",
  run_with = "auto", -- "tmux, wez, herdr, auto"
  setnotif = true,
  debug = false,
  quickfix = {
    copen = "belowright copen",
    lopen = "belowright lopen",
  },
  board = {
    keymaps = {
      -- Use `false` to disable it.
      focus = "f",
      run = "<CR>",
      stop = "s",
      kill = { "x", "K" },
      forget = "D",
      watch = "w",
      unwatch = "W",
      error = "e",
      all = "a",
      select_pane = "p",
      overseer = "o",
      toggle_group = "<Tab>",
      close = { "q", "<Esc>" },
      help = { "?", "g?" },
    },
  },
}

---@param cfg_tbl RmuxDefaultsConfig
---@param opts table
---@return RmuxDefaultsConfig
local function merge_settings(cfg_tbl, opts)
  opts = opts or {}
  local settings = vim.tbl_deep_extend("force", cfg_tbl, opts)
  return settings
end

function M.update_settings(opts)
  opts = opts or {}

  M.settings = merge_settings(M.settings, opts)

  M.settings.sendID = ""
  M.settings.file_rc = ""
  M.settings.active_tasks = {}
  M.settings.load_tasks = {}
  M.settings.cmd_provider = {
    RUN_FILE = "run_file",
    RUN_KILL_ALL_PANES = "kill_all_panes",

    RUN_SEND = "send_line",
    RUN_VSEND = "send_vline",
    RUN_ENTER = "send_enter",
    RUN_INTERRUPT = "send_interrupt",
    RUN_INTERRUPT_ALL = "send_interrupt_all",

    RUN_GRAB_ERR = "grep_err",
    RUN_GRAB_BUF = "grep_buf",
    RUN_TARGET_PANE = "target_pane",

    EDIT_CONFIG = "edit_config",
    SELECT_FILERC = "select_filerc",
    SHOW_CONFIG = "show_config",
  }

  return M.settings
end

return M
