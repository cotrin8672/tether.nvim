local api = vim.api

local M = {}

local function pos_lt(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

local function normalize_positions(a, b)
  if pos_lt(b, a) then
    return b, a
  end
  return a, b
end

local function line_length(bufnr, row)
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
  return line and #line or 0
end

local function inclusive_end_col(bufnr, row, col)
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ""
  if col >= #line then
    return #line
  end
  local lead = line:byte(col + 1)
  local width = 1
  if lead >= 0xF0 then
    width = 4
  elseif lead >= 0xE0 then
    width = 3
  elseif lead >= 0xC0 then
    width = 2
  end
  return math.min(col + width, #line)
end

local function from_inclusive_marks(bufnr, start_mark, end_mark, kind)
  local start_pos = { start_mark[2] - 1, math.max(start_mark[3] - 1, 0) }
  local end_pos = { end_mark[2] - 1, math.max(end_mark[3] - 1, 0) }
  start_pos, end_pos = normalize_positions(start_pos, end_pos)

  if kind == "line" or kind == "V" then
    start_pos[2] = 0
    end_pos[2] = line_length(bufnr, end_pos[1])
  else
    end_pos[2] = inclusive_end_col(bufnr, end_pos[1], end_pos[2])
  end

  return {
    start_row = start_pos[1],
    start_col = start_pos[2],
    end_row = end_pos[1],
    end_col = end_pos[2],
  }
end

function M.from_operator(bufnr, kind)
  return from_inclusive_marks(bufnr, vim.fn.getpos("'["), vim.fn.getpos("']"), kind)
end

function M.from_visual(bufnr)
  local mode = vim.fn.mode()
  local visual_kind = mode == "V" and "V" or mode
  return from_inclusive_marks(bufnr, vim.fn.getpos("v"), vim.fn.getpos("."), visual_kind)
end

function M.get_text(bufnr, range)
  local lines = api.nvim_buf_get_text(
    bufnr,
    range.start_row,
    range.start_col,
    range.end_row,
    range.end_col,
    {}
  )
  return table.concat(lines, "\n")
end

function M.set_text(bufnr, range, text)
  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_text(
    bufnr,
    range.start_row,
    range.start_col,
    range.end_row,
    range.end_col,
    lines
  )

  local end_row = range.start_row + #lines - 1
  local end_col
  if #lines == 1 then
    end_col = range.start_col + #lines[1]
  else
    end_col = #lines[#lines]
  end
  return {
    start_row = range.start_row,
    start_col = range.start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

function M.contains(range, row, col)
  if range.start_row == range.end_row and range.start_col == range.end_col then
    return row == range.start_row and col == range.start_col
  end
  local point = { row, col }
  local start_pos = { range.start_row, range.start_col }
  local end_pos = { range.end_row, range.end_col }
  return not pos_lt(point, start_pos) and pos_lt(point, end_pos)
end

function M.overlaps(a, b)
  local a_start = { a.start_row, a.start_col }
  local a_end = { a.end_row, a.end_col }
  local b_start = { b.start_row, b.start_col }
  local b_end = { b.end_row, b.end_col }
  local a_empty = not pos_lt(a_start, a_end)
  local b_empty = not pos_lt(b_start, b_end)
  if a_empty and b_empty then
    return a_start[1] == b_start[1] and a_start[2] == b_start[2]
  end
  if a_empty then
    return not pos_lt(a_start, b_start) and pos_lt(a_start, b_end)
  end
  if b_empty then
    return not pos_lt(b_start, a_start) and pos_lt(b_start, a_end)
  end
  return pos_lt(a_start, b_end) and pos_lt(b_start, a_end)
end

function M.valid(range)
  if range.start_row < 0 or range.start_col < 0 then
    return false
  end
  return pos_lt({ range.start_row, range.start_col }, { range.end_row, range.end_col })
end

return M
