local uv = vim.uv or vim.loop

local M = {}

local server
local token
local handler
local max_body

local reasons = {
  [200] = "OK",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [409] = "Conflict",
  [413] = "Content Too Large",
  [500] = "Internal Server Error",
}

local function random_token(label)
  local seed = table.concat({ label, tostring(uv.hrtime()), tostring(vim.fn.getpid()), tostring(math.random()) }, ":")
  return vim.fn.sha256(seed)
end

local function respond(client, status, payload)
  if client:is_closing() then
    return
  end
  local body = vim.json.encode(payload)
  local response = table.concat({
    ("HTTP/1.1 %d %s"):format(status, reasons[status] or "Error"),
    "Content-Type: application/json",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }, "\r\n")
  client:write(response, function()
    if not client:is_closing() then
      client:shutdown(function()
        if not client:is_closing() then
          client:close()
        end
      end)
    end
  end)
end

local function parse_request(data)
  local header_end = data:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end
  local header = data:sub(1, header_end - 1)
  local request_line = header:match("^([^\r\n]+)")
  local method, path
  if request_line then
    method, path = request_line:match("^(%S+)%s+(%S+)")
  end
  local headers = {}
  for name, value in header:gmatch("\r\n([^:]+):%s*([^\r\n]+)") do
    headers[name:lower()] = value
  end
  local length = tonumber(headers["content-length"] or "0")
  local body_start = header_end + 4
  if #data - body_start + 1 < length then
    return nil
  end
  return {
    method = method,
    path = path,
    headers = headers,
    content_length = length,
    body = data:sub(body_start, body_start + length - 1),
  }
end

local function on_connection(err)
  if err or not server then
    return
  end
  local client = uv.new_tcp()
  server:accept(client)
  local chunks = ""
  client:read_start(function(read_err, data)
    if read_err then
      respond(client, 400, { ok = false, error = tostring(read_err) })
      return
    end
    if not data then
      if not client:is_closing() then
        client:close()
      end
      return
    end
    chunks = chunks .. data
    if #chunks > max_body + 16384 then
      client:read_stop()
      respond(client, 413, { ok = false, error = "Submission exceeds the configured body limit" })
      return
    end
    local request = parse_request(chunks)
    if not request then
      return
    end
    client:read_stop()
    if request.content_length > max_body then
      respond(client, 413, { ok = false, error = "Submission exceeds the configured body limit" })
      return
    end
    if request.method ~= "POST" or request.path ~= "/submit" then
      respond(client, 404, { ok = false, error = "Unknown endpoint" })
      return
    end
    if request.headers.authorization ~= "Bearer " .. token then
      respond(client, 401, { ok = false, error = "Invalid callback token" })
      return
    end
    local ok, payload = pcall(vim.json.decode, request.body)
    if not ok or type(payload) ~= "table" or type(payload.session_id) ~= "string" or type(payload.code) ~= "string" then
      respond(client, 400, { ok = false, error = "Expected JSON with string session_id and code fields" })
      return
    end
    vim.schedule(function()
      local handled, accepted, message = pcall(handler, payload.session_id, payload.code)
      if not handled then
        respond(client, 500, { ok = false, error = tostring(accepted) })
      elseif not accepted then
        respond(client, 409, { ok = false, error = message or "Submission rejected" })
      else
        respond(client, 200, { ok = true })
      end
    end)
  end)
end

function M.start(opts)
  if server then
    local address = server:getsockname()
    return { url = ("http://127.0.0.1:%d/submit"):format(address.port), token = token }
  end
  max_body = opts.max_body
  handler = assert(opts.handler, "callback handler is required")
  token = random_token("tether-callback")
  server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  assert(server:listen(128, on_connection))
  local address = assert(server:getsockname())
  return { url = ("http://127.0.0.1:%d/submit"):format(address.port), token = token }
end

function M.stop()
  if server and not server:is_closing() then
    server:close()
  end
  server = nil
  handler = nil
  token = nil
end

return M
