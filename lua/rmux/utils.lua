local M = {}

--  ╭──────────────────────────────────────────────────────────╮
--  │                         GENERALS                         │
--  ╰──────────────────────────────────────────────────────────╯

function M.get_root_path()
  local status = vim.b["gitsigns_status_dict"]

  if status == nil or status.root == nil then
    return vim.fn.getcwd()
  end

  return status.root
end

function M.rm_duplicates_tbl(arr)
  local newArray = {}
  local checkerTbl = {}
  for _, element in ipairs(arr) do
    -- [[if there is not yet a value at the index of element, then it will
    -- be nil, which will operate like false in an if statement
    -- ]]
    if not checkerTbl[element] then
      checkerTbl[element] = true
      table.insert(newArray, element)
    end
  end
  return newArray
end

function M.tablelength(T)
  local count = 0
  for _ in pairs(T) do
    count = count + 1
  end
  return count
end

function M.run_jobstart(command, on_stdout)
  vim.fn.jobstart(command, {
    on_stdout = on_stdout,
    on_stderr = on_stdout,
    stdout_buffered = false,
    stderr_buffered = false,
  })
end

function M.list_strip_empty_lines_beginning(lines)
  local i = 1
  while lines[i] == "" do
    i = i + 1
  end
  return vim.list_slice(lines, i)
end

function M.list_strip_empty_lines_ending(lines)
  local i = #lines
  while lines[i] == "" do
    i = i - 1
  end
  return vim.list_slice(lines, 1, i)
end

function M.list_strip_empty_lines(lines)
  return M.list_strip_empty_lines_ending(M.list_strip_empty_lines_beginning(lines))
end

function M.lstrip_whitespace(str, limit)
  if limit ~= nil then
    local num_found = 0
    while num_found < limit do
      str = string.gsub(str, "^%s", "")
      num_found = num_found + 1
    end
  else
    str = string.gsub(str, "^%s+", "")
  end
  return str
end

local rstrip_whitespace = function(str)
  str = string.gsub(str, "%s+$", "")
  return str
end

function M.strip_whitespace(str)
  if str then
    return rstrip_whitespace(M.lstrip_whitespace(str))
  end
  return ""
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                        FILE UTILS                        │
--  ╰──────────────────────────────────────────────────────────╯

function M.exists(filename)
  local stat = vim.loop.fs_stat(filename)
  return stat and stat.type or false
end

function M.is_dir(filename)
  return M.exists(filename) == "directory"
end

function M.is_file(filename)
  return M.exists(filename) == "file"
end

function M.jsonEncode(tbl)
  return vim.fn.json_encode(tbl)
end

function M.jsonDecode(tbl)
  return vim.fn.json_decode(tbl)
end

function M.read_json_file(tbl)
  return M.jsonDecode(vim.fn.readfile(tbl))
end

---@param env string
function M.get_env(env)
  return os.getenv(env)
end

--  ╭──────────────────────────────────────────────────────────╮
--  │                         LOGGING                          │
--  ╰──────────────────────────────────────────────────────────╯

function M.warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Notify" })
end

function M.error(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "Notify" })
end

function M.info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Notify" })
end

return M
