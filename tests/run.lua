local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fs.dirname(vim.fs.normalize(source))
local root = vim.fs.dirname(tests_dir)

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local tests = {}

_G.test = function(name, callback)
  tests[#tests + 1] = { name = name, callback = callback }
end

local function inspect(value)
  return vim.inspect(value, { newline = " ", indent = "" })
end

_G.assert_equal = function(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error((message and (message .. ": ") or "")
      .. "expected " .. inspect(expected) .. ", got " .. inspect(actual), 2)
  end
end

_G.assert_truthy = function(value, message)
  if not value then
    error(message or ("expected a truthy value, got " .. inspect(value)), 2)
  end
end

_G.assert_falsy = function(value, message)
  if value then
    error(message or ("expected a falsy value, got " .. inspect(value)), 2)
  end
end

dofile(tests_dir .. "/range_spec.lua")
dofile(tests_dir .. "/task_spec.lua")
dofile(tests_dir .. "/bridge_spec.lua")
dofile(tests_dir .. "/setup_spec.lua")

local failures = {}
for _, case in ipairs(tests) do
  local ok, err = xpcall(case.callback, debug.traceback)
  if ok then
    io.stdout:write("ok - " .. case.name .. "\n")
  else
    failures[#failures + 1] = case.name
    io.stderr:write("not ok - " .. case.name .. "\n" .. err .. "\n")
  end
end

io.stdout:write(("\n%d tests, %d failures\n"):format(#tests, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("quitall!")
