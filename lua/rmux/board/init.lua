local Config = require "rmux.config"
local Constant = require "rmux.constant"
local History = require "rmux.board.history"
local State = require "rmux.board.state"
local Util = require "rmux.utils"

local M = {}

local NS = vim.api.nvim_create_namespace "rmux_board"
local unpack = table.unpack or unpack

-- override with require("rmux").setup { board = { ... } }
local DEFAULTS = { recent = 6, refresh_ms = 1000, width = 84 }

M.popup = {
  main = { win = nil, buf = nil },
  footer = { win = nil, buf = nil },
}

M.timer = nil ---@type uv.uv_timer_t|nil
M.Integs = nil ---@type table|nil
M.overseer = false
M.reason = nil ---@type string|nil  why overseer is used (shown instead of the task list)
M.rows = {} ---@type table<integer, table>  line number -> selectable row
M.expanded = {} ---@type table<string, boolean>
M.prev_line = 1
M.footer_hidden = false

local actions = {} -- filled in the ACTIONS section

--  ╭──────────────────────────────────────────────────────────╮
--  │                         HELPERS                          │
--  ╰──────────────────────────────────────────────────────────╯

local function board_cfg()
  local b = Config.settings.board
  return type(b) == "table" and b or {}
end

local function settings()
  return vim.tbl_extend("force", DEFAULTS, board_cfg())
end

--- strict check for any window
local function win_ok(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- is the main popup alive?
local function valid()
  return win_ok(M.popup.main.win)
end

--- Wrap `fn` so errors never escape (key callbacks, autocmds, timer).
---@param fn function
---@param once? boolean  report the same message only once (use for timer ticks)
local function guard(fn, once)
  local last_err
  local function handler(e)
    if Config.settings.debug then
      return debug.traceback(tostring(e), 2)
    end
    return tostring(e)
  end

  return function(...)
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function()
      return fn(unpack(args, 1, n))
    end, handler)

    if ok then
      last_err = nil
      return
    end
    if once and err == last_err then
      return
    end
    last_err = err
    Util.error(err)
  end
end

local function dw(text)
  return vim.fn.strdisplaywidth(text)
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        RENDERING                         │
--  ╰──────────────────────────────────────────────────────────╯

local function setup_highlights()
  local links = {
    RmuxBoardOn = "DiagnosticOk",
    RmuxBoardStale = "DiagnosticError",
    RmuxBoardWatch = "DiagnosticInfo",
    RmuxBoardOff = "Comment",
    RmuxBoardMuted = "Comment",
    RmuxBoardKey = "Special",
    RmuxBoardTitleSection = "String",
    RmuxBoardSection = "Function",
    RmuxBoardCursor = "CursorLine",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function new_line()
  return { text = "", marks = {} }
end

--- Appends `text`; `hl` is applied to exactly that piece (byte offsets).
local function put(line, text, hl)
  local start = #line.text
  line.text = line.text .. text
  if hl then
    line.marks[#line.marks + 1] = { start, #line.text, hl }
  end
end

local function pad(text, width)
  local w = dw(text)
  if w >= width then
    return text
  end
  return text .. (" "):rep(width - w)
end

local function truncate(text, width)
  if width < 2 then
    return ""
  end
  if dw(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, width - 1) .. "…"
end

local function ago(ts)
  local d = os.time() - ts
  if d < 60 then
    return "just now"
  end
  if d < 3600 then
    return ("%d min ago"):format(math.floor(d / 60))
  end
  if d < 86400 then
    return ("%d h ago"):format(math.floor(d / 3600))
  end
  if d < 172800 then
    return "yesterday"
  end
  return ("%d d ago"):format(math.floor(d / 86400))
end

local function key_of(row)
  return (row.parent and (row.parent .. ">") or "") .. row.kind .. ":" .. row.name
end

---@param row RmuxBoardTask
local function task_line(row, namew, indent, width)
  local l = new_line()
  put(l, indent)
  put(l, row.alive and "●" or "✕", row.alive and "RmuxBoardOn" or "RmuxBoardStale")
  put(l, " ")
  put(l, pad(truncate(row.name, namew), namew), row.alive and nil or "RmuxBoardStale")
  put(l, " ")
  put(l, pad(row.pane_id or "-", 7), "RmuxBoardMuted")

  if row.alive then
    local used = dw(l.text)
    put(l, truncate(row.cmd, math.max(10, width - used - 14)), "RmuxBoardMuted")
  else
    put(l, "pane closed", "RmuxBoardStale")
  end

  if row.watching then
    put(l, "  ◉ watching", "RmuxBoardWatch")
  elseif row.target then
    put(l, "  › target", "RmuxBoardWatch")
  end
  return l
end

---@param row RmuxBoardGroup
local function group_summary(row)
  local up, down = {}, {}
  for _, child in ipairs(row.children) do
    local list = child.alive and up or down
    list[#list + 1] = child.name
  end

  local text = table.concat(up, ", ")
  if #down > 0 then
    text = text .. (#up > 0 and " · " or "") .. table.concat(down, ", ") .. " gone"
  end
  return text
end

---@param snap RmuxBoardSnapshot
---@return table[] lines, table<integer, table> rows
local function render(snap, width)
  local lines, rows = {}, {}

  local function add(line, row)
    lines[#lines + 1] = line
    if row then
      rows[#lines] = row
    end
  end

  local function text_line(text, hl)
    local l = new_line()
    put(l, text, hl)
    return l
  end

  add(
    text_line((" %s · %s · %d tasks"):format(snap.provider, snap.file_rc, snap.total_tasks), "RmuxBoardTitleSection")
  )
  add(new_line())

  -- one shared name column so panes and commands line up
  local namew = 10
  for _, row in ipairs(snap.running) do
    namew = math.max(namew, dw(row.name) + (row.kind == "group" and 2 or 0))
    if row.kind == "group" then
      for _, child in ipairs(row.children) do
        namew = math.max(namew, dw(child.name) + 4)
      end
    end
  end
  for _, row in ipairs(snap.recent) do
    namew = math.max(namew, dw(row.name))
  end
  namew = math.min(namew, 26)

  add(text_line(" running", "RmuxBoardSection"))
  if #snap.running == 0 then
    add(text_line("   nothing running", "RmuxBoardMuted"))
  end

  for _, row in ipairs(snap.running) do
    if row.kind == "group" then
      local open = M.expanded[row.name]
      local l = new_line()
      put(l, "  ")
      put(l, row.alive and "●" or "✕", row.alive and "RmuxBoardOn" or "RmuxBoardStale")
      put(l, " ")
      put(l, pad(truncate((open and "▾ " or "▸ ") .. row.name, namew), namew))
      put(l, " ")
      put(l, pad(("%d/%d"):format(row.on, row.total), 7), "RmuxBoardMuted")
      put(l, truncate(group_summary(row), math.max(10, width - namew - 28)), "RmuxBoardMuted")
      if row.watching then
        put(l, "  ◉ watching", "RmuxBoardWatch")
      end
      add(l, row)

      if open then
        for _, child in ipairs(row.children) do
          child.parent = row.name
          add(task_line(child, math.max(6, namew - 4), "    └ ", width), child)
        end
      end
    else
      add(task_line(row, namew, "  ", width), row)
    end
  end

  add(new_line())
  add(text_line(" recent", "RmuxBoardSection"))
  if #snap.recent == 0 then
    add(text_line("   no history yet · press a to run a task", "RmuxBoardMuted"))
  end

  for _, row in ipairs(snap.recent) do
    local l = new_line()
    put(l, "  ○", "RmuxBoardOff")
    put(l, " ")
    put(l, pad(truncate(row.name, namew), namew), "RmuxBoardMuted")
    put(l, " ")
    put(l, pad("-", 7), "RmuxBoardMuted")
    put(l, ago(row.ts), "RmuxBoardMuted")
    add(l, row)
  end

  add(new_line())
  return lines, rows
end

---@param messages string[]
---@param hl string
local function message_lines(messages, hl)
  local lines = { new_line() }
  for _, msg in ipairs(messages) do
    local l = new_line()
    put(l, " " .. msg, hl)
    lines[#lines + 1] = l
  end
  return lines, {}
end

--- Writes `lines` (text + highlight marks) into `buf`.
local function draw(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local texts = {}
  for i, l in ipairs(lines) do
    texts[i] = l.text
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, l in ipairs(lines) do
    for _, mark in ipairs(l.marks) do
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, mark[1], { end_col = mark[2], hl_group = mark[3] })
    end
  end
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                     KEYMAPS + FOOTER                     │
--  ╰──────────────────────────────────────────────────────────╯

-- display order in the footer (and binding order)
local ORDER = {
  "run",
  "focus",
  "stop",
  "kill",
  "watch",
  "unwatch",
  "errors",
  "all",
  "select_pane",
  "overseer",
  "toggle_group",
  "forget",
  -- "refresh",
  "close",
  "help",
}

local LABELS = {
  run = "run",
  focus = "focus",
  stop = "stop",
  kill = "kill",
  watch = "watch",
  unwatch = "unwatch",
  errors = "errors",
  all = "all",
  select_pane = "pane",
  overseer = "overseer",
  toggle_group = "toggle",
  forget = "forget",
  -- refresh = "refresh",
  close = "close",
  help = "help",
}

local SPECIAL_KEYS = {
  ["<cr>"] = "cr",
  ["<esc>"] = "esc",
  ["<tab>"] = "tab",
  ["<s-tab>"] = "s-tab",
  ["<space>"] = "space",
  ["<bs>"] = "bs",
}

--- "<CR>" -> "cr", "<C-x>" -> "c-x", "K" -> "K"
local function key_label(key)
  local lower = key:lower()
  if SPECIAL_KEYS[lower] then
    return SPECIAL_KEYS[lower]
  end
  local inner = key:match "^<(.+)>$"
  if inner then
    return inner:lower()
  end
  return key
end

--- Keys configured for `name`. `false`/nil/empty values (user disabled it) are dropped.
---@return string[]
local function keys_for(name)
  local keymaps = board_cfg().keymaps
  if type(keymaps) ~= "table" then
    return {}
  end

  local raw = keymaps[name]
  if raw == nil and name == "errors" then
    raw = keymaps.error -- config uses `error`
  end
  if raw == nil or raw == false then
    return {}
  end

  local list = type(raw) == "table" and raw or { raw }
  local keys = {}
  for _, key in ipairs(list) do
    if type(key) == "string" and key ~= "" then
      keys[#keys + 1] = key
    end
  end
  return keys
end

--  ── config validation ──────────────────────────────────────

local function distance(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

--- Closest valid action name for a misspelled one (stopcc -> stop).
local function suggest(name)
  local candidates = vim.list_extend({ "error" }, ORDER)
  local best, best_d
  for _, valid_name in ipairs(candidates) do
    local d = distance(name, valid_name)
    if #name >= 3 and (valid_name:find(name, 1, true) == 1 or name:find(valid_name, 1, true) == 1) then
      d = math.min(d, 1)
    end
    if d <= 2 and (not best_d or d < best_d) then
      best, best_d = valid_name, d
    end
  end
  return best
end

local function norm_key(key)
  if key:match "^<.+>$" then
    return key:lower() -- <CR> == <cr>
  end
  return key
end

--- Checks board.keymaps. `false` (disable an action) is valid; typos, bad values
--- and the same key bound to two actions are reported.
---@return string[] errors
local function validate_keymaps()
  local keymaps = board_cfg().keymaps
  if keymaps == nil or keymaps == false then
    return {}
  end
  if type(keymaps) ~= "table" then
    return { ("board.keymaps must be a table or false, got %s"):format(type(keymaps)) }
  end

  local errs = {}
  local known = { error = true }
  for _, n in ipairs(ORDER) do
    known[n] = true
  end

  local names = vim.tbl_keys(keymaps)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local owner = {} -- normalized key -> action name
  for _, name in ipairs(names) do
    local raw = keymaps[name]

    if type(name) ~= "string" or not known[name] then
      local hint = type(name) == "string" and suggest(name) or nil
      errs[#errs + 1] = ('unknown action "%s"%s'):format(
        tostring(name),
        hint and (' (did you mean "%s"?)'):format(hint) or ""
      )
    elseif raw ~= false then
      local list = type(raw) == "table" and raw or { raw }
      if type(raw) == "table" and #raw == 0 then
        errs[#errs + 1] = ('"%s" is an empty list (use false to disable it)'):format(name)
      end
      for _, key in ipairs(list) do
        if type(key) ~= "string" or key == "" then
          errs[#errs + 1] = ('"%s" has an invalid key (%s); use a string, a list of strings or false'):format(
            name,
            vim.inspect(key)
          )
        else
          local nk = norm_key(key)
          local other = owner[nk]
          if other and other ~= name then
            errs[#errs + 1] = ('key "%s" is used by both "%s" and "%s"'):format(key, other, name)
          else
            owner[nk] = name
          end
        end
      end
    end
  end

  if keymaps.error ~= nil and keymaps.errors ~= nil then
    errs[#errs + 1] = '"error" and "errors" are the same action: set only one'
  end

  return errs
end

---@return { key: string, label: string }[]
local function footer_items()
  local items = {}
  for _, name in ipairs(ORDER) do
    local keys = keys_for(name)
    if actions[name] and #keys > 0 then
      local shown = {}
      for _, key in ipairs(keys) do
        shown[#shown + 1] = key_label(key)
      end
      items[#items + 1] = { key = table.concat(shown, "/"), label = LABELS[name] or name }
    end
  end
  return items
end

local SEP = " · "

--- Footer lines, wrapped to `width` (same width as the main popup).
local function footer_lines(width)
  local inner = math.max(10, width - 1)
  local sep_w = dw(SEP)
  local lines, cur, cur_w = {}, nil, 0

  for _, item in ipairs(footer_items()) do
    local w = dw(item.key) + 1 + dw(item.label)
    if cur and cur_w + sep_w + w <= inner then
      put(cur, SEP, "RmuxBoardMuted")
      cur_w = cur_w + sep_w
    else
      cur = new_line()
      put(cur, " ")
      cur_w = 1
      lines[#lines + 1] = cur
    end
    put(cur, item.key, "RmuxBoardKey")
    put(cur, " ")
    put(cur, item.label, "RmuxBoardMuted")
    cur_w = cur_w + w
  end

  return lines
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                         WINDOW                           │
--  ╰──────────────────────────────────────────────────────────╯

local function box_width()
  return math.max(20, math.min(settings().width, vim.o.columns - 4))
end

--- Main and footer are placed as one block, centered; the footer sits right below main.
---@return table main_cfg, table footer_cfg
local function geometry(width, main_h, footer_h)
  local footer_part = footer_h > 0 and (footer_h + 2) or 0
  main_h = math.max(6, math.min(main_h, vim.o.lines - 6 - footer_part))

  local total = main_h + 2 + footer_part -- + borders
  local row = math.max(0, math.floor((vim.o.lines - total) / 2) - 1)
  local col = math.floor((vim.o.columns - width) / 2)

  return {
    relative = "editor",
    width = width,
    height = main_h,
    row = row,
    col = col,
  }, {
    relative = "editor",
    width = width,
    height = math.max(1, footer_h),
    row = row + main_h + 2,
    col = col,
  }
end

local function stop_timer()
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end
end

function M.close()
  stop_timer()
  pcall(vim.api.nvim_del_augroup_by_name, "RmuxBoard")

  local main_win = M.popup.main.win
  local footer_win = M.popup.footer.win
  M.popup.main.win, M.popup.main.buf = nil, nil
  M.popup.footer.win, M.popup.footer.buf = nil, nil
  M.rows = {}

  if win_ok(main_win) then
    pcall(vim.api.nvim_win_close, main_win, true)
  end
  if win_ok(footer_win) then
    pcall(vim.api.nvim_win_close, footer_win, true)
  end
end

---@param title string?
---@param enter boolean
---@param tbl table
---@return integer buf, integer win
local function open(title, enter, tbl)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "rmuxboard"
  vim.bo[buf].modifiable = false

  local cfg = vim.tbl_extend("force", tbl, {
    style = "minimal",
    border = "rounded",
    focusable = enter,
  })
  if title then
    cfg.title = title
    cfg.title_pos = "left"
  end

  local win = vim.api.nvim_open_win(buf, enter, cfg)
  vim.wo[win].wrap = false
  if enter then
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight = "CursorLine:RmuxBoardCursor"
  else
    vim.wo[win].winhighlight = "FloatBorder:RmuxBoardMuted"
  end

  return buf, win
end

local function draw_footer(flines, cfg)
  local footer = M.popup.footer

  if #flines == 0 then
    if win_ok(footer.win) then
      pcall(vim.api.nvim_win_close, footer.win, true)
    end
    footer.win, footer.buf = nil, nil
    return
  end

  if win_ok(footer.win) then
    vim.api.nvim_win_set_config(footer.win, cfg)
  else
    footer.buf, footer.win = open(nil, false, cfg)
  end
  draw(footer.buf, flines)
end

--- Size/position both popups for a main body of `main_h` lines.
local function layout(main_h)
  local width = box_width()
  local flines = (not M.footer_hidden) and footer_lines(width) or {}
  local main_cfg, footer_cfg = geometry(width, main_h, #flines)

  vim.api.nvim_win_set_config(M.popup.main.win, main_cfg)
  draw_footer(flines, footer_cfg)
end

---@param win? integer
local function refresh(win)
  local main = M.popup.main
  win = type(win) == "number" and win or main.win
  if not win_ok(win) or not main.buf then
    return
  end

  local width = box_width()

  local cursor_key
  local current = M.rows[vim.api.nvim_win_get_cursor(win)[1]]
  if current then
    cursor_key = key_of(current)
  end

  local lines, rows
  if M.overseer then
    lines, rows = message_lines({
      M.reason or "No .vscode/tasks.json in this project.",
      "rmux is using overseer. Press o to open it.",
    }, "RmuxBoardMuted")
  else
    local ok, snap = pcall(State.snapshot, M.Integs, settings().recent)
    if ok then
      lines, rows = render(snap, width)
    else
      -- backend failure (not inside tmux/herdr, tmux gone...): show it here, don't notify every tick
      lines, rows = message_lines({ tostring(snap) }, "RmuxBoardStale")
    end
  end

  draw(main.buf, lines)
  M.rows = rows
  layout(#lines)

  local target
  if cursor_key then
    for line_nr, row in pairs(rows) do
      if key_of(row) == cursor_key then
        target = line_nr
        break
      end
    end
  end
  if not target then
    for i = 1, #lines do
      if rows[i] then
        target = i
        break
      end
    end
  end

  target = math.min(target or 1, #lines)
  if vim.api.nvim_win_get_cursor(win)[1] ~= target then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
  M.prev_line = target
end

local function start_timer()
  stop_timer()
  local ms = settings().refresh_ms
  local tick = guard(refresh, true) -- same error reported only once

  M.timer = vim.uv.new_timer()
  M.timer:start(
    ms,
    ms,
    vim.schedule_wrap(function()
      if valid() then
        tick()
      else
        M.close()
      end
    end)
  )
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                         ACTIONS                          │
--  ╰──────────────────────────────────────────────────────────╯

local function current_row()
  if not valid() then
    return nil
  end
  return M.rows[vim.api.nvim_win_get_cursor(M.popup.main.win)[1]]
end

---@param row table
---@param only_alive boolean
---@return string[]
local function row_panes(row, only_alive)
  local ids = {}
  local function add(task)
    if task.pane_id and (not only_alive or task.alive) then
      ids[#ids + 1] = task.pane_id
    end
  end

  if row.kind == "group" then
    for _, child in ipairs(row.children) do
      add(child)
    end
  elseif row.kind == "task" then
    add(row)
  end
  return ids
end

local function refresh_later()
  vim.defer_fn(
    guard(function()
      if valid() then
        refresh()
      end
    end, true),
    300
  )
end

--- Close the board first, then run `fn` (pickers must not open on top of it).
local function leave_and(fn)
  local Integs = M.Integs
  M.close()
  vim.schedule(guard(function()
    fn(Integs)
  end))
end

function actions.run()
  local row = current_row()
  if not row then
    return
  end
  -- running task: interrupt + resend (restart). Recent task: run it again.
  M.Integs:generator_cmd_panes(row.name)
  refresh_later()
end

function actions.focus()
  local row = current_row()
  if not row then
    return
  end

  local ids = row_panes(row, true)
  if #ids == 0 then
    Util.warn "Task is not running"
    return
  end

  if Constant.get_run_with() == "herdr" then
    Util.info "herdr cannot focus a pane by id"
    return
  end

  M.Integs:run().jump_to_pane_id(ids[1])
end

function actions.stop()
  local row = current_row()
  if not row then
    return
  end

  local ids = row_panes(row, true)
  if #ids == 0 then
    Util.warn "Task is not running"
    return
  end

  for _, id in ipairs(ids) do
    M.Integs:send_signal_interrupt(id)
  end
  refresh_later()
end

function actions.kill()
  local row = current_row()
  if not row then
    return
  end

  local ids = row_panes(row, false)
  if #ids == 0 then
    Util.warn "Task has no pane to kill"
    return
  end

  for _, id in ipairs(ids) do
    M.Integs:kill_pane(id)
  end
  refresh()
end

function actions.forget()
  local row = current_row()
  if not row then
    return
  end

  if row.kind == "recent" then
    local ok, err = History.forget(row.name)
    if not ok then
      Util.warn(err)
    end
  elseif not row.alive then
    M.Integs:update_rmux() -- drops every dead pane from the bookkeeping
  else
    Util.warn "Task is running: stop it first (x or K)"
    return
  end
  refresh()
end

---@param clear_target boolean also forget the send target (selected pane)
local function stop_watch(clear_target)
  Constant.set_watcher_status(false)
  if clear_target then
    Constant.set_selected_pane ""
  end
  M.Integs:set_au_watcher() -- watcher off: removes the BufWritePost autocmd
end

--- Toggle: on a row that is being watched it stops watching,
--- on any other running row it starts (and moves) the watch there.
function actions.watch()
  local row = current_row()
  if not row then
    return
  end

  if row.watching then
    stop_watch(false) -- the pane stays the send target (› target)
    Util.info("Unwatch " .. row.name)
    refresh()
    return
  end

  local ids = row_panes(row, true)
  if #ids == 0 then
    Util.warn "Task is not running"
    return
  end

  Constant.set_selected_pane(ids[1])
  Constant.set_watcher_status(true)
  M.Integs:set_au_watcher()
  Util.info("Watching " .. row.name)
  refresh()
end

--- Stop watching AND forget the send target.
function actions.unwatch()
  stop_watch(true)
  Util.info "Unwatch"
  refresh()
end

function actions.errors()
  local row = current_row()
  if not row then
    return
  end

  local ids = row_panes(row, true)
  if #ids == 0 then
    Util.warn "Task is not running"
    return
  end

  Constant.set_selected_pane(ids[1])
  leave_and(function(Integs)
    Integs:find_err()
  end)
end

function actions.all()
  leave_and(function(Integs)
    require("rmux.picker").load_tasks_list(Integs)
  end)
end

function actions.select_pane()
  leave_and(function(Integs)
    Integs:select_target_panes()
  end)
end

function actions.overseer()
  leave_and(function()
    vim.cmd.OverseerToggle()
  end)
end

function actions.toggle_group()
  local row = current_row()
  if not row then
    return
  end

  local name = row.kind == "group" and row.name or row.parent
  if not name then
    return
  end

  M.expanded[name] = not M.expanded[name] or nil
  refresh()
end

-- function actions.refresh()
--   refresh()
-- end

function actions.close()
  M.close()
end

--- Show/hide the keys footer.
function actions.help()
  M.footer_hidden = not M.footer_hidden
  refresh()
end

--- Binds every configured key; keys set to `false` in the config are skipped.
local function set_keymaps(buf)
  for _, name in ipairs(ORDER) do
    local fn = actions[name]
    if fn then
      for _, key in ipairs(keys_for(name)) do
        vim.keymap.set("n", key, guard(fn), {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = "rmux board: " .. name,
        })
      end
    end
  end
end

--- Keep the cursor on selectable rows (headers and blank lines are skipped).
local function snap_cursor()
  if not valid() then
    return
  end

  local buf = M.popup.main.buf
  local win = M.popup.main.win

  local line = vim.api.nvim_win_get_cursor(win)[1]
  if M.rows[line] then
    M.prev_line = line
    return
  end

  local total = vim.api.nvim_buf_line_count(buf)
  local dir = line >= M.prev_line and 1 or -1

  for _, step in ipairs { dir, -dir } do
    local i = line + step
    while i >= 1 and i <= total do
      if M.rows[i] then
        M.prev_line = i
        pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
        return
      end
      i = i + step
    end
  end
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                          POPUPS                          │
--  ╰──────────────────────────────────────────────────────────╯

---@param Integs table
---@param opts? { default_overseer?: boolean, reason?: string }
local function main_popup(Integs, opts)
  local main_cfg = geometry(box_width(), 9, 0)
  local buf, win = open(" Rmux Board ", true, main_cfg)

  M.Integs = Integs
  M.overseer = (opts and opts.default_overseer) or false
  M.reason = opts and opts.reason or nil

  M.popup.main.buf = buf
  M.popup.main.win = win

  set_keymaps(buf)

  local group = vim.api.nvim_create_augroup("RmuxBoard", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = guard(snap_cursor, true),
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = guard(function()
      refresh()
    end, true),
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = guard(function()
      refresh()
    end, true),
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(M.close) -- never close a window from inside its own WinLeave
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = guard(function()
      stop_timer()
      local footer_win = M.popup.footer.win
      M.popup.main.buf, M.popup.main.win = nil, nil
      M.popup.footer.buf, M.popup.footer.win = nil, nil
      M.rows = {}
      if win_ok(footer_win) then
        pcall(vim.api.nvim_win_close, footer_win, true)
      end
    end),
  })

  refresh() -- also creates and fills the footer
  start_timer()
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                           API                            │
--  ╰──────────────────────────────────────────────────────────╯

---@param Integs table
---@param opts? { default_overseer?: boolean, reason?: string }
function M.show(Integs, opts)
  if valid() then
    vim.api.nvim_set_current_win(M.popup.main.win)
    return
  end

  -- config is read on every open: fix it and the board opens again
  local problems = validate_keymaps()
  if #problems > 0 then
    local lines = { "rmux board: invalid `board.keymaps` in your config, the board was not opened:" }
    for _, p in ipairs(problems) do
      lines[#lines + 1] = "  • " .. p
    end
    Util.error(table.concat(lines, "\n"))
    return
  end

  local ok, err = pcall(function()
    setup_highlights()
    main_popup(Integs, opts)
  end)

  if not ok then
    M.close() -- don't leave half-built windows behind
    Util.error("board: " .. tostring(err))
  end
end

---@param Integs table
---@param opts? { default_overseer?: boolean, reason?: string }
function M.toggle(Integs, opts)
  if valid() then
    M.close()
    return
  end
  M.show(Integs, opts)
end

return M
