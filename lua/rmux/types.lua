---@alias RmuxProviders "vscode"
---@alias RmuxRunWith "mux" | "wez" | "auto"

---@alias RmuxTypeStrategy "shell" | "process"  | "orchestrator" | "sequential" | "close_all"

---@class RmuxBuilderTasks
---@field cmd string|table
---@field name string
---@field components string|table

---@class RmuxActiveTasks
---@field pane_id string
---@field pane_idx number
---@field label string
---@field builder RmuxBuilderTasks
---@field type_strategy RmuxTypeStrategy

---@class RmuxProviderCmd
---@field RUN_FILE string
---@field RUN_KILL_ALL_PANES string
---@field RUN_SEND string
---@field RUN_VSEND string
---@field RUN_ENTER string
---@field RUN_INTERRUPT string
---@field RUN_INTERRUPT_ALL string
---@field RUN_GRAB_ERR string
---@field RUN_GRAB_BUF string
---@field RUN_TARGET_PANE string
---@field EDIT_CONFIG string
---@field SHOW_CONFIG string
---@field SELECT_FILERC string

---@class RmuxDefaultsConfig
---@field setnotif boolean
---@field run_with RmuxRunWith
---@field quickfix { copen: string, lopen: string}
---@field sendID? string
---@field rmuxdirrc? string
---@field file_rc? string
---@field load_tasks? table
---@field active_tasks? table
---@field cmd_provider? RmuxProviderCmd
---@field is_watcher? boolean
---@field selected_pane? string
---@field statusline? boolean
---@field provider? RmuxProviders
