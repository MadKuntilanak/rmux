local Config = require "rmux.config"
local Constant = require "rmux.constant"
local Util = require "rmux.utils"
local Picker = require "rmux.picker"
local Problem_matcher = require "overseer.vscode.problem_matcher"

-- local is_not_run_overseer = function()
--   return not vim.tbl_contains(Config.settings.run_with, Config.settings.base.run_with)
-- end

---@param label_name string
---@param type_strategy RmuxTypeStrategy
---@param func function
local loop_panes = function(label_name, type_strategy, func)
  local tasks = Constant.get_active_tasks()
  if #tasks > 0 then
    if type_strategy == "orchestrator" or type_strategy == "close_all" then
      for _, task in pairs(tasks) do
        vim.schedule(function()
          func(task)
        end)
      end
    end

    if type_strategy == "sequential" then
      local new_task = {}
      local cmd_sequences = {}

      for _, task in pairs(tasks) do
        if task.type_strategy == "sequential" then
          if not new_task.builder then
            new_task.builder = {}
          end

          cmd_sequences[#cmd_sequences + 1] = task.builder.cmd

          new_task.label = label_name
          new_task.pane_id = task.pane_id
          new_task.pane_idx = task.pane_idx
          new_task.type_strategy = task.type_strategy

          new_task.builder.name = label_name
          new_task.builder.components = { "default_vscode" }
        end
      end

      new_task.builder.cmd = table.concat(cmd_sequences, " && ")

      Constant.insert_active_tasks {
        pane_id = new_task.pane_id,
        pane_idx = new_task.pane_idx,
        label = new_task.label,
        builder = new_task.builder,
        type_strategy = new_task.type_strategy,
      }

      func(new_task.builder)
    end
  end
end

local Integs = {
  prefix = "Rmux",
  augroup_watcher = "Watcher",
  augroup_autokill = "AutoKill",
}

Integs.__index = Integs

function Integs:run()
  return require("rmux.integrations." .. Config.settings.run_with)
end

---@param main_pane_id string
function Integs:__jump_to_main_pane(main_pane_id)
  self:run().jump_to_pane_id(main_pane_id)
end

---@param label_name string
---@param type_strategy string
---@param cur_pane_id string
---@param is_respawn_pane boolean
---@param builder_task? RmuxBuilderTasks
function Integs:spawn_pane(label_name, type_strategy, cur_pane_id, is_respawn_pane, builder_task)
  builder_task = builder_task or {}

  if is_respawn_pane then
    self:_respawn_pane()
  end

  local sendID = Constant.get_sendID()
  local pane_id = sendID
  local pane_idx = self:run().get_pane_idx_from_id(pane_id)

  if cur_pane_id == pane_id then
    Util.error "Run file aborted: 'cur_pane_id' and 'pane_id' cannot have the same value."
    return
  end

  Constant.insert_active_tasks {
    pane_id = pane_id,
    pane_idx = pane_idx,
    label = label_name,
    builder = builder_task,
    type_strategy = type_strategy,
  }

  Constant.set_selected_pane(pane_id)

  local is_clear_sceen = true

  self:send_command_to_pane(cur_pane_id, type_strategy, label_name, Constant.get_active_tasks(), is_clear_sceen)
end

---@param main_pane_id string
---@param type_strategy string
---@param label_name string
---@param tbl_tasks RmuxActiveTasks[]
---@param is_clear_sceen? boolean
function Integs:send_command_to_pane(main_pane_id, type_strategy, label_name, tbl_tasks, is_clear_sceen)
  is_clear_sceen = is_clear_sceen or false

  for _, task in pairs(tbl_tasks) do
    if task.type_strategy == type_strategy then
      if task.label == label_name then
        self:run().send_pane_cmd_task(task, is_clear_sceen)
      end
    end
  end

  self:__jump_to_main_pane(main_pane_id)
end

---@param pane_id? string
function Integs:update_rmux(pane_id)
  pane_id = pane_id or ""

  local statusline_status = Constant.get_statusline_status()
  if statusline_status and not statusline_status then
    return
  end

  if pane_id and #pane_id > 0 then
    if not self:run().is_pane_exists(pane_id) then
      Constant.remove_from_active_tasks(pane_id)
    end
  end

  local selected_pane = Constant.get_selected_pane()

  if selected_pane and #selected_pane > 0 then
    if not self:run().is_pane_exists(selected_pane) then
      Constant.set_selected_pane ""
      Constant.remove_from_active_tasks(selected_pane)
    end
  end

  local tbl_active_tasks = Constant.get_active_tasks()
  if tbl_active_tasks and #tbl_active_tasks > 0 then
    for _, task in pairs(tbl_active_tasks) do
      if not self:run().is_pane_exists(task.pane_id) then
        Constant.remove_from_active_tasks(task.pane_id)
      end
    end
  end
end

---@param label_name string
---@param type_strategy RmuxTypeStrategy
---@param active_tasks table
function Integs:is_task_active(label_name, type_strategy, active_tasks)
  local runner = self:run()
  for _, t in ipairs(active_tasks) do
    if t.label == label_name and t.type_strategy == type_strategy then
      for _, open_id in ipairs(runner.get_lists_pane_id_opened()) do
        if t.pane_id == open_id then
          return true
        end
      end
    end
  end
  return false
end

---@param label_name string
---@param type_strategy RmuxTypeStrategy
---@param builder_task RmuxBuilderTasks|nil
function Integs:run_file(label_name, type_strategy, builder_task)
  local runner = self:run()
  local main_pane_id = runner.get_current_pane_id()

  self:update_rmux()

  local active_tasks = Constant.get_active_tasks()

  -- Check if it hasn't spawned yet, then send the command to its pane
  if #active_tasks == 0 then
    self:spawn_pane(label_name, type_strategy, main_pane_id, true, builder_task)
    return
  end

  -- Check if the current task is active
  local found = self:is_task_active(label_name, type_strategy, active_tasks)

  if not found then
    self:spawn_pane(label_name, type_strategy, main_pane_id, true, builder_task)
  else
    -- Ensure the prompt is canceled before sending commands
    for _, task in pairs(active_tasks) do
      if task.type_strategy == type_strategy then
        if task.label == label_name then
          self:send_signal_interrupt(task.pane_id)
        end
      end
    end

    local is_clear_sceen = true
    self:send_command_to_pane(main_pane_id, type_strategy, label_name, active_tasks, is_clear_sceen)
  end
end

function Integs:setup_augroup()
  local tbl_active_tasks = Constant.get_active_tasks()

  if #tbl_active_tasks > 0 then
    self:set_au_autokill()
  end
end

function Integs:cleanup_augroup()
  local tbl_active_tasks = Constant.get_active_tasks()

  if #tbl_active_tasks == 0 then
    if Integs.augroups and #Integs.augroups > 0 then
      for _, augroup_name in pairs(Integs.augroups) do
        self:unset_augroup(augroup_name)
      end
    end
  end
end

---@param label_name string
---@param list_tasks table
---@param type_strategy RmuxTypeStrategy
function Integs:run_all(label_name, list_tasks, type_strategy)
  local cur_pane_id = self:run().get_current_pane_id()

  local active_tasks = Constant.get_active_tasks()
  if active_tasks and #active_tasks > 0 and type_strategy == "sequential" then
    if self:is_task_active(label_name, type_strategy, active_tasks) then
      local is_clear_sceen = true
      self:send_command_to_pane(cur_pane_id, type_strategy, label_name, active_tasks, is_clear_sceen)
      return
    end
  end

  local pane_strategy = "-v"
  local is_run_once = false

  local pane_id, pane_idx, builder, label_name_task

  for i, lang_task in pairs(Constant.get_load_tasks()) do
    local lang_task_name = lang_task.builder({}).name
    for _, task in pairs(list_tasks) do
      if lang_task_name == task then
        local pane_size = math.floor((self:run().get_pane_width() / i) + 70)

        if pane_strategy == "-v" then
          pane_size = 15
        end

        if not is_run_once then
          pane_id = self:run().open_vertical_pane(pane_strategy, pane_size)
          pane_idx = self:run().get_pane_idx_from_id(pane_id)
          if type_strategy == "sequential" then
            is_run_once = true
          end
        end

        builder = lang_task.builder {}
        label_name_task = lang_task.builder({}).name

        if pane_strategy == "-v" then
          pane_strategy = "-h"
        end

        Constant.insert_active_tasks {
          pane_id = pane_id,
          pane_idx = pane_idx,
          label = label_name_task,
          builder = builder,
          type_strategy = type_strategy,
        }
      end
    end
  end

  self:run().reset_size_pane()
  self:run().jump_to_pane_id(cur_pane_id)

  loop_panes(label_name, type_strategy, function(t)
    local task = t

    if type_strategy == "orchestrator" then
      if task.type_strategy == type_strategy then
        local is_clear_sceen = true
        self:run().send_pane_cmd_task(task, is_clear_sceen)
        self:run().jump_to_pane_id(cur_pane_id)
      end
    end
    if type_strategy == "sequential" then
      self:run_file(label_name, type_strategy, task)
    end
  end)
end

---@param label_name string
function Integs:generator_cmd_panes(label_name)
  local load_tasks = Constant.get_load_tasks()

  if #load_tasks == 0 then
    return
  end

  for _, lang_task in pairs(load_tasks) do
    if lang_task.name == label_name then
      local builder = lang_task.builder {} -- call builder only once

      -- type with: dependsOn("task 1", "task 2"), dependsOn
      if builder.components and #builder.components > 1 then
        if builder.components[2][1] == "dependencies" and #builder.components[2].tasks > 0 then
          local type_strategy = "orchestrator"
          if builder.components[2].sequential then
            type_strategy = "sequential"
          end
          self:run_all(label_name, builder.components[2].tasks, type_strategy)
        end
      end

      -- type: process
      if type(builder.cmd) == "table" then
        self:run_file(label_name, "process", builder)
      end

      -- type: shell
      if type(builder.cmd) == "string" then
        self:run_file(label_name, "shell", builder)
      end
    end
  end

  self:setup_augroup()
end

---@param is_expand_pane? boolean
function Integs:_respawn_pane(is_expand_pane)
  is_expand_pane = is_expand_pane or false

  local total_panes = self:run().get_total_active_panes()
  local cwd = vim.fn.getcwd()

  if total_panes == 1 then
    self:run().create_new_pane(cwd, false)
  else
    self:run().create_new_pane(cwd, true)
  end
end

function Integs:send_line()
  local selected_pane = Constant.get_selected_pane()
  if not selected_pane or (#selected_pane == 0) then
    Integs:select_target_panes()
    return
  end
  self:run().send_line(selected_pane)
end

function Integs:send_line_range()
  local selected_pane = Constant.get_selected_pane()
  if not selected_pane or (#selected_pane == 0) then
    Integs:select_target_panes()
    return
  end
  self:run().send_range_line(selected_pane)
end

function Integs:send_enter()
  local selected_pane = Constant.get_selected_pane()
  if not selected_pane or (#selected_pane == 0) then
    Integs:select_target_panes()
    return
  end
  self:run().send_enter(selected_pane)
end

---@param is_watcher? boolean
function Integs:select_target_panes(is_watcher)
  is_watcher = is_watcher or false

  local opts = self:run().fzf_select_panes(is_watcher)
  if opts then
    Picker.select_pane(Integs, opts)
  end
end

function Integs:send_cmd() -- pengganti openREPL
  print "open send cmd"
end

function Integs:send_signal_interrupt(selected_pane)
  selected_pane = selected_pane or Constant.get_selected_pane()

  if not selected_pane or (#selected_pane == 0) then
    Integs:select_target_panes()
    return
  end

  self:run().send_interrupt(selected_pane)
end

function Integs:send_signal_interrupt_all()
  loop_panes("", "close_all", function(pane)
    self:run().send_interrupt(pane.pane_id)
  end)

  Util.info "Sent interrupt to all panes"
end

function Integs:watcher()
  self:select_target_panes(true)
end

---@param name_augroup string
function Integs:unset_augroup(name_augroup)
  pcall(vim.api.nvim_clear_autocmds, { group = name_augroup })
  pcall(vim.api.nvim_del_augroup_by_name, name_augroup)
end

function Integs:set_au_watcher()
  local augroup_watcher = Integs.prefix .. Integs.augroup_watcher
  Integs:unset_augroup(augroup_watcher) -- avoid duplicate augroup
  if not Integs.augroups then
    Integs.augroups = {}
  end
  table.insert(Integs.augroups, augroup_watcher)

  local status_watcher = Constant.get_watcher_status()

  if status_watcher then
    local augroup = vim.api.nvim_create_augroup(augroup_watcher, { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      pattern = "*",
      group = augroup,
      callback = function()
        local selected_pane = Constant.get_selected_pane()

        if self:run().is_pane_exists(selected_pane) then
          local tbl_active_tasks = Constant.get_active_tasks()

          for _, task in pairs(tbl_active_tasks) do
            if task.pane_id == selected_pane then
              self:run_file(task.label, task.type_strategy, task.builder)
            end
          end
        end
      end,
    })
  end
end

function Integs:set_au_autokill()
  local augroup_autokill = Integs.prefix .. Integs.augroup_autokill
  Integs:unset_augroup(augroup_autokill)
  if not Integs.augroups then
    Integs.augroups = {}
  end
  table.insert(Integs.augroups, augroup_autokill)

  local augroup = vim.api.nvim_create_augroup(augroup_autokill, { clear = true })
  vim.api.nvim_create_autocmd("ExitPre", {
    pattern = "*",
    group = augroup,
    callback = function()
      Integs:close_all_panes()
    end,
  })
end

function Integs:find_err()
  local tbl_active_tasks = Constant.get_active_tasks()
  if #tbl_active_tasks == 0 then
    Util.warn "No task running"
    return
  end

  local opts = { title = "Grep Error" }
  local cur_pane_id = self:run().get_current_pane_id()

  local selected_pane = Constant.get_selected_pane()
  if not selected_pane or (#selected_pane == 0) then
    Integs:select_target_panes()
    return
  end

  -- if #selected_pane > 0 then
  -- 	target_panes = selected_pane
  -- else
  -- 	for _, task in pairs(tbl_active_tasks) do
  -- 		if task.pane_id then
  -- 			if target_panes[task.pane_id] ~= nil then
  -- 				target_panes[#target_panes + 1] = task.pane_id
  -- 			end
  -- 		end
  -- 	end
  -- end

  for _, task in pairs(tbl_active_tasks) do
    if task.pane_id and task.pane_id == selected_pane then
      local pm = Problem_matcher.resolve_problem_matcher(task.builder.components[1].problem_matcher)
      if pm then
        opts.regex = Problem_matcher.get_parser_from_problem_matcher(pm, {})
      end
    end
  end

  -- TODO: resize pane dahulu jika berjalan di tmux, karena pane width kecil ga bisa di grab secara optimal
  -- > get size pane
  -- tmux display -p "#{pane_width}x#{pane_height}"
  -- > Ubah tinggi pane jadi 20 baris
  -- tmux resize-pane -y 20
  -- > Ubah lebar pane jadi 80 kolom
  -- tmux resize-pane -x 80

  -- if #target_panes == 1 then
  opts.title = opts.title .. " Pane " .. selected_pane
  -- else
  -- 	opts.title = opts.title .. " Panes [ " .. table.concat(target_panes, " ") .. " ]"
  -- end

  -- local is_overseer = is_not_run_overseer()
  local is_overseer = true

  Picker.grep_err(Integs, Integs.run(self), cur_pane_id, selected_pane, opts, is_overseer)
end

---@param pane_id string
function Integs:kill_pane(pane_id)
  self:run().kill_pane(pane_id)
  self:update_rmux(pane_id)
end

---@param is_only_settings? boolean
function Integs:close_all_panes(is_only_settings)
  is_only_settings = is_only_settings or false

  if self:run() == "default" then
    vim.cmd.OverseerToggle()
    return
  end

  if not is_only_settings then
    loop_panes("", "close_all", function(pane)
      self:run().kill_pane(pane.pane_id)
    end)
  end

  Constant.set_selected_pane ""
  Constant.set_watcher_status(false)
  Config.settings.active_tasks = {}
  self:cleanup_augroup()
end

return Integs
