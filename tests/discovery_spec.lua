-- Discovery tests. Run with: nvim -l tests/discovery_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local failures = 0
local function report(name, ok, detail)
  if ok then
    io.write("ok   - " .. name .. "\n")
  else
    failures = failures + 1
    io.write("FAIL - " .. name .. "\n       " .. tostring(detail) .. "\n")
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  report(name, ok, err)
end

--- A state dir with the real service registration (if there is one).
local function real_service()
  local path = vim.fs.joinpath(vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state"),
    "opencode", "service.json")
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
  return lines and require("opencode-nvim.util").decode(table.concat(lines, "\n")) or nil
end

test("resolves a registered service", function()
  local service = real_service()
  if not service then
    io.write("skip - no service.json on this machine\n")
    return
  end
  local cfg = require("opencode-nvim.config")
  local discovery = require("opencode-nvim.discovery")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ vim.json.encode(service) }, vim.fs.joinpath(dir, "service.json"))
  cfg.setup({ server = { state_dir = dir } })
  discovery.reset()

  local done, err, server = false, nil, nil
  discovery.resolve(function(e, s)
    err, server, done = e, s, true
  end)
  assert(vim.wait(20000, function() return done end, 50), "resolve never returned")
  assert(err == nil, vim.inspect(err))
  assert(server and server.port, vim.inspect(server))
  vim.fn.delete(dir, "rf")
end)

test("autostart failure is reported, not a crash", function()
  local cfg = require("opencode-nvim.config")
  local discovery = require("opencode-nvim.discovery")
  -- An empty state dir (no service.json) and a command that always fails: the
  -- retry loop must run and end with an error instead of calling a nil global.
  cfg.setup({ server = { command = "false", state_dir = vim.fn.tempname(), start_timeout = 1500 } })
  discovery.reset()

  local done, err = false, nil
  discovery.resolve(function(e)
    err, done = e, true
  end)
  assert(vim.wait(20000, function() return done end, 100),
    "resolve never returned (did the autostart retry loop crash?)")
  assert(type(err) == "string", vim.inspect(err))
end)

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
