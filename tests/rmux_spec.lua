describe("rmux", function()
  local plugin

  before_each(function()
    package.loaded["rmux"] = nil
    plugin = require "rmux"
  end)

  it("should load successfully", function()
    assert.is_not_nil(plugin)
  end)
end)
