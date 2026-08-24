local M = {}

local defaults = {
  context = {
    max_buffer_bytes = 256 * 1024,
    max_submit_bytes = 2 * 1024 * 1024,
  },
  opencode = {
    command = "opencode",
    curl = "curl",
    minimum_version = "1.18.0",
    poll_interval_ms = 750,
    request_timeout_seconds = 15,
    server_start_timeout_ms = 10000,
  },
  ui = {
    picker = "auto",
    icons = {
      starting = "◌",
      working = "◌",
      retrying = "↻",
      waiting = "○",
      revising = "◌",
      pending = "●",
      edited = "!",
      error = "×",
    },
    float = {
      width = 0.88,
      height = 0.82,
      border = "rounded",
      title = " OpenCode ",
    },
  },
}

M.values = vim.deepcopy(defaults)

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.values
end

function M.get()
  return M.values
end

return M
