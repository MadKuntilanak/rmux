local Util = require "rmux.utils"

local Tmpl = {}
Tmpl.__index = Tmpl

function Tmpl:register()
  local user = {}
  setmetatable(user, Tmpl)
  return user
end

---@param set_provider table
function Tmpl:set_template(set_provider)
  self.tbl_template_providers = {
    provider = set_provider,
    file_rc = nil,
  }
end

function Tmpl:is_file_rc_exists(file_rc_path, strip_filerc_path)
  if Util.is_file(file_rc_path) then
    return true
  end

  vim.system { "mkdir", "-p", strip_filerc_path[1] }
  vim.system { "touch", file_rc_path }

  -- Get info path rmux plugin
  local info = debug.getinfo(require("rmux").setup)
  local plugin_dir = info.source:sub(2):match "(.*/)"

  vim.cmd("vsp " .. file_rc_path)

  -- Load the contents
  vim.cmd("0r! cat " .. plugin_dir .. "/fts/vscode.json")
  vim.cmd "write!"
  vim.cmd "0"

  return false
end

function Tmpl:is_load()
  local is_load = false

  local project_dir = vim.uv.cwd()

  if not project_dir then
    return false
  end

  local strip_filerc_path = { ".vscode", "tasks.json" }
  local file_rc = table.concat(strip_filerc_path, "/")

  for _, template in pairs(self.tbl_template_providers.provider) do
    if template.file_rc == nil then
      template.file_rc = project_dir .. "/" .. file_rc
    end

    if not Util.is_file(template.file_rc) then
      return false
    end

    if not Tmpl.is_file_rc_exists(self, template.file_rc, strip_filerc_path) then
      return false
    end

    if template:load(project_dir, file_rc) then
      is_load = true
    end
  end

  return is_load
end

return Tmpl
