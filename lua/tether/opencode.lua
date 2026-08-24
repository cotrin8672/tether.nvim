local uv = vim.uv or vim.loop
local bridge = require("tether.bridge")
local config_module = require("tether.config")
local tasks = require("tether.task")

local M = {}

local state = {
  ready = false,
  starting = false,
  stopping = false,
  callbacks = {},
  last_stderr = "",
  warned_custom_config_dir = false,
}

local poll_timer
local poll_running = false

local agent_prompt = [[You are an inline implementation agent controlled by tether.nvim.

The user owns one exact editor target. You may inspect the repository and use read-only tools to understand it, but you must never modify files or delegate work. When the implementation is complete, call tether_submit_target exactly once with the complete replacement text for the selected target. The submitted text must be final code only: no Markdown fences, no explanation, no file path, and no patch. Do not broaden the edit beyond the target. If the request cannot be completed safely, explain why and finish without submitting.]]

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "tether.nvim" })
end

local function random_token(label)
  local source = table.concat({ label, tostring(uv.hrtime()), tostring(vim.fn.getpid()), tostring(math.random()) }, ":")
  return vim.fn.sha256(source)
end

local function free_port()
  local socket = assert(uv.new_tcp())
  assert(socket:bind("127.0.0.1", 0))
  local port = assert(socket:getsockname()).port
  socket:close()
  return port
end

local function bundled_plugin_path()
  local files = vim.api.nvim_get_runtime_file("opencode/tether.js", false)
  if not files[1] then
    return nil, "Unable to locate bundled opencode/tether.js on runtimepath"
  end
  return vim.fs.abspath(files[1])
end

local function prepare_config_dir()
  local source, source_error = bundled_plugin_path()
  if not source then
    return nil, source_error
  end
  local directory = vim.fs.joinpath(vim.fn.stdpath("cache"), "tether.nvim", "opencode")
  local plugins = vim.fs.joinpath(directory, "plugins")
  vim.fn.mkdir(plugins, "p")
  local destination = vim.fs.joinpath(plugins, "tether.js")
  local source_lines = vim.fn.readfile(source, "b")
  local current_lines = vim.fn.filereadable(destination) == 1 and vim.fn.readfile(destination, "b") or nil
  if not current_lines or not vim.deep_equal(source_lines, current_lines) then
    local result = vim.fn.writefile(source_lines, destination, "b")
    if result ~= 0 then
      return nil, "Unable to stage the bundled OpenCode plugin in " .. destination
    end
  end
  return directory
end

local function injected_config()
  local base = {}
  local inherited = vim.env.OPENCODE_CONFIG_CONTENT
  if inherited and inherited ~= "" then
    local ok, decoded = pcall(vim.json.decode, inherited)
    if not ok or type(decoded) ~= "table" then
      return nil, "OPENCODE_CONFIG_CONTENT is not valid JSON"
    end
    base = decoded
  end

  if type(base.permission) ~= "table" then
    base.permission = {}
  end
  base.permission.edit = "deny"
  base.permission.bash = "deny"
  base.permission.task = "deny"

  if type(base.agent) ~= "table" then
    base.agent = {}
  end
  base.agent.tether = {
    description = "Read-only repository agent that can only submit one editor-owned target",
    mode = "primary",
    prompt = agent_prompt,
    permission = {
      edit = "deny",
      bash = "deny",
      task = "deny",
      question = "deny",
      read = "allow",
      grep = "allow",
      glob = "allow",
      list = "allow",
      lsp = "allow",
      webfetch = "allow",
      websearch = "allow",
      skill = "allow",
      todowrite = "allow",
      tether_submit_target = "allow",
    },
  }
  return vim.json.encode(base)
end

local function curl_request(method, path, body, root, callback)
  local cfg = config_module.get().opencode
  local url = state.url .. path
  if root then
    local separator = path:find("?", 1, true) and "&" or "?"
    url = url .. separator .. "directory=" .. vim.uri_encode(root)
  end
  local args = {
    cfg.curl,
    "--silent",
    "--show-error",
    "--max-time",
    tostring(cfg.request_timeout_seconds),
    "--user",
    "opencode:" .. state.password,
    "--request",
    method,
    "--header",
    "Content-Type: application/json",
    "--write-out",
    "\n%{http_code}",
    url,
  }
  local stdin
  if body ~= nil then
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@-"
    stdin = vim.json.encode(body)
  end
  vim.system(args, { text = true, stdin = stdin }, function(result)
    vim.schedule(function()
      local stdout = result.stdout or ""
      local response_body, status = stdout:match("^(.*)\n(%d%d%d)$")
      status = tonumber(status)
      if result.code ~= 0 or not status or status < 200 or status >= 300 then
        local detail = response_body ~= "" and response_body or (result.stderr or "curl request failed")
        callback(detail, nil, status)
        return
      end
      callback(nil, response_body or "", status)
    end)
  end)
end

local function flush_callbacks(err)
  local callbacks = state.callbacks
  state.callbacks = {}
  for _, callback in ipairs(callbacks) do
    callback(err)
  end
end

local function mark_server_error(message)
  for _, task in ipairs(tasks.all()) do
    if task.session_id then
      tasks.set_activity(task, "error", message)
    end
  end
end

local function poll_statuses()
  if poll_running or not state.ready then
    return
  end
  local roots = {}
  for _, task in ipairs(tasks.all()) do
    if task.session_id then
      roots[task.root] = true
    end
  end
  local root_list = vim.tbl_keys(roots)
  if #root_list == 0 then
    return
  end
  poll_running = true
  local remaining = #root_list
  for _, root in ipairs(root_list) do
    curl_request("GET", "/session/status", nil, root, function(err, body)
      if not err then
        local ok, statuses = pcall(vim.json.decode, body)
        if ok and type(statuses) == "table" then
          for _, task in ipairs(tasks.all()) do
            if task.root == root and task.session_id then
              local status = statuses[task.session_id]
              if status and status.type == "busy" then
                tasks.set_activity(task, "working")
              elseif status and status.type == "retry" then
                tasks.set_activity(task, "retrying", status.message)
              elseif task.activity ~= "error" then
                tasks.set_activity(task, "waiting")
              end
            end
          end
        end
      end
      remaining = remaining - 1
      if remaining == 0 then
        poll_running = false
      end
    end)
  end
end

local function start_polling()
  if poll_timer then
    return
  end
  poll_timer = assert(uv.new_timer())
  local interval = config_module.get().opencode.poll_interval_ms
  poll_timer:start(interval, interval, vim.schedule_wrap(poll_statuses))
end

local function start_server()
  local cfg = config_module.get()
  if vim.env.OPENCODE_CONFIG_DIR and vim.env.OPENCODE_CONFIG_DIR ~= "" and not state.warned_custom_config_dir then
    state.warned_custom_config_dir = true
    notify(
      "OpenCode's OPENCODE_CONFIG_DIR is temporarily replaced for the tether server; custom agents and plugins from that directory are unavailable in tether sessions",
      vim.log.levels.WARN
    )
  end
  local callback = bridge.start({
    max_body = cfg.context.max_submit_bytes,
    handler = function(session_id, code)
      return tasks.apply_submission(session_id, code)
    end,
  })
  local content, content_error = injected_config()
  if not content then
    state.starting = false
    flush_callbacks(content_error)
    return
  end
  local runtime_config_dir, runtime_error = prepare_config_dir()
  if not runtime_config_dir then
    state.starting = false
    flush_callbacks(runtime_error)
    return
  end

  state.port = free_port()
  state.url = ("http://127.0.0.1:%d"):format(state.port)
  state.password = random_token("tether-opencode")
  state.starting = true
  state.stopping = false
  state.last_stderr = ""
  local args = {
    cfg.opencode.command,
    "serve",
    "--hostname",
    "127.0.0.1",
    "--port",
    tostring(state.port),
  }
  state.process = vim.system(args, {
    text = true,
    cwd = vim.fn.getcwd(),
    env = {
      OPENCODE_CONFIG_CONTENT = content,
      OPENCODE_CONFIG_DIR = runtime_config_dir,
      OPENCODE_SERVER_PASSWORD = state.password,
      TETHER_CALLBACK_URL = callback.url,
      TETHER_CALLBACK_TOKEN = callback.token,
    },
    stdout = function() end,
    stderr = function(_, data)
      if data then
        state.last_stderr = (state.last_stderr .. data):sub(-8192)
      end
    end,
  }, function(result)
    vim.schedule(function()
      state.process = nil
      state.ready = false
      state.starting = false
      if not state.stopping then
        local message = vim.trim(state.last_stderr) ~= "" and vim.trim(state.last_stderr)
          or ("OpenCode server exited with code %d"):format(result.code or -1)
        mark_server_error(message)
        flush_callbacks(message)
        notify(message, vim.log.levels.ERROR)
      end
    end)
  end)

  local started_at = uv.hrtime()
  local function check_health()
    if not state.starting then
      return
    end
    curl_request("GET", "/global/health", nil, nil, function(err)
      if not err then
        state.ready = true
        state.starting = false
        start_polling()
        flush_callbacks(nil)
        return
      end
      local elapsed_ms = (uv.hrtime() - started_at) / 1e6
      if elapsed_ms >= cfg.opencode.server_start_timeout_ms then
        state.starting = false
        local message = "Timed out waiting for the OpenCode server"
        if state.process then
          pcall(state.process.kill, state.process, 15)
        end
        flush_callbacks(message)
        mark_server_error(message)
        return
      end
      vim.defer_fn(check_health, 150)
    end)
  end
  vim.defer_fn(check_health, 50)
end

function M.ensure(callback)
  callback = callback or function() end
  if state.ready then
    callback(nil)
    return
  end
  state.callbacks[#state.callbacks + 1] = callback
  if not state.starting then
    start_server()
  end
end

function M.request(method, path, body, root, callback)
  M.ensure(function(err)
    if err then
      callback(err)
      return
    end
    curl_request(method, path, body, root, callback)
  end)
end

function M.start_task(task, prompt, callback)
  local title = ("tether #%d · %s"):format(task.id, task.path)
  M.request("POST", "/session", { title = title, agent = "tether" }, task.root, function(create_error, body)
    if create_error then
      tasks.set_activity(task, "error", create_error)
      callback(create_error)
      return
    end
    local ok, session = pcall(vim.json.decode, body)
    if not ok or type(session) ~= "table" or type(session.id) ~= "string" then
      local message = "OpenCode returned an invalid session response"
      tasks.set_activity(task, "error", message)
      callback(message)
      return
    end
    if not tasks.bind_session(task, session.id) then
      curl_request("POST", "/session/" .. session.id .. "/abort", nil, task.root, function() end)
      callback("The target task was closed before its OpenCode session was ready")
      return
    end
    M.request("POST", "/session/" .. session.id .. "/prompt_async", {
      agent = "tether",
      parts = { { type = "text", text = prompt } },
    }, task.root, function(prompt_error)
      if prompt_error then
        tasks.set_activity(task, "error", prompt_error)
        callback(prompt_error)
        return
      end
      tasks.set_activity(task, "working")
      callback(nil, session.id)
      poll_statuses()
    end)
  end)
end

function M.abort(task)
  if not task.session_id or not state.ready then
    return
  end
  curl_request("POST", "/session/" .. task.session_id .. "/abort", {}, task.root, function() end)
end

function M.attach_spec(task)
  return {
    command = {
      config_module.get().opencode.command,
      "attach",
      state.url,
      "--dir",
      task.root,
      "--session",
      task.session_id,
      "--password",
      state.password,
    },
    cwd = task.root,
  }
end

function M.server_info()
  return { ready = state.ready, url = state.url, port = state.port }
end

function M.shutdown()
  state.stopping = true
  state.ready = false
  state.starting = false
  if poll_timer and not poll_timer:is_closing() then
    poll_timer:stop()
    poll_timer:close()
  end
  poll_timer = nil
  if state.process then
    pcall(state.process.kill, state.process, 15)
  end
  state.process = nil
  bridge.stop()
end

return M
