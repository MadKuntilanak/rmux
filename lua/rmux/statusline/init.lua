local Constant = require "rmux.constant"

--  ╭──────────────────────────────────────────────────────────╮
--  │ A statusline component is evaluated on EVERY redraw.     │
--  │                                                          │
--  │   get()      pure: reads Config.settings through         │
--  │              Constant, no subprocess, no notification,   │
--  │              never throws, result cached until an input  │
--  │              changes.                                    │
--  │   timer      the only thing that talks to the backend:   │
--  │              prunes dead panes every REFRESH_MS, only    │
--  │              while tasks exist, silent on failure.       │
--  ╰──────────────────────────────────────────────────────────╯

local M = {}

local REFRESH_MS = 2000

---@class RmuxStatus  (read-only: the same table is returned until an input changes)
---@field task integer     running tasks (a dependsOn group counts one pane per task)
---@field run_with string  "Tmux", "Herdr", ... or "Overseer" when no multiplexer is used
---@field watch string     pane being watched ("" when not watching)
---@field target string    pane that receives send-line / send-enter ("" when none or watching)

---@type RmuxStatus
local EMPTY = { task = 0, run_with = "", watch = "", target = "" }

local memo = { key = nil, status = EMPTY }

---@type uv.uv_timer_t|nil
local timer

---@param pane_id any
---@return string
local function pane_label(pane_id)
  if type(pane_id) ~= "string" or pane_id == "" then
    return ""
  end
  return (pane_id:gsub("^%%", "")) -- tmux "%3" -> "3"; herdr "w1:p2" stays
end

---@param str string
---@return string
local function capitalize(str)
  return (str:gsub("^%l", string.upper))
end

--- The chain of a sequential dependsOn has hidden children plus one combined
--- entry; only the combined one counts.
---@return integer
local function count_tasks()
  local n = 0
  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    local hidden = task.type_strategy == "sequential" and task.group ~= nil and task.label ~= task.group
    if not hidden then
      n = n + 1
    end
  end
  return n
end

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

--- Drop dead panes from the bookkeeping, then redraw only if something changed.
--- Any failure (tmux gone, ...) is swallowed: a statusline must never complain.
local function refresh()
  local function snapshot()
    return count_tasks() .. "|" .. tostring(Constant.get_selected_pane())
  end

  local before = snapshot()
  local ok = pcall(function()
    require("rmux.integrations"):update_rmux()
  end)

  if not ok then
    stop_timer() -- retried by the next get() that still sees tasks
    return
  end

  if snapshot() ~= before then
    pcall(vim.cmd.redrawstatus)
  end
end

local function ensure_timer()
  if timer then
    return
  end

  timer = vim.uv.new_timer()
  if timer then
    timer:start(
      REFRESH_MS,
      REFRESH_MS,
      vim.schedule_wrap(function()
        if #(Constant.get_active_tasks() or {}) == 0 or not Constant.get_backend() then
          stop_timer()
          return
        end
        refresh()
      end)
    )
  end
end

---@return RmuxStatus
function M.get()
  if Constant.get_statusline_status() == nil then
    Constant.statusline_is_up(true)
  end

  local tasks = count_tasks()
  local backend = Constant.get_backend() -- nil: no tmux/herdr -> overseer
  local selected = Constant.get_selected_pane()
  local watching = Constant.get_watcher_status() and true or false

  if tasks > 0 and backend then
    ensure_timer()
  end

  local key = table.concat({ tasks, backend or "-", tostring(selected), tostring(watching) }, "|")
  if memo.key == key then
    return memo.status
  end

  local label = pane_label(selected)

  ---@type RmuxStatus
  local status = {
    task = tasks,
    run_with = capitalize(backend or "overseer"),
    watch = watching and label or "",
    target = (not watching) and label or "",
  }

  memo = { key = key, status = status }
  return status
end

return M
