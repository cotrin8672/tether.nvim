local uv = vim.uv or vim.loop
local bridge = require("tether.bridge")

local function http_request(callback, opts)
  bridge.stop()
  local endpoint = bridge.start({
    max_body = 4096,
    handler = callback,
  })
  local port = assert(tonumber(endpoint.url:match(":(%d+)/submit$")))
  local body = opts.body or ""
  local headers = {
    (opts.method or "POST") .. " " .. (opts.path or "/submit") .. " HTTP/1.1",
    "Host: 127.0.0.1:" .. port,
    "Authorization: Bearer " .. (opts.token or endpoint.token),
    "Content-Type: application/json",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }
  local request = table.concat(headers, "\r\n")
  local client = assert(uv.new_tcp())
  local chunks = {}
  local finished = false
  local transport_error

  client:connect("127.0.0.1", port, function(connect_error)
    if connect_error then
      transport_error = tostring(connect_error)
      finished = true
      return
    end
    client:read_start(function(read_error, data)
      if read_error then
        transport_error = tostring(read_error)
        finished = true
        return
      end
      if data then
        chunks[#chunks + 1] = data
        return
      end
      finished = true
      if not client:is_closing() then
        client:close()
      end
    end)
    client:write(request)
  end)

  local completed = vim.wait(3000, function()
    return finished
  end, 10)
  if not client:is_closing() then
    client:close()
  end
  bridge.stop()
  assert_truthy(completed, "timed out waiting for the callback server")
  assert_equal(nil, transport_error)

  local response = table.concat(chunks)
  local status = tonumber(response:match("^HTTP/1%.1 (%d%d%d)"))
  local response_body = response:match("\r\n\r\n(.*)$")
  assert_truthy(status, "callback server returned an invalid HTTP response")
  local decoded = vim.json.decode(response_body)
  return status, decoded, endpoint
end

test("bridge accepts a valid token and submission payload", function()
  local received
  local status, payload = http_request(function(session_id, code)
    received = { session_id = session_id, code = code }
    return true
  end, {
    body = vim.json.encode({ session_id = "session-valid", code = "local x = '猫'" }),
  })

  assert_equal(200, status)
  assert_equal({ ok = true }, payload)
  assert_equal({ session_id = "session-valid", code = "local x = '猫'" }, received)
end)

test("bridge rejects an invalid bearer token before calling the handler", function()
  local calls = 0
  local status, payload = http_request(function()
    calls = calls + 1
    return true
  end, {
    token = "not-the-server-token",
    body = vim.json.encode({ session_id = "session-invalid", code = "code" }),
  })

  assert_equal(401, status)
  assert_equal(false, payload.ok)
  assert_equal("Invalid callback token", payload.error)
  assert_equal(0, calls)
end)

test("bridge returns not found for an unknown endpoint", function()
  local calls = 0
  local status, payload = http_request(function()
    calls = calls + 1
    return true
  end, {
    path = "/unknown",
    body = vim.json.encode({ session_id = "session-unknown", code = "code" }),
  })

  assert_equal(404, status)
  assert_equal(false, payload.ok)
  assert_equal("Unknown endpoint", payload.error)
  assert_equal(0, calls)
end)

test("bridge returns bad request for invalid JSON", function()
  local calls = 0
  local status, payload = http_request(function()
    calls = calls + 1
    return true
  end, {
    body = "{invalid-json",
  })

  assert_equal(400, status)
  assert_equal(false, payload.ok)
  assert_truthy(payload.error:find("Expected JSON", 1, true))
  assert_equal(0, calls)
end)

test("bridge reports handler rejection as a conflict", function()
  local status, payload = http_request(function(session_id, code)
    assert_equal("session-conflict", session_id)
    assert_equal("replacement", code)
    return false, "target changed"
  end, {
    body = vim.json.encode({ session_id = "session-conflict", code = "replacement" }),
  })

  assert_equal(409, status)
  assert_equal(false, payload.ok)
  assert_equal("target changed", payload.error)
end)
