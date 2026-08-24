vim.opt.runtimepath:prepend(vim.fn.getcwd())

require("tether").setup()

local opencode = require("tether.opencode")
local root = vim.fs.normalize(vim.fn.getcwd())

local function await_request(method, path, body)
  local done, request_error, response
  opencode.request(method, path, body, root, function(err, value)
    request_error = err
    response = value
    done = true
  end)
  assert(vim.wait(20000, function()
    return done
  end, 20), method .. " " .. path .. " timed out")
  assert(not request_error, request_error)
  return response
end

local tool_ids = vim.json.decode(await_request("GET", "/experimental/tool/ids"))
assert(vim.tbl_contains(tool_ids, "tether_submit_target"), "bundled tether tool was not loaded")

local agents = vim.json.decode(await_request("GET", "/agent"))
local has_tether_agent = false
for _, agent in ipairs(agents) do
  if agent.name == "tether" then
    has_tether_agent = true
    break
  end
end
assert(has_tether_agent, "dedicated tether agent was not loaded")

local session = vim.json.decode(await_request("POST", "/session", {
  title = "tether.nvim smoke test",
  agent = "tether",
}))
assert(type(session.id) == "string", "OpenCode did not return a session ID")
await_request("POST", "/session/" .. session.id .. "/abort", {})

opencode.shutdown()
print("OpenCode smoke test passed: tool, agent, session, abort")
