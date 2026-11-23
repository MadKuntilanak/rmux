-- Reads the current visual selection. Shared by every backend (tmux, herdr, ...).
-- Returns `lines` or `nil, "message"` (same contract as the backends).

local M = {}

local str_widthindex = function(s, index)
  if index < 1 or #s < index then
    return { 1, vim.api.nvim_strwidth(s) } -- return full range if index is out of range
  end

  local ws, we, b = 0, 0, 1
  while b <= #s and b <= index do
    local ch = s:sub(b, b + vim.str_utf_end(s, b))
    local wch = vim.api.nvim_strwidth(ch)
    ws = we + 1
    we = ws + wch - 1
    b = b + vim.str_utf_end(s, b) + 1
  end

  return { ws, we }
end

local str_wbyteindex = function(s, index)
  if index < 1 or vim.api.nvim_strwidth(s) < index then
    return { 1, #s } -- return full range if index is out of range
  end

  local b, bs, be, w = 1, 0, 0, 0
  while b <= #s and w < index do
    bs = b
    be = bs + vim.str_utf_end(s, bs)
    local ch = s:sub(bs, be)
    local wch = vim.api.nvim_strwidth(ch)
    w = w + wch
    b = be + 1
  end

  return { bs, be }
end

---@return string[]|nil lines, string|nil err
function M.get_lines()
  local c_v = vim.api.nvim_replace_termcodes("<C-v>", true, true, true)
  local mode = vim.fn.mode():sub(1, 1)
  if not vim.tbl_contains({ "v", "V", c_v }, mode) then
    return nil, "send range line must be called from visual mode"
  end

  -- Get the start and end positions of the selection
  local _, ls, cs = unpack(vim.fn.getpos "v")
  local _, le, ce = unpack(vim.fn.getpos ".")

  -- Ensure start position is before end position
  if ls > le or (ls == le and cs > ce) then
    ls, le = le, ls
    cs, ce = ce, cs
  end

  local lines = vim.api.nvim_buf_get_lines(0, ls - 1, le, false)
  if #lines == 0 then
    return nil, "empty selection"
  end
  ce = math.min(ce, #lines[#lines])

  if mode == "v" then
    -- include the whole (multi-byte) last character
    local last = lines[#lines]
    if ce >= 1 then
      ce = ce + vim.str_utf_end(last, ce)
    end

    if #lines == 1 then
      lines[1] = lines[1]:sub(cs, ce)
    else
      lines[1] = lines[1]:sub(cs)
      lines[#lines] = lines[#lines]:sub(1, ce)
    end
  elseif mode == c_v then
    -- TODO: visual block: fix weird behavior when selection include end of line
    local csw = math.min(str_widthindex(lines[1], cs)[1], str_widthindex(lines[#lines], ce)[1])
    local cew = math.max(str_widthindex(lines[1], cs)[2], str_widthindex(lines[#lines], ce)[2])
    for i, line in ipairs(lines) do
      local csl = str_wbyteindex(line, csw)[1]
      local cel = str_wbyteindex(line, cew)[2]
      lines[i] = line:sub(csl, cel)
    end
  end
  -- mode == "V": whole lines, nothing to cut

  return lines
end

return M
