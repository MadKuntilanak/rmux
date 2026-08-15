local h = function(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

local M = {
  prefix = "Rmux",
}

local colors = {
  -- Normal
  Normal = {
    fg = h("Normal").bg,
    bg = h("Normal").fg,
    italic = true,
    bold = true,
  },
  PrompTitle = {
    fg = h("Normal").bg,
    bg = h("Normal").fg,
    italic = true,
    bold = true,
  },
  IconTitle = {
    fg = h("Normal").bg,
    bg = h("Normal").fg,
    italic = true,
    bold = true,
  },

  -- Error
  NormalError = {
    fg = h("Normal").bg,
    bg = h("Error").fg,
    italic = true,
    bold = true,
  },
  PromptTitleError = {
    fg = h("Normal").bg,
    bg = h("Error").fg,
    italic = true,
    bold = true,
  },
  IconTitleError = {
    fg = h("Normal").bg,
    bg = h("Error").fg,
    italic = true,
    bold = true,
  },
}

function M.setup()
  for name_idx, col_data in pairs(colors) do
    vim.api.nvim_set_hl(
      0,
      M.prefix .. name_idx,
      { fg = col_data.fg, bg = col_data.bg, italic = col_data.italic, bold = col_data.bold }
    )
  end
end

return M
