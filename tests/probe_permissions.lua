-- Free probe: how do permissions actually get enforced?
-- Creates sessions and inspects config/agents. No model calls.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local api = require("opencode-nvim.api")
local event = require("opencode-nvim.event")

event.start()

local function step(name, fn, timeout)
  io.write("== " .. name .. "\n")
  local done, err = false, nil
  fn(function(e) err = e; done = true end)
  if not vim.wait(timeout or 15000, function() return done end, 20) then
    io.write("   TIMEOUT\n"); return nil
  end
  if err then
    io.write("   ERRO: " .. (type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)) .. "\n")
    return nil
  end
  return true
end

step("agentes", function(cb)
  api.agents(function(err, agents)
    if err then return cb(err) end
    for _, agent in ipairs(agents or {}) do
      io.write(string.format("   id=%-14s mode=%-10s keys=%s\n", tostring(agent.id), tostring(agent.mode),
        vim.inspect(vim.tbl_keys(agent))))
      if agent.permissions then io.write("      permissions=" .. vim.inspect(agent.permissions) .. "\n") end
    end
    cb(nil)
  end)
end)

local created = {}
step("criar sessão com permissions edit/shell = ask", function(cb)
  api.create_session({
    location = { directory = vim.fn.tempname() },
    agent = "build",
    permissions = {
      { action = "*", resource = "*", effect = "allow" },
      { action = "edit", resource = "*", effect = "ask" },
      { action = "shell", resource = "*", effect = "ask" },
    },
    title = "probe permissions",
  }, function(err, info)
    if err then return cb(err) end
    created[#created + 1] = info.id
    io.write("   criada " .. info.id .. "\n")
    io.write("   resposta.permissions = " .. vim.inspect(info.permissions) .. "\n")
    api.get_session(info.id, function(err2, fresh)
      if err2 then return cb(err2) end
      io.write("   GET .permissions     = " .. vim.inspect(fresh.permissions) .. "\n")
      io.write("   GET .agent=" .. tostring(fresh.agent) .. " keys=" .. vim.inspect(vim.tbl_keys(fresh)) .. "\n")
      cb(nil)
    end)
  end)
end)

step("config global", function(cb)
  api.raw({ method = "GET", path = "/api/config" }, function(err, decoded)
    if err then return cb(err) end
    local config = type(decoded) == "table" and (decoded.data or decoded) or decoded
    io.write("   keys: " .. vim.inspect(vim.tbl_keys(config)) .. "\n")
    io.write("   permissions: " .. vim.inspect((config or {}).permissions) .. "\n")
    io.write("   agents: " .. vim.inspect((config or {}).agents) .. "\n")
    cb(nil)
  end)
end)

for _, id in ipairs(created) do
  step("limpar " .. id, function(cb)
    api.delete_session(id, function() cb(nil) end)
  end)
end

os.exit(0)
