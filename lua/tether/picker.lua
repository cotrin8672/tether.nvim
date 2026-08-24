local task_manager = require("tether.task")
local config_module = require("tether.config")

local M = {}

local function label(task)
  local range = task_manager.range(task)
  local location = range and ("%d:%d"):format(range.start_row + 1, range.start_col + 1) or "?:?"
  local prompt = task.prompt:gsub("%s+", " ")
  if #prompt > 64 then
    prompt = prompt:sub(1, 61) .. "..."
  end
  return ("[%s] %s:%s — %s"):format(task.state or task.activity, task.path, location, prompt)
end

function M.select(items, callback)
  local provider = config_module.get().ui.picker
  local ok, snacks = false, nil
  if provider == "auto" or provider == "snacks" then
    ok, snacks = pcall(require, "snacks")
  end
  if provider ~= "vim.ui.select" and ok and snacks.picker and type(snacks.picker.select) == "function" then
    snacks.picker.select(items, {
      prompt = "Open tether task",
      format_item = label,
      kind = "tether_task",
    }, callback)
    return
  end
  vim.ui.select(items, {
    prompt = "Open tether task",
    format_item = label,
  }, callback)
end

return M
