local function keymaps(mode)
  local result = {}
  for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
    result[#result + 1] = {
      lhs = mapping.lhs,
      rhs = mapping.rhs,
      callback = mapping.callback,
      expr = mapping.expr,
    }
  end
  return result
end

test("setup creates no default normal or visual keymaps", function()
  local before_normal = keymaps("n")
  local before_visual = keymaps("x")
  local tether = require("tether")

  tether.setup()

  assert_equal(before_normal, keymaps("n"))
  assert_equal(before_visual, keymaps("x"))
end)
