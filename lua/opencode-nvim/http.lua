local uv = vim.uv or vim.loop
local log = require("opencode-nvim.log")

--- Tiny HTTP/1.1 client over `vim.uv`, enough for the OpenCode API on
--- localhost. Handles `content-length`, `chunked` and connection-close
--- bodies, plus streaming responses for SSE.
local M = {}

---@class opencode.http.Server
---@field host string
---@field port integer
---@field password? string
---@field url? string

---@param url string
---@return string? host
---@return integer? port
---@return string? err
function M.url_parts(url)
  if type(url) ~= "string" then return nil, nil, "invalid url" end
  if url:sub(1, 5) == "https" then
    return nil, nil, "https não é suportado (use o servidor local em http)"
  end
  local host, port = url:match("^http://([^:/]+):(%d+)")
  if not host then
    host, port = url:match("^http://([^:/]+)")
    port = port or 80
  end
  if not host then
    host, port = url:match("^([^:/]+):(%d+)")
    port = port or 80
  end
  if not host then return nil, nil, "url inválida: " .. url end
  return host, tonumber(port) or 80
end

--------------------------------------------------------------------------------
-- Response parser
--------------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

---@param cb fun(err: string?, status: integer?, headers: table, body: string)
---@param stream boolean? skip body accumulation
function Parser.new(cb, stream)
  return setmetatable({
    state = "headers",
    buf = "",
    status = nil,
    headers = {},
    body = {},
    cb = cb,
    stream = stream or false,
    done = false,
    remaining = 0,
    on_data = nil,
  }, Parser)
end

function Parser:_finish(err)
  if self.done then return end
  self.done = true
  self.cb(err, self.status, self.headers, table.concat(self.body))
end

function Parser:_headers(raw)
  local first, rest = raw:match("^(.-)\r?\n(.*)$")
  if not first then first, rest = raw, "" end
  self.status = tonumber(first:match("^HTTP/%d%.%d%s+(%d+)")) or 0
  for line in rest:gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w%-_]+):%s*(.*)$")
    if key then self.headers[key:lower()] = value end
  end

  local encoding = (self.headers["transfer-encoding"] or ""):lower()
  local length = tonumber(self.headers["content-length"])
  if encoding:find("chunked", 1, true) then
    self.state = "chunked"
  elseif length then
    self.state = "length"
    self.remaining = length
  else
    self.state = "eof"
  end
end

---@return boolean needs_more
function Parser:_chunk()
  local nl = self.buf:find("\r\n", 1, true)
  local skip = 2
  if not nl then
    nl = self.buf:find("\n", 1, true)
    skip = 1
  end
  if not nl then return false end

  local size = tonumber(self.buf:sub(1, nl - 1):match("^%x+") or "", 16)
  if not size then
    self:_finish("chunk header inválido")
    return true
  end

  local start = nl + skip
  if size == 0 then
    self.buf = self.buf:sub(start)
    self:_finish(nil)
    return true
  end

  if #self.buf < start + size + 1 then return false end

  local data = self.buf:sub(start, start + size - 1)
  if self.on_data then
    self.on_data(data)
  elseif not self.stream then
    self.body[#self.body + 1] = data
  end
  self.buf = self.buf:sub(start + size + 2)
  return true
end

function Parser:feed(chunk)
  if self.done then return end
  self.buf = self.buf .. chunk

  while not self.done do
    if self.state == "headers" then
      local index = self.buf:find("\r\n\r\n", 1, true)
      local skip = 4
      if not index then
        index = self.buf:find("\n\n", 1, true)
        skip = 2
      end
      if not index then return end
      local raw = self.buf:sub(1, index - 1)
      self.buf = self.buf:sub(index + skip)
      self:_headers(raw)
    elseif self.state == "chunked" then
      if not self:_chunk() then return end
    elseif self.state == "length" then
      if #self.buf < self.remaining then
        if self.on_data and #self.buf > 0 then
          self.on_data(self.buf)
          self.remaining = self.remaining - #self.buf
          self.buf = ""
        end
        return
      end
      local data = self.buf:sub(1, self.remaining)
      if self.on_data then
        self.on_data(data)
      else
        self.body[#self.body + 1] = data
      end
      self.buf = self.buf:sub(self.remaining + 1)
      self:_finish(nil)
    elseif self.state == "eof" then
      if #self.buf > 0 then
        if self.on_data then
          self.on_data(self.buf)
        else
          self.body[#self.body + 1] = self.buf
        end
        self.buf = ""
      end
      return
    else
      return
    end
  end
end

function Parser:eof()
  if self.done then return end
  if self.state == "length" and self.remaining > 0 then
    return self:_finish("conexão encerrada antes do corpo completo")
  end
  if self.state == "eof" and #self.buf > 0 then
    if self.on_data then
      self.on_data(self.buf)
    else
      self.body[#self.body + 1] = self.buf
    end
    self.buf = ""
  end
  self:_finish(nil)
end

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

---@class opencode.http.Opts
---@field method? string
---@field path string
---@field body? string|table
---@field accept? string
---@field timeout? integer|nil false disables
---@field keep_alive? boolean
---@field stream? boolean
---@field on_chunk? fun(chunk: string)

--- Perform a request. Returns a handle with `cancel()`.
---@param server opencode.http.Server
---@param opts opencode.http.Opts
---@param cb fun(err: string?, status: integer?, headers: table, body: string)
---@return { cancel: fun() }
function M.request(server, opts, cb)
  local host = server.host or "127.0.0.1"
  local port = server.port or 4096
  local method = opts.method or "GET"
  local path = opts.path or "/"
  if path:sub(1, 1) ~= "/" then path = "/" .. path end

  local body = opts.body
  if type(body) == "table" then body = vim.json.encode(body) end

  local lines = {
    string.format("%s %s HTTP/1.1", method, path),
    string.format("Host: %s:%d", host, port),
    "Accept: " .. (opts.accept or "application/json"),
    "User-Agent: opencode-nvim/0.1.0",
    opts.keep_alive and "Connection: keep-alive" or "Connection: close",
  }
  if server.password then
    lines[#lines + 1] = "Authorization: Basic " .. vim.base64.encode("opencode:" .. server.password)
  end
  if body then
    lines[#lines + 1] = "Content-Type: application/json"
    lines[#lines + 1] = "Content-Length: " .. #body
  end

  local payload = table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")

  local conn = uv.new_tcp()
  local finished = false
  local timer
  local timeout = opts.timeout
  if timeout == nil then timeout = 30000 end

  local function finish(err, status, headers, text)
    if finished then return end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    pcall(function() conn:read_stop() end)
    pcall(function() conn:close() end)
    local callback = cb
    if not callback then return end
    vim.schedule(function()
      callback(err, status, headers, text)
    end)
  end

  local parser = Parser.new(finish, opts.stream)
  parser.on_data = opts.on_chunk

  conn:connect(host, port, function(connect_err)
    if finished then return end
    if connect_err then return finish("conexão falhou: " .. tostring(connect_err)) end
    conn:write(payload, function(write_err)
      if finished then return end
      if write_err then return finish("escrita falhou: " .. tostring(write_err)) end
      conn:read_start(function(read_err, data)
        if finished then return end
        if read_err then return finish("leitura falhou: " .. tostring(read_err)) end
        if data then
          parser:feed(data)
        else
          parser:eof()
        end
      end)
    end)
  end)

  if timeout and timeout > 0 then
    timer = uv.new_timer()
    timer:start(timeout, 0, function()
      finish("timeout")
    end)
  end

  return {
    cancel = function()
      finish("cancelado")
    end,
  }
end

---@param server opencode.http.Server
---@param path string
---@param cb fun(err: string?, status: integer?, headers: table, body: string)
function M.get(server, path, cb, timeout)
  return M.request(server, { method = "GET", path = path, timeout = timeout }, cb)
end

---@param server opencode.http.Server
---@param path string
---@param body table|string
---@param cb fun(err: string?, status: integer?, headers: table, body: string)
function M.post(server, path, body, cb, timeout)
  return M.request(server, { method = "POST", path = path, body = body, timeout = timeout }, cb)
end

--- Streaming GET (used for SSE). `opts.on_chunk` receives raw decoded bytes
--- and `opts.on_end(err)` fires when the stream closes.
---@param server opencode.http.Server
---@param path string
---@param opts { on_chunk: fun(chunk: string), on_end: fun(err: string?) }
---@return { close: fun() }
function M.stream(server, path, opts)
  local handle = { closed = false }
  local request = M.request(server, {
    method = "GET",
    path = path,
    accept = "text/event-stream",
    keep_alive = true,
    stream = true,
    timeout = 0,
    on_chunk = opts.on_chunk,
  }, function(err, status, headers)
    if handle.closed then return end
    handle.closed = true
    if err then
      if opts.on_end then opts.on_end(err) end
    elseif status and (status < 200 or status >= 300) then
      if opts.on_end then opts.on_end("status " .. tostring(status)) end
    else
      if opts.on_end then opts.on_end(nil, status, headers) end
    end
  end)

  handle.close = function()
    if handle.closed then return end
    handle.closed = true
    request.cancel()
  end

  return handle
end

return M
