local api = vim.api
local range_util = require("tether.range")

local M = {
  tasks = {},
  sessions = {},
  next_id = 1,
}

local namespace
local config

local state_hl = {
  starting = "TetherWorking",
  working = "TetherWorking",
  retrying = "TetherRetrying",
  waiting = "TetherWaiting",
  revising = "TetherWorking",
  pending = "TetherPending",
  edited = "TetherEdited",
  error = "TetherError",
}

local function extmark_range(task)
  if not api.nvim_buf_is_valid(task.bufnr) then
    return nil
  end
  local mark = api.nvim_buf_get_extmark_by_id(task.bufnr, namespace, task.extmark, { details = true })
  if not mark or #mark == 0 then
    return nil
  end
  local details = mark[3]
  return {
    start_row = mark[1],
    start_col = mark[2],
    end_row = details.end_row or mark[1],
    end_col = details.end_col or mark[2],
  }
end

local function display_state(task)
  if task.conflicted then
    return "edited"
  end
  if task.activity == "error" then
    return "error"
  end
  if task.activity == "retrying" then
    return "retrying"
  end
  if task.activity == "starting" then
    return "starting"
  end
  if task.activity == "working" then
    return task.has_proposal and "revising" or "working"
  end
  if task.has_proposal then
    return "pending"
  end
  return "waiting"
end

local function render(task)
  local current = extmark_range(task)
  if not current then
    return
  end
  local state = display_state(task)
  local icon = config.ui.icons[state] or "AI"
  task.state = state
  task.extmark = api.nvim_buf_set_extmark(task.bufnr, namespace, current.start_row, current.start_col, {
    id = task.extmark,
    end_row = current.end_row,
    end_col = current.end_col,
    right_gravity = false,
    end_right_gravity = true,
    sign_text = icon,
    sign_hl_group = state_hl[state],
    virt_text = { { " AI · " .. state, state_hl[state] } },
    virt_text_pos = "eol",
    virt_text_hide = true,
    priority = 110,
  })
end

function M.setup(opts)
  config = opts
  namespace = namespace or api.nvim_create_namespace("tether.nvim")
end

function M.range(task)
  return extmark_range(task)
end

function M.refresh(task)
  local current = extmark_range(task)
  if not current then
    task.conflicted = true
    return false
  end
  task.conflicted = range_util.get_text(task.bufnr, current) ~= task.expected_text
  render(task)
  return not task.conflicted
end

function M.refresh_buffer(bufnr)
  for _, task in pairs(M.tasks) do
    if task.bufnr == bufnr and not task.applying then
      M.refresh(task)
    end
  end
end

function M.create(args)
  for _, task in pairs(M.tasks) do
    if task.bufnr == args.bufnr then
      local existing = extmark_range(task)
      if existing and range_util.overlaps(existing, args.range) then
        return nil, "The selected range overlaps tether task #" .. task.id
      end
    end
  end

  local id = M.next_id
  M.next_id = id + 1
  local extmark = api.nvim_buf_set_extmark(args.bufnr, namespace, args.range.start_row, args.range.start_col, {
    end_row = args.range.end_row,
    end_col = args.range.end_col,
    right_gravity = false,
    end_right_gravity = true,
  })
  local original = range_util.get_text(args.bufnr, args.range)
  local task = {
    id = id,
    bufnr = args.bufnr,
    extmark = extmark,
    original_text = original,
    expected_text = original,
    prompt = args.prompt,
    root = args.root,
    path = args.path,
    activity = "starting",
    has_proposal = false,
    conflicted = false,
  }
  M.tasks[id] = task
  render(task)
  return task
end

function M.bind_session(task, session_id)
  if M.tasks[task.id] ~= task then
    return false
  end
  if task.session_id then
    M.sessions[task.session_id] = nil
  end
  task.session_id = session_id
  M.sessions[session_id] = task.id
  return true
end

function M.by_session(session_id)
  local id = M.sessions[session_id]
  return id and M.tasks[id] or nil
end

function M.set_activity(task, activity, message)
  if not M.tasks[task.id] then
    return
  end
  task.activity = activity
  task.error = message
  M.refresh(task)
end

function M.apply_submission(session_id, code)
  local task = M.by_session(session_id)
  if not task then
    return false, "No active Neovim task is bound to this OpenCode session"
  end
  if not api.nvim_buf_is_valid(task.bufnr) then
    return false, "The target buffer no longer exists"
  end
  if not vim.bo[task.bufnr].modifiable then
    return false, "The target buffer is not modifiable"
  end
  if not M.refresh(task) then
    return false, "The target changed in Neovim; accept or reject it before submitting again"
  end

  local current = extmark_range(task)
  task.applying = true
  local next_range = range_util.set_text(task.bufnr, current, code)
  task.expected_text = code
  task.has_proposal = true
  task.conflicted = false
  task.extmark = api.nvim_buf_set_extmark(task.bufnr, namespace, next_range.start_row, next_range.start_col, {
    id = task.extmark,
    end_row = next_range.end_row,
    end_col = next_range.end_col,
    right_gravity = false,
    end_right_gravity = true,
  })
  task.applying = false
  M.refresh_buffer(task.bufnr)
  return true
end

function M.restore(task)
  local current = extmark_range(task)
  if not current or not api.nvim_buf_is_valid(task.bufnr) then
    return false
  end
  task.applying = true
  local restored = range_util.set_text(task.bufnr, current, task.original_text)
  task.expected_text = task.original_text
  task.extmark = api.nvim_buf_set_extmark(task.bufnr, namespace, restored.start_row, restored.start_col, {
    id = task.extmark,
    end_row = restored.end_row,
    end_col = restored.end_col,
    right_gravity = false,
    end_right_gravity = true,
  })
  task.applying = false
  return true
end

function M.remove(task)
  M.tasks[task.id] = nil
  if task.session_id then
    M.sessions[task.session_id] = nil
  end
  if api.nvim_buf_is_valid(task.bufnr) then
    pcall(api.nvim_buf_del_extmark, task.bufnr, namespace, task.extmark)
  end
end

function M.at(bufnr, row, col)
  for _, task in pairs(M.tasks) do
    if task.bufnr == bufnr then
      M.refresh(task)
      local current = extmark_range(task)
      if current and range_util.contains(current, row, col) then
        return task
      end
    end
  end
end

function M.for_buffer(bufnr)
  local result = {}
  for _, task in pairs(M.tasks) do
    if task.bufnr == bufnr then
      result[#result + 1] = task
    end
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

function M.all()
  local result = vim.tbl_values(M.tasks)
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

function M.reset()
  for _, task in pairs(vim.deepcopy(M.tasks)) do
    local live = M.tasks[task.id]
    if live then
      M.remove(live)
    end
  end
  M.tasks = {}
  M.sessions = {}
  M.next_id = 1
end

return M
