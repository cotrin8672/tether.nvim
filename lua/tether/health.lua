local health = vim.health

local M = {}

local function parse_version(value)
  if type(value) ~= "string" then
    return nil
  end

  local major, minor, patch = value:match("[vV]?(%d+)%.(%d+)%.(%d+)")
  if not major then
    major, minor = value:match("[vV]?(%d+)%.(%d+)")
    patch = "0"
  end
  if not major then
    return nil
  end

  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function version_at_least(actual, minimum)
  for index = 1, 3 do
    if actual[index] ~= minimum[index] then
      return actual[index] > minimum[index]
    end
  end
  return true
end

local function version_string(version)
  return table.concat(version, ".")
end

local function check_neovim()
  local current = vim.version()
  local actual = { current.major, current.minor, current.patch }
  local minimum = { 0, 11, 0 }

  if version_at_least(actual, minimum) then
    health.ok("Neovim " .. version_string(actual) .. " (>= 0.11.0)")
  else
    health.error("Neovim 0.11.0 or newer is required (found " .. version_string(actual) .. ")")
  end
end

local function executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

local function check_curl(config)
  local command = config.opencode.curl
  if executable(command) then
    health.ok("curl executable found: " .. command)
  else
    health.error("curl executable not found: " .. tostring(command), {
      "Install curl and ensure it is available on $PATH.",
      "Alternatively, set `opencode.curl` to the executable path in require('tether').setup().",
    })
  end
end

local function check_opencode(config)
  local command = config.opencode.command
  if not executable(command) then
    health.error("OpenCode executable not found: " .. tostring(command), {
      "Install OpenCode and ensure it is available on $PATH.",
      "Alternatively, set `opencode.command` to the executable path in require('tether').setup().",
    })
    return
  end

  local result = vim.system({ command, "--version" }, { text = true }):wait(5000)
  if result.code ~= 0 then
    local detail = vim.trim(result.stderr or result.stdout or "")
    health.error("Unable to read the OpenCode version" .. (detail ~= "" and ": " .. detail or ""))
    return
  end

  local output = vim.trim((result.stdout and result.stdout ~= "") and result.stdout or (result.stderr or ""))
  local actual = parse_version(output)
  local minimum = parse_version(config.opencode.minimum_version)
  if not actual then
    health.error("Unable to parse the OpenCode version from: " .. output)
    return
  end
  if not minimum then
    health.error("Invalid `opencode.minimum_version`: " .. tostring(config.opencode.minimum_version))
    return
  end

  if version_at_least(actual, minimum) then
    health.ok("OpenCode " .. version_string(actual) .. " (>= " .. version_string(minimum) .. ")")
  else
    health.error(
      "OpenCode " .. version_string(minimum) .. " or newer is required (found " .. version_string(actual) .. ")",
      { "Upgrade OpenCode, or change `opencode.minimum_version` only if the older server API is compatible." }
    )
  end
end

local function check_snacks()
  local ok = pcall(require, "snacks")
  if ok then
    health.ok("Snacks.nvim found (task picker enabled)")
  else
    health.info("Snacks.nvim is not installed; task selection will use vim.ui.select")
  end
end

local function check_opencode_environment()
  if vim.env.OPENCODE_CONFIG_DIR and vim.env.OPENCODE_CONFIG_DIR ~= "" then
    health.warn("OPENCODE_CONFIG_DIR is set; tether's isolated OpenCode server cannot load custom agents or plugins from it", {
      "Global/project configuration, authentication, models, and project instructions are still discovered normally.",
      "Unset OPENCODE_CONFIG_DIR if those custom components are not needed in tether sessions.",
    })
  end

  local inline = vim.env.OPENCODE_CONFIG_CONTENT
  if inline and inline ~= "" then
    local ok, value = pcall(vim.json.decode, inline)
    if ok and type(value) == "table" then
      health.ok("OPENCODE_CONFIG_CONTENT is valid JSON and can be merged")
    else
      health.error("OPENCODE_CONFIG_CONTENT must be strict JSON for tether.nvim", {
        "OpenCode accepts JSONC here, but Neovim's JSON decoder cannot merge comments or trailing commas.",
      })
    end
  end
end

function M.check()
  health.start("tether.nvim")

  local ok, config_module = pcall(require, "tether.config")
  if not ok then
    health.error("Unable to load tether.config: " .. tostring(config_module))
    return
  end

  local config = config_module.get()
  check_neovim()
  check_opencode(config)
  check_curl(config)
  check_snacks()
  check_opencode_environment()
end

return M
