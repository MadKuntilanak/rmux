local Config = require "rmux.config"
local Constant = require "rmux.constant"

local M = {}

---@param str string
---@return string
local function remove_percent(str)
  return vim.split(str:gsub("%%", ""), " ")[1]
end

---@param str string
---@return string
local function capitalize_first_letter(str)
  return (str:gsub("^%l", string.upper))
end

---@return {task: integer, run_with: string, watch: string}
function M.get()
  local status = { task = 0, run_with = "", watch = "" }

  local Integs = require "rmux.integrations"

  local statusline_status = Constant.get_statusline_status()
  if statusline_status == nil then
    Constant.statusline_is_up(true)
  end

  Integs:update_rmux()

  local tbl_active_tasks = Constant.get_active_tasks()

  if tbl_active_tasks and #tbl_active_tasks > 0 then
    status.task = #tbl_active_tasks
  end

  local run_with = Config.settings.run_with
  if run_with and #run_with > 0 then
    run_with = capitalize_first_letter(run_with)
    status.run_with = run_with
  end

  local selected_pane = Constant.get_selected_pane()
  if selected_pane then
    status.watch = remove_percent(selected_pane)
  end

  return status
end

return M
