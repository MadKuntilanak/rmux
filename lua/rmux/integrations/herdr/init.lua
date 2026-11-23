local Constant = require "rmux.constant"
local Path = require "plenary.path"
local Selection = require "rmux.selection"
local Util = require "rmux.utils"

local TIMEOUT_MS = 3000

local SPLIT_RATIO = nil

local LUANIL = { luanil = { object = true, array = true } }

local M = {}

---@type string|nil
local last_opened

--  ╭──────────────────────────────────────────────────────────╮
--  │                         CORE                             │
--  ╰──────────────────────────────────────────────────────────╯

--- HERDR_BIN_PATH is the binary that owns this pane (same version as the server).
local function binary()
  local bin = vim.env.HERDR_BIN_PATH
  if bin and bin ~= "" then
    return bin
  end
  return "herdr"
end

---@param args string[]
---@param res vim.SystemCompleted
---@return string
local function format_error(args, res)
  local raw = vim.trim(res.stderr or "")
  local msg = raw

  local ok, data = pcall(vim.json.decode, raw, LUANIL)
  if ok and type(data) == "table" then
    local e = type(data.error) == "table" and data.error or data
    if type(e.message) == "string" then
      msg = (type(e.code) == "string" and (e.code .. ": ") or "") .. e.message
    end
  end

  if msg == "" then
    msg = "exit code " .. tostring(res.code)
  end
  msg = msg:match "[^\n]+" or msg -- first line only

  return ("herdr %s: %s"):format(table.concat(args, " ", 1, math.min(#args, 2)), msg)
end

---@param args string[]
---@return string|nil stdout, string|nil err
local function herdr(args)
  if vim.env.HERDR_ENV ~= "1" then
    return nil, "not running inside herdr (HERDR_ENV is not set to 1)"
  end

  local cmd = vim.list_extend({ binary() }, args)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil, "cannot execute herdr: " .. tostring(proc)
  end

  local wait_ok, res = pcall(proc.wait, proc, TIMEOUT_MS)
  if not wait_ok then
    return nil, "cannot wait for herdr: " .. tostring(res)
  end

  if res.code ~= 0 then
    return nil, format_error(args, res)
  end

  return res.stdout or ""
end

---@return true|nil ok, string|nil err
local function run(args)
  local out, err = herdr(args)
  if not out then
    return nil, err
  end
  return true
end

---@param args string[]
---@return table|nil result, string|nil err
local function request(args)
  local out, err = herdr(args)
  if not out then
    return nil, err
  end

  local ok, data = pcall(vim.json.decode, out, LUANIL)
  if not ok or type(data) ~= "table" then
    return nil, ("herdr %s: output is not valid JSON"):format(args[1])
  end

  return data.result or data
end

---@param base string[]
---@param text string
---@return string[]
local function with_text(base, text)
  if text:sub(1, 1) == "-" then
    base[#base + 1] = "--"
  end
  base[#base + 1] = text
  return base
end

---@param pane_id string
---@return integer|nil
local function pane_number(pane_id)
  return tonumber(tostring(pane_id):match ":p(%d+)$")
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        QUERIES                           │
--  ╰──────────────────────────────────────────────────────────╯

---@return string|nil, string|nil
function M.get_current_pane_id()
  local id = vim.env.HERDR_PANE_ID
  if id and id ~= "" then
    return id
  end

  local result, err = request { "pane", "current" } -- focused pane as a fallback
  if not result then
    return nil, err
  end
  return result.pane and result.pane.pane_id
end

---@param pane_id string
---@return boolean
function M.is_pane_exists(pane_id)
  if type(pane_id) ~= "string" or pane_id == "" then
    return false
  end
  -- an unknown pane makes herdr fail (not_found) -> false. "Gone" is an answer, not an error.
  return herdr { "pane", "get", pane_id } ~= nil
end

---@param pane_id string
---@return integer|nil
function M.get_pane_idx_from_id(pane_id)
  return pane_number(pane_id)
end

--- Panes of the current workspace (one call).
---@return table[]|nil panes, string|nil err
local function list_panes()
  local args = { "pane", "list" }
  local workspace = vim.env.HERDR_WORKSPACE_ID
  if workspace and workspace ~= "" then
    vim.list_extend(args, { "--workspace", workspace })
  end

  local result, err = request(args)
  if not result then
    return nil, err
  end

  local panes = {}
  for _, pane in ipairs(result.panes or {}) do
    if pane.pane_id then
      panes[#panes + 1] = pane
    end
  end
  return panes
end

---@return string[]|nil, string|nil
function M.get_lists_pane_id_opened()
  local panes, err = list_panes()
  if not panes then
    return nil, err
  end

  local ids = {}
  for _, pane in ipairs(panes) do
    ids[#ids + 1] = pane.pane_id
  end
  return ids
end

---@return integer|nil, string|nil
function M.get_total_active_panes()
  local ids, err = M.get_lists_pane_id_opened()
  if not ids then
    return nil, err
  end
  return #ids
end

--- argv for a previewer (same role as the tmux capture-pane command).
---@param pane_id string
---@param num_history_lines? integer
---@return string[]
function M.cmd_str_capture_pane(pane_id, num_history_lines)
  return {
    binary(),
    "pane",
    "read",
    pane_id,
    "--source",
    "recent-unwrapped",
    "--lines",
    tostring(num_history_lines or 10000),
    "--ansi",
  }
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                       NAVIGATE                           │
--  ╰──────────────────────────────────────────────────────────╯

---@param _ string
function M.jump_to_pane_id(_)
  return true
end

function M.reset_size_pane()
  return true
end

function M.set_pane_zoom()
  return run { "pane", "zoom", "--toggle", "--current" }
end

---@param direction "left"|"right"|"up"|"down"
local function focus(direction)
  return run { "pane", "focus", "--direction", direction, "--current" }
end

function M.go_left_pane()
  return focus "left"
end

function M.go_right_pane()
  return focus "right"
end

function M.go_down_pane()
  return focus "down"
end

function M.go_up_pane()
  return focus "up"
end

---@param pane_id string
function M.kill_pane(pane_id)
  local ok, err = run { "pane", "close", pane_id }
  if not ok and err and (err:find("not_found", 1, true) or err:find("not found", 1, true)) then
    ok = true
  end

  if not ok then
    return nil, err
  end

  if last_opened == pane_id then
    last_opened = nil
  end
  return true
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                     CREATE PANES                         │
--  ╰──────────────────────────────────────────────────────────╯

---@param target string pane to split
---@param direction "right"|"down"
---@param cwd? string
---@return string|nil pane_id, string|nil err
local function split(target, direction, cwd)
  local args = { "pane", "split", target, "--direction", direction, "--no-focus" }
  if cwd then
    vim.list_extend(args, { "--cwd", cwd })
  end
  if SPLIT_RATIO then
    vim.list_extend(args, { "--ratio", tostring(SPLIT_RATIO) })
  end

  local result, err = request(args)
  if not result then
    return nil, err
  end

  local pane_id = result.pane and result.pane.pane_id
  if not pane_id then
    return nil, "herdr pane split: response has no pane id"
  end

  last_opened = pane_id
  return pane_id
end

---@param cwd? string
---@param is_expand_pane? boolean
---@return string|nil pane_id, string|nil err
function M.create_new_pane(cwd, is_expand_pane)
  local current, cerr = M.get_current_pane_id()
  if not current then
    return nil, cerr
  end

  local target, direction = current, "down"
  if is_expand_pane and last_opened and last_opened ~= current and M.is_pane_exists(last_opened) then
    target, direction = last_opened, "right"
  end

  local pane_id, err = split(target, direction, cwd or vim.fn.getcwd())
  if not pane_id then
    return nil, err
  end

  Constant.set_sendID(pane_id)
  return pane_id
end

---@param pane_strategy "-v" | "-h"
---@param _ integer
---@return string|nil pane_id, string|nil err
function M.open_vertical_pane(pane_strategy, _)
  local current, cerr = M.get_current_pane_id()
  if not current then
    return nil, cerr
  end

  if pane_strategy == "-h" then
    local target = current
    if last_opened and M.is_pane_exists(last_opened) then
      target = last_opened
    end
    return split(target, "right")
  end

  return split(current, "down")
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

  local info = request { "pane", "get", target_pane }
  local pane_path = info and info.pane and (info.pane.foreground_cwd or info.pane.cwd) or ""

  ---@type string[]
  local lines

  if type(regex) == "string" then
    if not grep_cmd then
      return nil, "Grep err output: 'grep_cmd' is required when the regex is a string"
    end

    -- grep_cmd is a user-configured command line, so this one stays a shell
    -- pipeline, but every dynamic part is escaped.
    local pipeline = ("%s pane read %s --source recent-unwrapped --lines %d | %s %s | tr -d ' '"):format(
      vim.fn.shellescape(binary()),
      vim.fn.shellescape(target_pane),
      num_history_lines,
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
    -- `pane read` prints the text directly. recent-unwrapped ignores soft
    -- wrapping, so a "file:line:col" that was wrapped by a narrow pane is
    -- still on one line (the old TODO about resizing the pane).
    local out, err = herdr {
      "pane",
      "read",
      target_pane,
      "--source",
      "recent-unwrapped",
      "--lines",
      tostring(num_history_lines),
    }
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
  local panes, err = list_panes()
  if not panes then
    return nil, err
  end

  local current = M.get_current_pane_id()

  local task_by_pane = {}
  for _, task in ipairs(Constant.get_active_tasks() or {}) do
    task_by_pane[task.pane_id] = task -- last one wins
  end

  local results, sorted = {}, {}
  for _, pane in ipairs(panes) do
    local id = pane.pane_id
    if id ~= current then
      local task = task_by_pane[id]
      local entry = { pane_id = id, pane_idx = pane_number(id) or 0, builder = task and task.builder }
      results[id] = entry
      sorted[#sorted + 1] = entry
    end
  end

  if #sorted == 0 then
    return nil
  end

  table.sort(sorted, function(a, b)
    if a.pane_idx ~= b.pane_idx then
      return a.pane_idx < b.pane_idx
    end
    return a.pane_id < b.pane_id
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

--- Types text into the pane without pressing Enter.
--- Unlike the tmux backend, this doesn't use bracketed paste or append a trailing
--- newline; multi-line input is sent line by line.
---@param pane string
---@param text string|string[]
function M.paste(pane, text)
  if type(text) == "table" then
    text = table.concat(Util.list_strip_empty_lines(text), "\n")
  end
  if text == "" then
    return true
  end
  return run(with_text({ "pane", "send-text", pane }, text))
end

---@param pane string
---@param ... string herdr key names, e.g. "ctrl+c", "enter"
function M.send_keys(pane, ...)
  return run(vim.list_extend({ "pane", "send-keys", pane }, { ... }))
end

---@param pane string
---@param cmd string
---@param is_clear_screen? boolean
function M.run_in_pane(pane, cmd, is_clear_screen)
  if is_clear_screen then
    local ok, err = run { "pane", "run", pane, "clear" }
    if not ok then
      return nil, err
    end
  end
  return run(with_text({ "pane", "run", pane }, cmd))
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
  return M.send_keys(pane, "ctrl+c")
end

---@param target_pane? string
function M.send_enter(target_pane)
  local pane, err = resolve_target(target_pane)
  if not pane then
    return nil, err
  end
  return M.send_keys(pane, "enter")
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
