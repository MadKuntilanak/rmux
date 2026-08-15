local Util = require "rmux.utils"
local Constant = require "rmux.constant"

local Overseer
local loaded

local function setup_overseer()
  if loaded then
    return Overseer
  end

  if not Overseer then
    local has_overseer, _ = pcall(require, "overseer")
    if not has_overseer then
      error "This extension requires overseer.nvim (https://github.com/stevearc/overseer.nvim)"
      return
    end
  end

  Overseer = require "overseer.template.vscode"
  loaded = true
  return Overseer
end

local VScode = {}
VScode.__index = VScode

---@return boolean
function VScode:load(project_dir, file_rc)
  local overseer = setup_overseer()

  if not overseer then
    return false
  end

  Constant.set_file_rc(file_rc)

  local tbl_data = overseer.generator({ dir = project_dir }, function() end)

  if not tbl_data or #tbl_data == 0 then
    Util.warn "The file .vscode/tasks.json exists but the tasks is empty"
    return false
  end

  Constant.load_tasks(tbl_data)
  Constant.set_template_provider "vscode"

  return true
end

return VScode
