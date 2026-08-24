local range = require("tether.range")

local function new_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function leave_visual_mode()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
end

test("operator character ranges use inclusive marks", function()
  local bufnr = new_buffer({ "abcdef", "ghijkl" })
  vim.api.nvim_buf_set_mark(bufnr, "[", 1, 1, {})
  vim.api.nvim_buf_set_mark(bufnr, "]", 1, 3, {})

  local selected = range.from_operator(bufnr, "char")
  assert_equal({ start_row = 0, start_col = 1, end_row = 0, end_col = 4 }, selected)
  assert_equal("bcd", range.get_text(bufnr, selected))
end)

test("operator line ranges include complete lines", function()
  local bufnr = new_buffer({ "first", "second", "third" })
  vim.api.nvim_buf_set_mark(bufnr, "[", 1, 3, {})
  vim.api.nvim_buf_set_mark(bufnr, "]", 2, 2, {})

  local selected = range.from_operator(bufnr, "line")
  assert_equal({ start_row = 0, start_col = 0, end_row = 1, end_col = 6 }, selected)
  assert_equal("first\nsecond", range.get_text(bufnr, selected))
end)

test("operator block ranges are normalized to one continuous range", function()
  local bufnr = new_buffer({ "abcd", "wxyz" })
  vim.api.nvim_buf_set_mark(bufnr, "[", 1, 1, {})
  vim.api.nvim_buf_set_mark(bufnr, "]", 2, 2, {})

  local selected = range.from_operator(bufnr, "block")
  assert_equal({ start_row = 0, start_col = 1, end_row = 1, end_col = 3 }, selected)
  assert_equal("bcd\nwxy", range.get_text(bufnr, selected))
end)

test("visual character selections normalize a reversed selection", function()
  local bufnr = new_buffer({ "abcdef" })
  vim.cmd("normal! gg04lv3h")

  local selected = range.from_visual(bufnr)
  assert_equal({ start_row = 0, start_col = 1, end_row = 0, end_col = 5 }, selected)
  assert_equal("bcde", range.get_text(bufnr, selected))
  leave_visual_mode()
end)

test("visual line selections include complete lines", function()
  local bufnr = new_buffer({ "first", "second", "third" })
  vim.cmd("normal! ggVj")

  local selected = range.from_visual(bufnr)
  assert_equal({ start_row = 0, start_col = 0, end_row = 1, end_col = 6 }, selected)
  assert_equal("first\nsecond", range.get_text(bufnr, selected))
  leave_visual_mode()
end)

test("visual block selections become one continuous range", function()
  local bufnr = new_buffer({ "abcd", "wxyz" })
  vim.cmd("normal! gg0l\022jl")

  local selected = range.from_visual(bufnr)
  assert_equal({ start_row = 0, start_col = 1, end_row = 1, end_col = 3 }, selected)
  assert_equal("bcd\nwxy", range.get_text(bufnr, selected))
  leave_visual_mode()
end)

test("inclusive UTF-8 marks advance by the full final character", function()
  local bufnr = new_buffer({ "aé猫z" })
  vim.api.nvim_buf_set_mark(bufnr, "[", 1, 1, {})
  vim.api.nvim_buf_set_mark(bufnr, "]", 1, 1, {})

  local selected = range.from_operator(bufnr, "char")
  assert_equal({ start_row = 0, start_col = 1, end_row = 0, end_col = 3 }, selected)
  assert_equal("é", range.get_text(bufnr, selected))
end)

test("set_text returns byte-column ranges for UTF-8 replacements", function()
  local bufnr = new_buffer({ "aBCz" })
  local replaced = range.set_text(bufnr, {
    start_row = 0,
    start_col = 1,
    end_row = 0,
    end_col = 3,
  }, "é猫")

  assert_equal("aé猫z", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  assert_equal({ start_row = 0, start_col = 1, end_row = 0, end_col = 6 }, replaced)
end)

test("adjacent half-open ranges do not overlap", function()
  local left = { start_row = 0, start_col = 0, end_row = 0, end_col = 3 }
  local right = { start_row = 0, start_col = 3, end_row = 0, end_col = 6 }
  assert_falsy(range.overlaps(left, right))
  assert_truthy(range.overlaps(left, { start_row = 0, start_col = 2, end_row = 0, end_col = 4 }))
  assert_truthy(range.contains(left, 0, 0))
  assert_falsy(range.contains(left, 0, 3))
end)
