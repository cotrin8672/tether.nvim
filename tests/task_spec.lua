local range = require("tether.range")
local tasks = require("tether.task")

local icons = {
  starting = "S",
  working = "W",
  retrying = "R",
  waiting = "I",
  revising = "V",
  pending = "P",
  edited = "E",
  error = "X",
}

local function setup_buffer(line)
  tasks.reset()
  tasks.setup({ ui = { icons = icons } })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  return bufnr
end

local function create(bufnr, start_col, end_col, prompt)
  return tasks.create({
    bufnr = bufnr,
    range = { start_row = 0, start_col = start_col, end_row = 0, end_col = end_col },
    prompt = prompt or "change this",
    root = "test-root",
    path = "test.lua",
  })
end

test("tasks allow adjacent ranges and reject overlapping ranges", function()
  local bufnr = setup_buffer("aa bb cc")
  local first = assert(create(bufnr, 0, 2))
  local adjacent = assert(create(bufnr, 2, 5))
  local overlapping, err = create(bufnr, 1, 3)

  assert_equal(1, first.id)
  assert_equal(2, adjacent.id)
  assert_equal(nil, overlapping)
  assert_truthy(err:find("overlaps tether task #1", 1, true))
end)

test("tasks at identical coordinates in different buffers do not overlap", function()
  local first_bufnr = setup_buffer("target")
  local first = assert(create(first_bufnr, 0, 6))
  local second_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(second_bufnr, 0, -1, false, { "target" })
  local second = assert(create(second_bufnr, 0, 6))

  assert_equal(first_bufnr, first.bufnr)
  assert_equal(second_bufnr, second.bufnr)
  assert_equal(2, #tasks.all())
end)

test("extmarks follow edits made before a task without causing conflicts", function()
  local bufnr = setup_buffer("alpha beta gamma")
  local task = assert(create(bufnr, 6, 10))

  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { "X " })
  assert_truthy(tasks.refresh(task))
  assert_equal({ start_row = 0, start_col = 8, end_row = 0, end_col = 12 }, tasks.range(task))
  assert_equal("beta", range.get_text(bufnr, tasks.range(task)))
end)

test("a proposal replaces only its bound task and moves later extmarks", function()
  local bufnr = setup_buffer("aaa bbb ccc")
  local first = assert(create(bufnr, 0, 3))
  local later = assert(create(bufnr, 8, 11))
  tasks.bind_session(first, "session-1")
  tasks.set_activity(first, "waiting")

  local ok, err = tasks.apply_submission("session-1", "AAAAA")
  assert_truthy(ok, err)
  assert_equal("AAAAA bbb ccc", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  assert_equal("AAAAA", first.expected_text)
  assert_equal("pending", first.state)
  assert_equal({ start_row = 0, start_col = 10, end_row = 0, end_col = 13 }, tasks.range(later))
  assert_truthy(tasks.refresh(later))
end)

test("subsequent submissions replace the complete current proposal", function()
  local bufnr = setup_buffer("before target after")
  local task = assert(create(bufnr, 7, 13))
  tasks.bind_session(task, "session-2")
  tasks.set_activity(task, "waiting")

  assert_truthy(tasks.apply_submission("session-2", "first\nproposal"))
  assert_truthy(tasks.apply_submission("session-2", "final"))
  assert_equal({ "before final after" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_equal("final", task.expected_text)
end)

test("an empty submission deletes the target and keeps its insertion point reserved", function()
  local bufnr = setup_buffer("before target after")
  local task = assert(create(bufnr, 7, 13))
  tasks.bind_session(task, "session-delete")

  assert_truthy(tasks.apply_submission("session-delete", ""))
  assert_equal("before  after", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  assert_equal({ start_row = 0, start_col = 7, end_row = 0, end_col = 7 }, tasks.range(task))

  local overlapping, err = create(bufnr, 7, 8)
  assert_equal(nil, overlapping)
  assert_truthy(err:find("overlaps tether task", 1, true))
  assert_truthy(tasks.apply_submission("session-delete", "replacement"))
  assert_equal("before replacement after", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
end)

test("edits inside a task conflict and prevent later submissions", function()
  local bufnr = setup_buffer("before target after")
  local task = assert(create(bufnr, 7, 13))
  tasks.bind_session(task, "session-3")
  vim.api.nvim_buf_set_text(bufnr, 0, 7, 0, 13, { "manual" })

  assert_falsy(tasks.refresh(task))
  assert_equal("edited", task.state)
  local ok, err = tasks.apply_submission("session-3", "agent")
  assert_falsy(ok)
  assert_truthy(err:find("target changed", 1, true))
  assert_equal("before manual after", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
end)

test("restore recovers the original snapshot after proposal and manual edits", function()
  local bufnr = setup_buffer("before target after")
  local task = assert(create(bufnr, 7, 13))
  tasks.bind_session(task, "session-4")
  tasks.set_activity(task, "waiting")
  assert_truthy(tasks.apply_submission("session-4", "proposal"))
  vim.api.nvim_buf_set_text(bufnr, 0, 7, 0, 15, { "manual" })
  assert_falsy(tasks.refresh(task))

  assert_truthy(tasks.restore(task))
  assert_equal("before target after", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  assert_equal("target", task.expected_text)
  assert_truthy(tasks.refresh(task))
end)

test("submission rejects unknown sessions and unmodifiable buffers", function()
  local bufnr = setup_buffer("target")
  local task = assert(create(bufnr, 0, 6))
  tasks.bind_session(task, "session-5")

  local unknown, unknown_err = tasks.apply_submission("missing", "code")
  assert_falsy(unknown)
  assert_truthy(unknown_err:find("No active", 1, true))

  vim.bo[bufnr].modifiable = false
  local immutable, immutable_err = tasks.apply_submission("session-5", "code")
  assert_falsy(immutable)
  assert_truthy(immutable_err:find("not modifiable", 1, true))
  vim.bo[bufnr].modifiable = true
end)

test("remove clears task and session indexes", function()
  local bufnr = setup_buffer("target")
  local task = assert(create(bufnr, 0, 6))
  tasks.bind_session(task, "session-6")
  tasks.remove(task)

  assert_equal(nil, tasks.by_session("session-6"))
  assert_equal({}, tasks.all())
  assert_falsy(tasks.bind_session(task, "late-session"))
  assert_equal(nil, tasks.by_session("late-session"))
end)
