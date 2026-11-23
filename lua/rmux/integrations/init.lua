local Config = require "rmux.config"
local Constant = require "rmux.constant"
local Util = require "rmux.utils"
local Picker = require "rmux.picker"
local History = require "rmux.board.history"

local SEND_DELAY_MS = 100

---@param mod table
local function strict(mod)
  local cache = {}
  return setmetatable({}, {
    __index = function(_, key)
      local fn = mod[key]
      if type(fn) ~= "function" then
        return fn
      end
      if not cache[key] then
        cache[key] = function(...)
          local r1, r2 = fn(...)
          if not r1 and type(r2) == "string" then
            error(r2, 0)
          end
          return r1, r2
        end
      end
      return cache[key]
    end,
  })
end

---@param fn function
local function later(fn)
  vim.defer_fn(function()
    local ok, err = pcall(fn)
    if not ok then
      Util.error(tostring(err))
    end
  end, SEND_DELAY_MS)
end

---@param fn function
local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      Util.error(tostring(err))
    end
  end
end

---@return string[] unique pane ids of all active tasks (several tasks may share one pane)
local function active_pane_ids()
  local seen, ids = {}, {}
  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    local id = task.pane_id
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

---@param entries table[]
---@return string
local function join_cmds(entries)
  local cmds = {}
  for _, entry in ipairs(entries) do
    local cmd = entry.builder and entry.builder.cmd
    if type(cmd) == "table" then
      cmd = table.concat(cmd, " ")
    end
    if type(cmd) == "string" and cmd ~= "" then
      cmds[#cmds + 1] = cmd
    end
  end
  return table.concat(cmds, " && ")
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                      TASK LOOKUP                         │
--  ╰──────────────────────────────────────────────────────────╯

local task_index = { src = nil, by_name = {} }

local function find_task(name)
  local src = Constant.get_load_tasks() or {}

  if task_index.src ~= src then
    task_index = { src = src, by_name = {} }
    for _, task in pairs(src) do
      task_index.by_name[task.name] = task
    end
  end

  local hit = task_index.by_name[name]
  if hit then
    return hit
  end

  for _, task in pairs(src) do
    if task.builder({}).name == name then
      task_index.by_name[name] = task
      return task
    end
  end
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                          CORE                            │
--  ╰──────────────────────────────────────────────────────────╯

local Integs = {
  prefix = "Rmux",
  augroup_watcher = "Watcher",
  augroup_autokill = "AutoKill",
  augroups = {}, -- set: { [name] = true }
}

Integs.__index = Integs

local runners = {}

function Integs:run()
  -- Resolve "auto" per call. Commands that support overseer fallback bail out
  -- earlier in call/init.lua, so reaching here with nil means a hard requirement.
  local name, reason = Constant.get_backend()
  if not name then
    error(reason, 0)
  end

  if runners[name] then
    return runners[name]
  end

  local modname = "rmux.integrations." .. tostring(name)
  local ok, mod = pcall(require, modname)
  if not ok then
    if tostring(mod):find("module '" .. modname .. "' not found", 1, true) then
      error(("unsupported run_with '%s'"):format(tostring(name)), 0)
    end
    error(mod, 0) -- real bug inside the backend: keep its message
  end

  runners[name] = strict(mod)
  return runners[name]
end

---@param main_pane_id string
function Integs:__jump_to_main_pane(main_pane_id)
  self:run().jump_to_pane_id(main_pane_id)
end

---@return string pane_id
function Integs:_respawn_pane()
  local runner = self:run()
  local cwd = vim.fn.getcwd()
  local expand = runner.get_total_active_panes() ~= 1
  return runner.create_new_pane(cwd, expand)
end

--- Prunes dead panes from internal state in a single backend call (previously N+2).
--- Returns a lookup set of live pane IDs so callers can avoid redundant queries.
---@param pane_id? string
---@return table<string, boolean> alive
function Integs:update_rmux(pane_id)
  local alive = {}
  for _, id in ipairs(self:run().get_lists_pane_id_opened()) do
    alive[id] = true
  end

  local dead = {}

  if pane_id and #pane_id > 0 and not alive[pane_id] then
    dead[#dead + 1] = pane_id
  end

  local selected_pane = Constant.get_selected_pane()
  if selected_pane and #selected_pane > 0 and not alive[selected_pane] then
    Constant.set_selected_pane ""
    dead[#dead + 1] = selected_pane
  end

  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    if not alive[task.pane_id] then
      dead[#dead + 1] = task.pane_id
    end
  end

  for _, id in ipairs(dead) do
    Constant.remove_from_active_tasks(id)
  end

  return alive
end

---@param label_name string
---@param type_strategy RmuxTypeStrategy
---@param active_tasks table
---@param alive? table<string, boolean>
function Integs:is_task_active(label_name, type_strategy, active_tasks, alive)
  if not alive then
    alive = {}
    for _, id in ipairs(self:run().get_lists_pane_id_opened()) do
      alive[id] = true
    end
  end

  for _, t in ipairs(active_tasks) do
    if t.label == label_name and t.type_strategy == type_strategy and alive[t.pane_id] then
      return true
    end
  end
  return false
end

---@param main_pane_id string
---@param type_strategy string
---@param label_name string
---@param tbl_tasks RmuxActiveTasks[]
---@param is_clear_screen? boolean
function Integs:send_command_to_pane(main_pane_id, type_strategy, label_name, tbl_tasks, is_clear_screen)
  local runner = self:run()

  local ok, err = pcall(function()
    for _, task in ipairs(tbl_tasks) do
      if task.type_strategy == type_strategy and task.label == label_name then
        runner.send_pane_cmd_task(task, is_clear_screen or false)
      end
    end
  end)

  -- always go back to the main pane, even when a send failed
  self:__jump_to_main_pane(main_pane_id)

  if not ok then
    error(err, 0)
  end
end

---@param label_name string
---@param type_strategy string
---@param cur_pane_id string
---@param is_respawn_pane boolean
---@param builder_task? RmuxBuilderTasks
function Integs:spawn_pane(label_name, type_strategy, cur_pane_id, is_respawn_pane, builder_task)
  local runner = self:run()

  local pane_id
  if is_respawn_pane then
    pane_id = self:_respawn_pane()
  else
    pane_id = Constant.get_sendID()
  end

  if not pane_id or pane_id == "" then
    error("Run file aborted: no pane available to run the task in", 0)
  end

  if pane_id == cur_pane_id then
    error("Run file aborted: 'cur_pane_id' and 'pane_id' cannot have the same value.", 0)
  end

  Constant.insert_active_tasks {
    pane_id = pane_id,
    pane_idx = runner.get_pane_idx_from_id(pane_id),
    label = label_name,
    builder = builder_task or {},
    type_strategy = type_strategy,
  }

  Constant.set_selected_pane(pane_id)

  self:send_command_to_pane(cur_pane_id, type_strategy, label_name, Constant.get_active_tasks(), true)
end

---@param label_name string
---@param type_strategy RmuxTypeStrategy
---@param builder_task RmuxBuilderTasks|nil
function Integs:run_file(label_name, type_strategy, builder_task)
  local runner = self:run()
  local main_pane_id = runner.get_current_pane_id()

  local alive = self:update_rmux()
  local active_tasks = Constant.get_active_tasks()

  -- Not spawned yet (or its pane is gone): open a pane and run there
  if #active_tasks == 0 or not self:is_task_active(label_name, type_strategy, active_tasks, alive) then
    self:spawn_pane(label_name, type_strategy, main_pane_id, true, builder_task)
    return
  end

  -- Already running: cancel the prompt first, then send the command again
  for _, task in ipairs(active_tasks) do
    if task.type_strategy == type_strategy and task.label == label_name then
      self:send_signal_interrupt(task.pane_id)
    end
  end

  self:send_command_to_pane(main_pane_id, type_strategy, label_name, active_tasks, true)
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                  dependsOn (run_all)                     │
--  ╰──────────────────────────────────────────────────────────╯

---@param label_name string
---@param list_tasks string[] names from dependsOn, in order
---@param type_strategy RmuxTypeStrategy "orchestrator" | "sequential"
function Integs:run_all(label_name, list_tasks, type_strategy)
  local runner = self:run()
  local cur_pane_id = runner.get_current_pane_id()

  if type_strategy == "sequential" then
    local active_tasks = Constant.get_active_tasks()
    if #active_tasks > 0 and self:is_task_active(label_name, type_strategy, active_tasks) then
      self:send_command_to_pane(cur_pane_id, type_strategy, label_name, active_tasks, true)
      return
    end
  end

  -- Resolve all tasks upfront so invalid `dependsOn` names fail before opening
  -- any panes.  Caches builder() output per task by name for O(1) lookup.
  local resolved = {}
  for _, name in ipairs(list_tasks) do
    local lang_task = find_task(name)
    if not lang_task then
      error(("dependsOn task '%s' of '%s' was not found"):format(name, label_name), 0)
    end
    local builder = lang_task.builder {}
    resolved[#resolved + 1] = { name = name, builder = builder }
  end

  local pane_strategy = "-v"
  local pane_id, pane_idx
  local spawned = {}

  for _, item in ipairs(resolved) do
    -- orchestrator: one pane per task. sequential: one shared pane.
    if not (pane_id and type_strategy == "sequential") then
      pane_id = runner.open_vertical_pane(pane_strategy, 15)
      pane_idx = runner.get_pane_idx_from_id(pane_id)
      pane_strategy = "-h"
    end

    local entry = {
      pane_id = pane_id,
      pane_idx = pane_idx,
      label = item.builder.name or item.name,
      builder = item.builder,
      type_strategy = type_strategy,
      group = label_name, -- the board folds children under their dependsOn parent
    }
    Constant.insert_active_tasks(entry)
    spawned[#spawned + 1] = entry
  end

  runner.reset_size_pane()
  runner.jump_to_pane_id(cur_pane_id)

  -- Only what we just spawned is (re)started. Before, every active task with
  -- the same strategy was re-sent, including stale ones from earlier runs.
  if type_strategy == "orchestrator" then
    later(function()
      for _, entry in ipairs(spawned) do
        runner.send_pane_cmd_task(entry, true)
      end
      runner.jump_to_pane_id(cur_pane_id)
    end)
    return
  end

  if type_strategy == "sequential" then
    local last = spawned[#spawned]
    if not last then
      return
    end

    local combined = {
      name = label_name,
      components = { "default_vscode" },
      cmd = join_cmds(spawned), -- follows dependsOn order
    }

    Constant.insert_active_tasks {
      pane_id = last.pane_id,
      pane_idx = last.pane_idx,
      label = label_name,
      builder = combined,
      type_strategy = "sequential",
      group = label_name,
    }

    self:run_file(label_name, "sequential", combined)
  end
end

---@param label_name string
function Integs:generator_cmd_panes(label_name)
  if next(Constant.get_load_tasks() or {}) == nil then
    error("No tasks loaded (is .vscode/tasks.json empty?)", 0)
  end

  local lang_task = find_task(label_name)
  if not lang_task then
    error(("Task '%s' was not found in tasks.json"):format(label_name), 0)
  end

  local builder = lang_task.builder {} -- call builder only once

  -- type with: dependsOn("task 1", "task 2")
  local deps = builder.components and builder.components[2]
  if type(deps) == "table" and deps[1] == "dependencies" and deps.tasks and #deps.tasks > 0 then
    self:run_all(label_name, deps.tasks, deps.sequential and "sequential" or "orchestrator")
  end

  if type(builder.cmd) == "table" then
    self:run_file(label_name, "process", builder) -- type: process
  elseif type(builder.cmd) == "string" then
    self:run_file(label_name, "shell", builder) -- type: shell
  end

  self:setup_augroup()

  -- the one place every user-launched task goes through: feeds the board's "recent"
  local ok, err = History.record(label_name)
  if not ok then
    Util.warn(err)
  end
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                    SEND / TARGET PANE                    │
--  ╰──────────────────────────────────────────────────────────╯

--- Returns the selected pane, or opens the picker and returns nil.
---@return string|nil
local function selected_pane_or_pick(self)
  local pane = Constant.get_selected_pane()
  if type(pane) ~= "string" or pane == "" then
    self:select_target_panes()
    return nil
  end
  return pane
end

function Integs:send_line()
  local pane = selected_pane_or_pick(self)
  if pane then
    self:run().send_line(pane)
  end
end

function Integs:send_line_range()
  local pane = selected_pane_or_pick(self)
  if pane then
    self:run().send_range_line(pane)
  end
end

function Integs:send_enter()
  local pane = selected_pane_or_pick(self)
  if pane then
    self:run().send_enter(pane)
  end
end

---@param is_watcher? boolean
function Integs:select_target_panes(is_watcher)
  local opts = self:run().fzf_select_panes(is_watcher or false)
  if not opts then
    -- the backend returns plain nil when there is nothing to choose from
    Util.warn "No other pane to select (only one pane is open)"
    return
  end
  Picker.select_pane(Integs, opts)
end

---@param selected_pane? string
function Integs:send_signal_interrupt(selected_pane)
  selected_pane = selected_pane or Constant.get_selected_pane()

  if type(selected_pane) ~= "string" or selected_pane == "" then
    self:select_target_panes()
    return
  end

  self:run().send_interrupt(selected_pane)
end

function Integs:send_signal_interrupt_all()
  local runner = self:run()
  for _, pane_id in ipairs(active_pane_ids()) do
    runner.send_interrupt(pane_id)
  end
  Util.info "Sent interrupt to all panes"
end

function Integs:watcher()
  self:select_target_panes(true)
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        AUTOCMDS                          │
--  ╰──────────────────────────────────────────────────────────╯

function Integs:setup_augroup()
  if #Constant.get_active_tasks() > 0 then
    self:set_au_autokill()
  end
end

---@param name_augroup string
function Integs:unset_augroup(name_augroup)
  pcall(vim.api.nvim_del_augroup_by_name, name_augroup) -- also clears its autocmds
  Integs.augroups[name_augroup] = nil
end

function Integs:cleanup_augroup()
  if #Constant.get_active_tasks() > 0 then
    return
  end
  for name in pairs(vim.deepcopy(Integs.augroups)) do
    self:unset_augroup(name)
  end
end

function Integs:set_au_watcher()
  local name = Integs.prefix .. Integs.augroup_watcher
  self:unset_augroup(name) -- avoid duplicate augroup

  if not Constant.get_watcher_status() then
    return
  end

  Integs.augroups[name] = true
  local augroup = vim.api.nvim_create_augroup(name, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "*",
    group = augroup,
    callback = guarded(function()
      local selected_pane = Constant.get_selected_pane()
      if not self:run().is_pane_exists(selected_pane) then
        return
      end

      for _, task in ipairs(Constant.get_active_tasks()) do
        if task.pane_id == selected_pane then
          self:run_file(task.label, task.type_strategy, task.builder)
        end
      end
    end),
  })
end

function Integs:set_au_autokill()
  local name = Integs.prefix .. Integs.augroup_autokill
  Integs.augroups[name] = true

  local augroup = vim.api.nvim_create_augroup(name, { clear = true })
  vim.api.nvim_create_autocmd("ExitPre", {
    pattern = "*",
    group = augroup,
    callback = guarded(function()
      Integs:close_all_panes()
    end),
  })
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                       GREP / KILL                        │
--  ╰──────────────────────────────────────────────────────────╯

function Integs:find_err()
  local tbl_active_tasks = Constant.get_active_tasks()
  if #tbl_active_tasks == 0 then
    Util.warn "No task running"
    return
  end

  local selected_pane = Constant.get_selected_pane()
  if type(selected_pane) ~= "string" or selected_pane == "" then
    self:select_target_panes()
    return
  end

  local opts = { title = "Grep Error Pane " .. selected_pane }

  -- lazy: overseer is only needed here, not for loading the whole integration
  local has_pm, Problem_matcher = pcall(require, "overseer.vscode.problem_matcher")
  if has_pm then
    for _, task in ipairs(tbl_active_tasks) do
      local components = task.pane_id == selected_pane and task.builder and task.builder.components
      local first = components and components[1]
      if type(first) == "table" and first.problem_matcher then
        local pm = Problem_matcher.resolve_problem_matcher(first.problem_matcher)
        if pm then
          opts.regex = Problem_matcher.get_parser_from_problem_matcher(pm, {})
        end
      end
    end
  end

  -- TODO: resize the pane first when running in tmux; a narrow pane cannot be
  -- grabbed reliably (tmux resize-pane -x 80 / -y 20)

  local runner = self:run()
  Picker.grep_err(Integs, runner, runner.get_current_pane_id(), selected_pane, opts, true)
end

---@param pane_id string
function Integs:kill_pane(pane_id)
  self:run().kill_pane(pane_id)
  self:update_rmux(pane_id)
end

--- Runs synchronously because this is also invoked on `ExitPre`, where deferred
--- callbacks might never execute. Errors on individual panes are ignored so all
--- get closed.
---@param is_only_settings? boolean
function Integs:close_all_panes(is_only_settings)
  if not is_only_settings then
    local runner = self:run()
    for _, pane_id in ipairs(active_pane_ids()) do
      local ok, err = pcall(runner.kill_pane, pane_id)
      if not ok then
        Util.warn(tostring(err))
      end
    end
  end

  Constant.set_selected_pane ""
  Constant.set_watcher_status(false)
  Config.settings.active_tasks = {}
  self:cleanup_augroup()
end

return Integs
