local Constant = require "rmux.constant"
local Path = require "plenary.path"
local Selection = require "rmux.selection"
local Util = require "rmux.utils"

local TIMEOUT_MS = 3000
local PASTE_BUFFER = "rmux"
local size_pane = Constant.get_size_pane()

local M = {}

--  ╭──────────────────────────────────────────────────────────╮
--  │                         CORE                             │
--  ╰──────────────────────────────────────────────────────────╯

---@param args string[]
---@param stdin? string
---@return string|nil stdout, string|nil err
local function tmux(args, stdin)
  if not vim.env.TMUX then
    return nil, "not running inside tmux ($TMUX is not set)"
  end

  local cmd = vim.list_extend({ "tmux" }, args)
  local ok, proc = pcall(vim.system, cmd, { text = true, stdin = stdin })
  if not ok then
    return nil, "cannot execute tmux: " .. tostring(proc)
  end

  local wait_ok, res = pcall(proc.wait, proc, TIMEOUT_MS)
  if not wait_ok then
    return nil, "cannot wait for tmux: " .. tostring(res)
  end

  if res.code ~= 0 then
    local msg = vim.trim(res.stderr or "")
    if msg == "" then
      msg = "exit code " .. tostring(res.code)
    end
    return nil, ("tmux %s: %s"):format(args[1], msg)
  end

  return res.stdout or ""
end

--- Like tmux(), but only reports success (`true`) or `nil, err`.
---@return true|nil ok, string|nil err
local function run(args, stdin)
  local out, err = tmux(args, stdin)
  if not out then
    return nil, err
  end
  return true
end

---@param fmt string tmux format, e.g. "#{pane_id}"
---@param target? string|integer
---@return string|nil value, string|nil err
local function display(fmt, target)
  local args = { "display-message", "-p" }
  if target ~= nil then
    vim.list_extend(args, { "-t", tostring(target) })
  end
  args[#args + 1] = fmt

  local out, err = tmux(args)
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        QUERIES                           │
--  ╰──────────────────────────────────────────────────────────╯

---@return boolean|nil, string|nil
function M.is_pane_zoomed()
  local out, err = display "#{window_zoomed_flag}"
  if not out then
    return nil, err
  end
  return out == "1"
end

---@param pane_id? string default: the pane nvim runs in
---@return boolean|nil, string|nil
function M.is_pane_at_bottom(pane_id)
  local out, err = display("#{pane_at_bottom}", pane_id)
  if not out then
    return nil, err
  end
  return out == "1"
end

---@param program_name string
---@return boolean
function M.is_current_pane_program_name(program_name)
  local pane_id = M.get_current_pane_id()
  if not pane_id then
    return false
  end
  return display("#{pane_current_command}", pane_id) == program_name
end

---@param pane_id string
---@return boolean
function M.is_pane_exists(pane_id)
  if type(pane_id) ~= "string" or pane_id == "" then
    return false
  end
  -- tmux fails when the pane doesn't exist (nil -> false); treat a missing pane
  -- as expected, not an error.
  return display("#{pane_id}", pane_id) == pane_id
end

---@return string|nil, string|nil
function M.get_current_pane_id()
  local id = vim.env.TMUX_PANE
  if id and id ~= "" then
    return id
  end
  return display "#{pane_id}"
end

---@param pane_idx integer
---@return string|nil, string|nil
function M.get_pane_id_from_idx(pane_idx)
  return display("#{pane_id}", pane_idx)
end

---@param pane_id string
---@return integer|nil, string|nil
function M.get_pane_idx_from_id(pane_id)
  local out, err = display("#{pane_index}", pane_id)
  if not out then
    return nil, err
  end
  return tonumber(out)
end

---@return integer|nil, string|nil
function M.get_pane_width()
  local out, err = display "#{pane_width}"
  if not out then
    return nil, err
  end
  return tonumber(out)
end

---@return integer|nil, string|nil
function M.get_pane_height()
  local out, err = display "#{pane_height}"
  if not out then
    return nil, err
  end
  return tonumber(out)
end

---@param target string|integer pane id or index
---@return string|nil, string|nil
function M.get_pane_current_command(target)
  return display("#{pane_current_command}", target)
end

---@return string[]|nil, string|nil
function M.get_lists_pane_id_opened()
  local out, err = tmux { "list-panes", "-F", "#{pane_id}" }
  if not out then
    return nil, err
  end
  return vim.split(out, "\n", { plain = true, trimempty = true })
end

---@return integer|nil, string|nil
function M.get_total_active_panes()
  local ids, err = M.get_lists_pane_id_opened()
  if not ids then
    return nil, err
  end
  return #ids
end

---@param pane_id string
---@param num_history_lines? integer
---@return string[]
function M.cmd_str_capture_pane(pane_id, num_history_lines)
  num_history_lines = num_history_lines or 10000
  -- every argv element must be a string
  return { "tmux", "capture-pane", "-p", "-t", pane_id, "-S", tostring(-num_history_lines), "-e" }
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                       NAVIGATE                           │
--  ╰──────────────────────────────────────────────────────────╯

function M.set_pane_zoom()
  return run { "resize-pane", "-Z" }
end

function M.reset_size_pane()
  return run { "select-layout", "-E" }
end

---@param pane_id string
function M.jump_to_pane_id(pane_id)
  return run { "select-pane", "-t", pane_id }
end

function M.jump_to_last_pane()
  return run { "last-pane" }
end

function M.go_right_pane()
  return run { "select-pane", "-R" }
end

function M.go_left_pane()
  return run { "select-pane", "-L" }
end

function M.go_down_pane()
  return run { "select-pane", "-D" }
end

--- A pane that is already gone counts as killed (close-all must not fail on it).
---@param pane_id string
function M.kill_pane(pane_id)
  local ok, err = run { "kill-pane", "-t", pane_id }
  if not ok and err and err:find("can't find", 1, true) then
    return true
  end
  return ok, err
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                     CREATE PANES                         │
--  ╰──────────────────────────────────────────────────────────╯

---@param args string[]
---@return string|nil pane_id, string|nil err
local function split_window(args)
  local cmd = vim.list_extend({ "split-window", "-P", "-F", "#{pane_id}" }, args)
  local out, err = tmux(cmd)
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

---@param cwd? string
---@param is_expand_pane? boolean
---@return string|nil pane_id, string|nil err
function M.create_new_pane(cwd, is_expand_pane)
  cwd = cwd or vim.fn.getcwd()

  local flag, set_expand = "-v", false

  if is_expand_pane then
    local at_bottom, berr = M.is_pane_at_bottom()
    if at_bottom == nil then
      return nil, berr
    end

    if not at_bottom then
      -- program of the pane we are about to jump to (asked BEFORE jumping)
      local last_cmd = display("#{pane_current_command}", "{last}")

      local ok, jerr = M.jump_to_last_pane()
      if not ok then
        return nil, jerr
      end

      if last_cmd == "yazi" then
        M.jump_to_last_pane()
        M.go_down_pane()
      end

      flag, set_expand = "-h", true
    end
  end

  local pane_id, err = split_window { flag, "-l", tostring(size_pane), "-c", cwd }
  if not pane_id then
    return nil, err
  end

  if set_expand and M.is_pane_at_bottom(pane_id) then
    M.reset_size_pane()
  end

  Constant.set_sendID(pane_id)
  return pane_id
end

---@param pane_strategy "-v" | "-h"
---@param size integer
---@return string|nil pane_id, string|nil err
function M.open_vertical_pane(pane_strategy, size)
  local args = { pane_strategy }
  if pane_strategy == "-v" then
    vim.list_extend(args, { "-l", tostring(size) })
  end
  return split_window(args)
end

---@param task_tbl_panes table
---@param lang_task table
function M.update_keys_task(task_tbl_panes, lang_task)
  task_tbl_panes.builder = lang_task.builder {}
  task_tbl_panes.name = lang_task.name
  task_tbl_panes.pane_id = Constant.get_sendID()

  if not M.is_pane_exists(task_tbl_panes.pane_id) then
    M.go_right_pane()
  end
  M.go_left_pane()
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                    GREP ERROR OUTPUT                     │
--  ╰──────────────────────────────────────────────────────────╯

---@param current_pane string
---@param target_pane string
---@param opts table
---@return table[]|nil results, string|nil err
function M.grep_err_output_commands(current_pane, target_pane, opts)
  local grep_cmd = opts.grep_cmd
  local regex = opts.regex
  local num_history_lines = opts.num_history_lines or 10000

  if target_pane == current_pane then
    return nil, "Grep err output cancelled: target pane is the current pane"
  end

  local pane_path = display("#{pane_current_path}", target_pane) or ""

  ---@type string[]
  local lines

  if type(regex) == "string" then
    if not grep_cmd then
      return nil, "Grep err output: 'grep_cmd' is required when the regex is a string"
    end

    local pipeline = ("tmux capture-pane -p -t %s -S %d | %s %s | tr -d ' '"):format(
      vim.fn.shellescape(target_pane),
      -num_history_lines,
      grep_cmd,
      vim.fn.shellescape(regex)
    )
    local ok, proc = pcall(vim.system, { "sh", "-c", pipeline }, { text = true })
    if not ok then
      return nil, "Grep err output: " .. tostring(proc)
    end
    local res = proc:wait(TIMEOUT_MS)
    if res.code ~= 0 then
      return nil, "Grep err output failed: " .. vim.trim(res.stderr or "")
    end
    lines = vim.split(res.stdout or "", "\n", { plain = true, trimempty = true })
  else
    local out, err = tmux { "capture-pane", "-p", "-t", target_pane, "-S", tostring(-num_history_lines) }
    if not out then
      return nil, err
    end
    lines = vim.split(out, "\n", { plain = true, trimempty = true })
  end

  if #lines == 0 then
    return nil, "Grep err output: nothing found in pane " .. target_pane
  end

  local results, seen = {}, {}

  local function add(pathx, lnum, cnum, text)
    if not pathx or pathx == "" then
      return
    end

    local path = Path:new(pathx)
    if not path:is_absolute() then
      path = Path:new(pane_path, path)
    end
    if not path:is_file() then
      return
    end

    local norm = path:normalize()
    local key = norm .. ":" .. (lnum or "") .. ":" .. (cnum or "")
    if seen[key] then
      return
    end
    seen[key] = true
    results[#results + 1] = { path = norm, lnum = lnum, cnum = cnum, text = text }
  end

  for _, line in ipairs(lines) do
    if type(regex) == "table" then
      regex:parse(line)
      local p = regex:get_result()
      if p and p.diagnostics then
        for _, diag in ipairs(p.diagnostics) do
          add(diag.filename, diag.lnum or 0, diag.col or 0, diag.text)
        end
      end
    else
      local parts = {}
      for part in line:gmatch "[^:]+" do
        parts[#parts + 1] = part
      end
      add(parts[1], parts[2], parts[3])
    end
  end

  return results
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                    SELECT TARGET PANE                    │
--  ╰──────────────────────────────────────────────────────────╯

---@param is_watcher? boolean
---@return table|nil opts, string|nil err  -- (nil) alone: no other pane to choose from
function M.fzf_select_panes(is_watcher)
  local out, err = tmux { "list-panes", "-F", "#{pane_id} #{pane_index}" }
  if not out then
    return nil, err
  end

  local cur_pane_id = M.get_current_pane_id()

  local task_by_pane = {}
  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    task_by_pane[task.pane_id] = task -- last one wins, like before
  end

  local results, sorted = {}, {}
  for _, line in ipairs(vim.split(out, "\n", { plain = true, trimempty = true })) do
    local id, idx = line:match "^(%S+)%s+(%d+)$"
    if id and id ~= cur_pane_id then
      local task = task_by_pane[id]
      local entry = { pane_id = id, pane_idx = tonumber(idx), builder = task and task.builder }
      results[id] = entry
      sorted[#sorted + 1] = entry
    end
  end

  if #sorted == 0 then
    return nil
  end

  -- Tasks in the select pane follow tmux's index
  table.sort(sorted, function(a, b)
    return a.pane_idx < b.pane_idx
  end)

  local items = {}
  for _, entry in ipairs(sorted) do
    items[#items + 1] = entry.pane_id .. "  " .. ((entry.builder and entry.builder.name) or "")
  end

  return { results = results, is_watcher = is_watcher or false, select_pane_fzf = items }
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                          SEND                            │
--  ╰──────────────────────────────────────────────────────────╯

---@param pane? string
---@return string|nil pane, string|nil err
local function resolve_target(pane)
  pane = pane or Constant.get_sendID()
  if type(pane) ~= "string" or pane == "" then
    return nil, "no target pane selected"
  end
  return pane
end

--- Paste text through a tmux buffer. Text goes over stdin: no `echo '...'`,
--- so quotes, backslashes and newlines in the code are sent untouched.
---@param pane string
---@param text string|string[]
function M.paste(pane, text)
  local content = text
  if type(text) == "table" then
    content = table.concat(Util.list_strip_empty_lines(text), "\n")
  end
  content = content .. "\n"

  local ok, err = run({ "load-buffer", "-b", PASTE_BUFFER, "-" }, content)
  if not ok then
    return nil, err
  end
  return run { "paste-buffer", "-b", PASTE_BUFFER, "-dpr", "-t", pane }
end

---@param pane string
---@param ... string tmux key names, e.g. "C-c", "Enter"
function M.send_keys(pane, ...)
  return run(vim.list_extend({ "send-keys", "-t", pane }, { ... }))
end

---@param pane string
---@param cmd string
---@param is_clear_screen? boolean
function M.run_in_pane(pane, cmd, is_clear_screen)
  if is_clear_screen then
    local ok, err = run { "send-keys", "-t", pane, "-l", "--", "clear" }
    if not ok then
      return nil, err
    end
    ok, err = M.send_keys(pane, "Enter")
    if not ok then
      return nil, err
    end
  end

  local ok, err = run { "send-keys", "-t", pane, "-l", "--", cmd }
  if not ok then
    return nil, err
  end
  return M.send_keys(pane, "Enter")
end

---@param task RmuxActiveTasks
---@param is_clear_screen? boolean
function M.send_pane_cmd_task(task, is_clear_screen)
  local cmd = task.builder and task.builder.cmd
  if type(cmd) == "table" then
    cmd = table.concat(cmd, " ")
  end
  if type(cmd) ~= "string" or cmd == "" then
    return nil, "Task cmd is empty!"
  end

  local pane, err = resolve_target(task.pane_id)
  if not pane then
    return nil, err
  end

  return M.run_in_pane(pane, cmd, is_clear_screen)
end

---@param target_pane? string
function M.send_interrupt(target_pane)
  local pane, err = resolve_target(target_pane)
  if not pane then
    return nil, err
  end
  return M.send_keys(pane, "C-c")
end

---@param target_pane? string
function M.send_enter(target_pane)
  local pane, err = resolve_target(target_pane)
  if not pane then
    return nil, err
  end
  return M.send_keys(pane, "Enter")
end

---@param target_pane? string
function M.send_line(target_pane)
  local pane, err = resolve_target(target_pane)
  if not pane then
    return nil, err
  end
  return M.paste(pane, vim.api.nvim_get_current_line())
end

---@param target_pane? string
function M.send_range_line(target_pane)
  local pane, perr = resolve_target(target_pane)
  if not pane then
    return nil, perr
  end

  local lines, err = Selection.get_lines()
  if not lines then
    return nil, err
  end
  return M.paste(pane, lines)
end

return M
