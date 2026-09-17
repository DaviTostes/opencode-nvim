-- Unit tests for the HTTP client. Run with: nvim -l tests/http_spec.lua
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

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

--- Fake HTTP server. `respond(client, request)` runs on the first read.
local function serve(respond)
  local server = uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  server:listen(8, function(err)
    assert(not err, err)
    local client = uv.new_tcp()
    server:accept(client)
    local buffer = ""
    client:read_start(function(read_err, data)
      if read_err then return end
      if not data then return end
      buffer = buffer .. data
      if buffer:find("\r\n\r\n", 1, true) then
        client:read_stop()
        respond(client, buffer)
      end
    end)
  end)
  local addr = server:getsockname()
  return server, addr.port
end

local function with_server(respond, fn)
  local server, port = serve(respond)
  local ok, err = pcall(fn, { host = "127.0.0.1", port = port, password = "secret" })
  pcall(function()
    server:close()
  end)
  if not ok then error(err) end
end

local function wait_for(condition, timeout)
  vim.wait(timeout or 3000, condition, 10)
  return condition()
end

--------------------------------------------------------------------------------

test("url_parts parses host and port", function()
  local host, port = http.url_parts("http://127.0.0.1:49374")
  assert(host == "127.0.0.1", host)
  assert(port == 49374, port)
end)

test("url_parts rejects https", function()
  local host, _, err = http.url_parts("https://example.com")
  assert(host == nil and err ~= nil)
end)

test("content-length response", function()
  local body = '{"data":{"healthy":true}}'
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
  end, function(server)
    local done, result = false, nil
    http.request(server, { method = "GET", path = "/api/health" }, function(err, status, _, text)
      result = { err = err, status = status, text = text }
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(result.err == nil, result.err)
    assert(result.status == 200, result.status)
    assert(result.text == body, result.text)
  end)
end)

test("sends basic auth header", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
  end, function(server)
    local done, request = false, nil
    local server2, port = serve(function(client, req)
      request = req
      client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
    end)
    local s = { host = "127.0.0.1", port = port, password = "secret" }
    http.request(s, { method = "GET", path = "/x" }, function() done = true end)
    assert(wait_for(function() return done end), "timeout")
    assert(request:find("Authorization: Basic " .. vim.base64.encode("opencode:secret"), 1, true), request)
    assert(request:find("Connection: close", 1, true), request)
    server2:close()
  end)
end)

test("chunked response delivered incrementally", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
    local parts = { "hello ", "chunked ", "world" }
    local index = 0
    local timer = uv.new_timer()
    timer:start(10, 15, function()
      index = index + 1
      if index <= #parts then
        local part = parts[index]
        client:write(string.format("%x\r\n%s\r\n", #part, part))
      else
        client:write("0\r\n\r\n")
        timer:stop()
        timer:close()
      end
    end)
  end, function(server)
    local chunks, done = {}, false
    http.request(server, {
      method = "GET",
      path = "/stream",
      stream = true,
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end,
    }, function(err)
      assert(err == nil, err)
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(#chunks >= 3, "expected incremental chunks, got " .. #chunks)
    assert(table.concat(chunks) == "hello chunked world", table.concat(chunks))
  end)
end)

test("content-length body arriving in several writes", function()
  -- The parser is allowed to accumulate the pieces without concatenating them
  -- (that is the O(n²) path a large response used to take), so the body has to
  -- come out in one piece at the end anyway.
  local body = string.rep("ab", 300)
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n")
    local parts = { body:sub(1, 100), body:sub(101, 300), body:sub(301, 500), body:sub(501) }
    local index = 0
    local timer = uv.new_timer()
    timer:start(10, 15, function()
      index = index + 1
      if index <= #parts then
        client:write(parts[index])
      else
        timer:stop()
        timer:close()
      end
    end)
  end, function(server)
    local done, text, status = false, nil, nil
    http.request(server, { method = "GET", path = "/big" }, function(err, code, _, got)
      assert(err == nil, err)
      status, text, done = code, got, true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(status == 200, status)
    assert(text == body, string.format("body mismatch: %s bytes instead of %d", tostring(text and #text), #body))
  end)
end)

test("chunked response with bare LF terminators", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
    -- Non-compliant but seen in the wild: the size line and the data are
    -- terminated by a single LF, so a fixed CRLF skip would eat the next size.
    client:write("2\n{}\n0\n\n")
  end, function(server)
    local done, text = false, nil
    http.request(server, { method = "GET", path = "/x" }, function(err, _, _, body)
      assert(err == nil, err)
      text = body
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(text == "{}", text)
  end)
end)

test("connection-close body", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\n\r\nno length here")
    client:close()
  end, function(server)
    local done, text = false, nil
    http.request(server, { method = "GET", path = "/x" }, function(err, status, _, body)
      assert(err == nil, err)
      assert(status == 200, status)
      text = body
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(text == "no length here", text)
  end)
end)

test("error status is surfaced", function()
  with_server(function(client)
    client:write('HTTP/1.1 404 Not Found\r\nContent-Length: 17\r\n\r\n{"message":"nope"}')
  end, function(server)
    local done, status = false, nil
    http.request(server, { method = "GET", path = "/x" }, function(_, s)
      status = s
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(status == 404, status)
  end)
end)

test("timeout is reported", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
  end, function(server)
    local done, err = false, nil
    http.request(server, { method = "GET", path = "/x", timeout = 150 }, function(e)
      err = e
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(err == "timeout", tostring(err))
  end)
end)

test("POST sends a JSON body", function()
  local server, port = serve(function(client, req)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
    _G.__request = req
  end)
  local s = { host = "127.0.0.1", port = port }
  local done = false
  http.request(s, { method = "POST", path = "/api/session", body = { text = "hi" } }, function() done = true end)
  assert(wait_for(function() return done end), "timeout")
  assert(_G.__request:find('{"text":"hi"}', 1, true), _G.__request)
  assert(_G.__request:find("Content-Length: 13", 1, true), _G.__request)
  server:close()
end)

test("chunked response for a body-length request", function()
  with_server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
  end, function(server)
    local done, text = false, nil
    http.request(server, { method = "GET", path = "/x" }, function(err, _, _, body)
      assert(err == nil, err)
      text = body
      done = true
    end)
    assert(wait_for(function() return done end), "timeout")
    assert(text == "{}", text)
  end)
end)

io.write(string.format("\n%d failure(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
