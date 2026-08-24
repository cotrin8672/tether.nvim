local api = vim.api
local config_module = require("tether.config")
local opencode = require("tether.opencode")
local picker = require("tether.picker")
local range_util = require("tether.range")
local task_manager = require("tether.task")
local tui = require("tether.tui")

local M = {}

local initialized = false
local operator_bufnr

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "tether.nvim" })
end

local function ensure_setup()
  if not initialized then
    M.setup()
  end
end

local function current_task()
  local cursor = api.nvim_win_get_cursor(0)
  return task_manager.at(api.nvim_get_current_buf(), cursor[1] - 1, cursor[2])
end

local function project_root(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    local root = vim.fs.root(name, { ".git" })
    if root then
      return vim.fs.normalize(root)
    end
  end
  return vim.fs.normalize(vim.fn.getcwd())
end

local function display_path(bufnr, root)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "[No Name]"
  end
  local relative = vim.fs.relpath(root, name)
  return relative or vim.fs.normalize(name)
end

local function buffer_snapshot(bufnr)
  return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
end

local function make_prompt(task, user_prompt, selected, snapshot)
  local target_range = task_manager.range(task)
  local context = {
    path = task.path,
    filetype = vim.bo[task.bufnr].filetype,
    selection = {
      start = { line = target_range.start_row + 1, column = target_range.start_col + 1 },
      ["end"] = { line = target_range.end_row + 1, column = target_range.end_col + 1 },
    },
    target = selected,
    buffer_snapshot = snapshot,
  }
  return table.concat({
    "Implement the following request for the editor-owned target:",
    user_prompt,
    "",
    "The current editor context is encoded as JSON below. The `target` value is the only text you may replace.",
    vim.json.encode(context),
    "",
    "Inspect the repository as needed, then call tether_submit_target with the complete replacement text.",
  }, "\n")
end

local function begin(range)
  ensure_setup()
  local bufnr = api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    notify("Tether only supports normal file buffers", vim.log.levels.ERROR)
    return
  end
  if not vim.bo[bufnr].modifiable then
    notify("The current buffer is not modifiable", vim.log.levels.ERROR)
    return
  end
  if not range_util.valid(range) then
    notify("The selected target is empty", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Tether > " }, function(input)
    if input == nil then
      return
    end
    input = vim.trim(input)
    if input == "" then
      notify("A task instruction is required", vim.log.levels.WARN)
      return
    end
    if not api.nvim_buf_is_valid(bufnr) then
      notify("The target buffer no longer exists", vim.log.levels.ERROR)
      return
    end
    if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable then
      notify("The target buffer is no longer a modifiable file buffer", vim.log.levels.ERROR)
      return
    end
    local name = api.nvim_buf_get_name(bufnr)
    local snapshot
    if vim.bo[bufnr].modified or name == "" then
      snapshot = buffer_snapshot(bufnr)
      if #snapshot > config_module.get().context.max_buffer_bytes then
        notify(
          ("The dirty buffer snapshot is %d bytes; save it or raise context.max_buffer_bytes"):format(#snapshot),
          vim.log.levels.ERROR
        )
        return
      end
    end
    local root = project_root(bufnr)
    local created, task, create_error = pcall(task_manager.create, {
      bufnr = bufnr,
      range = range,
      prompt = input,
      root = root,
      path = display_path(bufnr, root),
    })
    if not created then
      notify("The selected target is no longer valid: " .. tostring(task), vim.log.levels.ERROR)
      return
    end
    if not task then
      notify(create_error, vim.log.levels.ERROR)
      return
    end
    local prompt = make_prompt(task, input, task.original_text, snapshot)
    opencode.start_task(task, prompt, function(err)
      if err then
        notify("Unable to start tether task: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

local function finish(task, restore)
  opencode.abort(task)
  tui.close(task)
  if restore then
    task_manager.restore(task)
  end
  task_manager.remove(task)
end

local function open_task(task)
  if not task.session_id then
    notify("This task does not have an OpenCode session yet", vim.log.levels.WARN)
    return
  end
  opencode.ensure(function(err)
    if err then
      notify("Unable to start OpenCode: " .. err, vim.log.levels.ERROR)
      return
    end
    tui.open(task, opencode.attach_spec(task))
  end)
end

function M.setup(opts)
  local config = config_module.setup(opts)
  task_manager.setup(config)
  initialized = true

  api.nvim_set_hl(0, "TetherWorking", { link = "DiagnosticInfo", default = true })
  api.nvim_set_hl(0, "TetherRetrying", { link = "DiagnosticWarn", default = true })
  api.nvim_set_hl(0, "TetherWaiting", { link = "Comment", default = true })
  api.nvim_set_hl(0, "TetherPending", { link = "DiagnosticOk", default = true })
  api.nvim_set_hl(0, "TetherEdited", { link = "DiagnosticWarn", default = true })
  api.nvim_set_hl(0, "TetherError", { link = "DiagnosticError", default = true })
  api.nvim_set_hl(0, "TetherFloatBorder", { link = "FloatBorder", default = true })

  local group = api.nvim_create_augroup("tether.nvim", { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      task_manager.refresh_buffer(event.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      for _, task in ipairs(task_manager.for_buffer(event.buf)) do
        opencode.abort(task)
        tui.close(task)
        task_manager.remove(task)
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      tui.close_all()
      opencode.shutdown()
    end,
  })

  for _, command in ipairs({ "TetherOpen", "TetherAccept", "TetherReject" }) do
    pcall(api.nvim_del_user_command, command)
  end
  api.nvim_create_user_command("TetherOpen", M.open, {})
  api.nvim_create_user_command("TetherAccept", M.accept, {})
  api.nvim_create_user_command("TetherReject", M.reject, {})
  return M
end

function M.operator()
  ensure_setup()
  operator_bufnr = api.nvim_get_current_buf()
  vim.go.operatorfunc = "v:lua.require'tether'._operatorfunc"
  return "g@"
end

function M._operatorfunc(kind)
  local bufnr = api.nvim_get_current_buf()
  if operator_bufnr and operator_bufnr ~= bufnr then
    notify("The operator target buffer changed", vim.log.levels.ERROR)
    return
  end
  begin(range_util.from_operator(bufnr, kind))
end

function M.visual()
  ensure_setup()
  local selected = range_util.from_visual(api.nvim_get_current_buf())
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  vim.schedule(function()
    begin(selected)
  end)
end

function M.open()
  ensure_setup()
  local task = current_task()
  if task then
    open_task(task)
    return
  end
  local all = task_manager.all()
  if #all == 0 then
    notify("There are no active tether tasks", vim.log.levels.INFO)
    return
  end
  picker.select(all, function(choice)
    if choice then
      open_task(choice)
    end
  end)
end

function M.accept()
  ensure_setup()
  local task = current_task()
  if not task then
    notify("There is no tether task at the cursor", vim.log.levels.WARN)
    return
  end
  task_manager.refresh(task)
  if not task.has_proposal and not task.conflicted then
    notify("This task has no proposal to accept", vim.log.levels.WARN)
    return
  end
  finish(task, false)
end

function M.reject()
  ensure_setup()
  local task = current_task()
  if not task then
    notify("There is no tether task at the cursor", vim.log.levels.WARN)
    return
  end
  task_manager.refresh(task)
  if task.conflicted then
    vim.ui.select({ "Restore original text", "Keep editing" }, {
      prompt = "The tether target was edited. Reject and discard those edits?",
    }, function(choice)
      if choice == "Restore original text" then
        finish(task, true)
      end
    end)
    return
  end
  finish(task, task.has_proposal)
end

M._task_manager = task_manager

return M
