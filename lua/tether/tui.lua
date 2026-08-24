local api = vim.api
local config_module = require("tether.config")

local M = {}

local terminals = {}

local function dimensions()
  local opts = config_module.get().ui.float
  local width = opts.width <= 1 and math.floor(vim.o.columns * opts.width) or opts.width
  local height = opts.height <= 1 and math.floor(vim.o.lines * opts.height) or opts.height
  width = math.max(20, math.min(width, vim.o.columns - 2))
  height = math.max(5, math.min(height, vim.o.lines - 2))
  return width, height
end

local function open_window(bufnr, task)
  local opts = config_module.get().ui.float
  local width, height = dimensions()
  local win = api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = opts.border,
    title = (opts.title or " OpenCode ") .. "#" .. task.id .. " ",
    title_pos = "center",
  })
  vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:TetherFloatBorder"
  return win
end

function M.open(task, spec)
  local terminal = terminals[task.id]
  if terminal and api.nvim_buf_is_valid(terminal.bufnr) then
    local existing = vim.fn.bufwinid(terminal.bufnr)
    if existing ~= -1 then
      api.nvim_set_current_win(existing)
      return
    end
    terminal.win = open_window(terminal.bufnr, task)
    vim.cmd.startinsert()
    return
  end

  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  local win = open_window(bufnr, task)
  local job = vim.fn.termopen(spec.command, {
    cwd = spec.cwd,
    on_exit = function()
      vim.schedule(function()
        local current = terminals[task.id]
        if current and current.bufnr == bufnr then
          terminals[task.id] = nil
        end
        if api.nvim_buf_is_valid(bufnr) then
          pcall(api.nvim_buf_delete, bufnr, { force = true })
        end
      end)
    end,
  })
  if job <= 0 then
    pcall(api.nvim_win_close, win, true)
    pcall(api.nvim_buf_delete, bufnr, { force = true })
    vim.notify("Failed to start the OpenCode TUI", vim.log.levels.ERROR, { title = "tether.nvim" })
    return
  end
  terminals[task.id] = { bufnr = bufnr, win = win, job = job }
  vim.cmd.startinsert()
end

function M.close(task)
  local terminal = terminals[task.id]
  if not terminal then
    return
  end
  terminals[task.id] = nil
  if terminal.job and vim.fn.jobwait({ terminal.job }, 0)[1] == -1 then
    pcall(vim.fn.jobstop, terminal.job)
  end
  if api.nvim_buf_is_valid(terminal.bufnr) then
    pcall(api.nvim_buf_delete, terminal.bufnr, { force = true })
  end
end

function M.close_all()
  for task_id in pairs(vim.deepcopy(terminals)) do
    M.close({ id = task_id })
  end
end

return M
