-- Unit tests for the SSE frame parser and streaming. Run: nvim -l tests/sse_spec.lua
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local sse = require("opencode-nvim.sse")
local http = require("opencode-nvim.http")

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

local function parse(frame)
  local events = {}
  sse.parse_frame(frame, function(event) events[#events + 1] = event end)
  return events
end

--------------------------------------------------------------------------------

test("parses a data frame", function()
  local events = parse('data: {"id":"evt_1","type":"server.connected","data":{}}')
  assert(#events == 1, #events)
  assert(events[1].type == "server.connected", vim.inspect(events[1]))
end)

test("ignores heartbeat comments", function()
  local events = parse(": heartbeat")
  assert(#events == 0, #events)
end)

test("ignores malformed json", function()
  local events = parse("data: {not json")
  assert(#events == 0, #events)
end)

test("joins multiple data lines", function()
  local events = parse('data: {"type":"a.b",\ndata: "data":{"n":1}}')
  assert(#events == 1, #events)
  assert(events[1].type == "a.b", vim.inspect(events[1]))
  assert(events[1].data.n == 1, vim.inspect(events[1]))
end)

test("handles a payload with code fences", function()
  local frame = 'data: {"type":"session.text.delta","data":{"delta":"```lua\\nprint(1)\\n```"}}'
  local events = parse(frame)
  assert(#events == 1, #events)
  assert(events[1].data.delta:find("print(1)", 1, true), events[1].data.delta)
end)

test("streams frames split across chunks", function()
  local server = uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  local addr = server:getsockname()
  local port = addr.port

  server:listen(8, function()
    local client = uv.new_tcp()
    server:accept(client)
    client:read_start(function(_, data)
      if not data then return end
      client:read_stop()
      -- Deliberately split a frame in the middle.
      local payload = 'data: {"type":"session.text.delta","data":{"delta":"oi"}}\n\n'
      local cut = 20
      client:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      local function chunk(text)
        return string.format("%x\r\n%s\r\n", #text, text)
      end
      client:write(chunk(payload:sub(1, cut)))
      local timer = uv.new_timer()
      timer:start(20, 0, function()
        client:write(chunk(payload:sub(cut + 1)))
        client:write("0\r\n\r\n")
        timer:close()
      end)
    end)
  end)

  local received, done = {}, false
  local handle = http.stream({ host = "127.0.0.1", port = port }, "/api/event", {
    on_chunk = function(chunk)
      table.insert(received, chunk)
    end,
    on_end = function() done = true end,
  })
  assert(vim.wait(3000, function() return done end, 10), "timeout no stream")
  handle.close()
  local text = table.concat(received)
  assert(text:find("session.text.delta", 1, true), text)
  server:close()
end)

test("status reports off by default", function()
  assert(sse.status() == "off", sse.status())
end)

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
