-- Builds what the board shows. No UI here.
--
-- Sources (all of them live in Config.settings, read through Constant):
--   active_tasks   what the user ran (label, pane_id, type_strategy, group, builder)
--   load_tasks     only used to count tasks and to drop stale history entries
--   selected_pane  send target / watch target
-- plus ONE backend call for the panes that are alive right now.

local Constant = require "rmux.constant"
local History = require "rmux.board.history"

local M = {}

---@class RmuxBoardTask
---@field kind "task"
---@field name string
---@field pane_id string|nil
---@field alive boolean
---@field strategy string
---@field cmd string
---@field watching boolean
---@field target boolean
---@field parent? string

---@class RmuxBoardGroup
---@field kind "group"
---@field name string
---@field children RmuxBoardTask[]
---@field on integer
---@field total integer
---@field alive boolean
---@field watching boolean

---@class RmuxBoardRecent
---@field kind "recent"
---@field name string
---@field ts integer

---@class RmuxBoardSnapshot
---@field running (RmuxBoardTask|RmuxBoardGroup)[]
---@field recent RmuxBoardRecent[]
---@field total_tasks integer
---@field provider string
---@field file_rc string

---@param Integs table
---@param recent_limit integer
---@return RmuxBoardSnapshot
function M.snapshot(Integs, recent_limit)
  local alive = {}
  for _, id in ipairs(Integs:run().get_lists_pane_id_opened()) do
    alive[id] = true
  end

  local selected = Constant.get_selected_pane()
  local is_watching = Constant.get_watcher_status() and true or false

  ---@param row RmuxBoardTask
  local function mark(row)
    local is_selected = row.pane_id ~= nil and row.pane_id == selected
    row.watching = is_selected and is_watching
    row.target = is_selected and not is_watching
  end

  local running, groups, seen = {}, {}, {}

  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    local strategy = task.type_strategy
    local cmd = task.builder and task.builder.cmd
    if type(cmd) == "table" then
      cmd = table.concat(cmd, " ")
    end

    ---@type RmuxBoardTask
    local row = {
      kind = "task",
      name = task.label,
      pane_id = task.pane_id,
      alive = alive[task.pane_id] == true,
      strategy = strategy,
      cmd = type(cmd) == "string" and cmd or "",
      watching = false,
      target = false,
    }

    if strategy == "orchestrator" and task.group then
      -- one row for the whole dependsOn group, children are shown on expand
      local group = groups[task.group]
      if not group then
        group = { kind = "group", name = task.group, children = {}, on = 0, total = 0, alive = false, watching = false }
        groups[task.group] = group
        running[#running + 1] = group
      end
      group.children[#group.children + 1] = row
    elseif strategy == "sequential" and task.group and task.label ~= task.group then
      -- hidden on purpose: the combined entry (label == group) stands for the whole chain
    else
      local key = tostring(strategy) .. ":" .. tostring(task.label)
      if not seen[key] then
        seen[key] = true
        running[#running + 1] = row
      end
    end
  end

  for _, row in ipairs(running) do
    if row.kind == "group" then
      row.total = #row.children
      for _, child in ipairs(row.children) do
        mark(child)
        if child.alive then
          row.on = row.on + 1
        end
        if child.watching then
          row.watching = true
        end
      end
      row.alive = row.on > 0
    else
      mark(row)
    end
  end

  local valid, total = {}, 0
  for _, task in pairs(Constant.get_load_tasks() or {}) do
    valid[task.name] = true
    total = total + 1
  end

  local used = {}
  for _, row in ipairs(running) do
    used[row.name] = true
  end

  local recent = {}
  for _, entry in ipairs(History.list(valid)) do
    if not used[entry.name] and #recent < recent_limit then
      recent[#recent + 1] = { kind = "recent", name = entry.name, ts = entry.ts }
    end
  end

  return {
    running = running,
    recent = recent,
    total_tasks = total,
    provider = tostring(Constant.get_run_with()),
    file_rc = Constant.get_file_rc() or "-",
  }
end

return M
