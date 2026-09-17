local api = require("opencode-nvim.api")
local log = require("opencode-nvim.log")
local session = require("opencode-nvim.session")
local ui = require("opencode-nvim.ui.diff")

--- Turns `permission.asked` events into in-editor approval popups.
local M = {}

local queue = {}
local deferred = {}
local active = nil
local paused = false

local ACTION_LABEL = {
  edit = "edit a file",
  shell = "run a command",
  read = "read a file",
  glob = "list files",
  grep = "search contents",
  webfetch = "fetch a URL",
  websearch = "search the web",
  external_directory = "access an external directory",
  skill = "activate a skill",
  subagent = "call a subagent",
  question = "ask a question",
}

local function label(request)
  return ACTION_LABEL[request.action] or request.action or "action"
end

local function relevant_patches(patches, resources)
  if type(patches) ~= "table" then return {} end
  if type(resources) ~= "table" or #resources == 0 then return patches end
  local out = {}
  for _, patch in ipairs(patches) do
    local file = patch.file or ""
    for _, resource in ipairs(resources) do
      if file == resource
        or file:sub(-#resource) == resource
        or vim.fs.basename(file) == vim.fs.basename(resource) then
        out[#out + 1] = patch
        break
      end
    end
  end
  if #out == 0 then return patches end
  return out
end

--- True when the request is already being shown, queued or deferred.
---
--- The same request arrives twice easily (the `permission.asked` event and the
--- `M.sync` sweep when a session is attached), and two dialogs for one decision
--- is one dialog too many.
local function known(id)
  if active and active.id == id then return true end
  for _, request in ipairs(queue) do
    if request.id == id then return true end
  end
  for _, request in ipairs(deferred) do
    if request.id == id then return true end
  end
  return false
end

local function reply(request, decision, message)
  active = nil
  api.reply_permission(session.id(), request.id, decision, message, function(err)
    if err then
      log.error("failed to reply to the permission: " .. require("opencode-nvim.util").err_text(err))
    end
  end)
  vim.schedule(function()
    if not paused then M.next() end
  end)
end

--- Unified diff for an edit proposal (the tool input has the replacement).
---@return table[]? patches
local function patches_from_edit_input(input, resource)
  if type(input) ~= "table" then return nil end
  local file = input.filePath or input.path or input.file or resource or "?"

  if type(input.oldString) == "string" and type(input.newString) == "string" then
    local ok, patch = pcall(vim.diff, input.oldString, input.newString, {
      result_type = "unified",
      ctxlen = 3,
      header = string.format("--- a/%s\n+++ b/%s", file, file),
    })
    if ok and type(patch) == "string" and patch ~= "" then
      return { { file = file, patch = patch, additions = 0, deletions = 0, status = "modified" } }
    end
  end

  local body = input.content or input.newContent or input.text
  if type(body) == "string" and body ~= "" then
    local lines = {}
    for line in body:gmatch("[^\r\n]*") do lines[#lines + 1] = "+" .. line end
    return {
      {
        file = file,
        patch = string.format("--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n%s", file, #lines, table.concat(lines, "\n")),
        additions = #lines,
        deletions = 0,
        status = "added",
      },
    }
  end

  return nil
end

--- Best-effort diff for a pending edit: the proposal is not on disk yet, so it
--- has to come from the permission payload or from the pending tool call.
---@return table[]? patches FileDiff-shaped
local function patches_from_request(request)
  local meta = request.metadata
  local resource = (request.resources or {})[1]
  if type(meta) ~= "table" then return nil end

  -- Already FileDiff-shaped (whatever the field is called).
  for _, key in ipairs({ "files", "diff", "patches", "changes" }) do
    local value = meta[key]
    if type(value) == "table" and type(value[1]) == "table" then
      local out = {}
      for _, item in ipairs(value) do
        local file = item.file or item.filePath
        if file or item.patch or item.diff then
          out[#out + 1] = {
            file = file or resource or "?",
            patch = item.patch or item.diff or item.content or "",
            additions = item.additions or 0,
            deletions = item.deletions or 0,
            status = item.status or "modified",
          }
        end
      end
      if #out > 0 then return out end
    end
  end

  return patches_from_edit_input(meta, resource)
end

--- The pending tool call carries the proposal (`oldString`/`newString`).
local function pending_patches(request, cb)
  local source = request.source
  if type(source) ~= "table" or not source.id or not session.id() then return cb(nil) end
  api.messages(session.id(), { limit = 5, order = "desc" }, function(err, page)
    if err then return cb(nil) end
    for _, message in ipairs((type(page) == "table" and page.data) or {}) do
      if message.type == "assistant" then
        for _, item in ipairs(message.content or {}) do
          if type(item) == "table" and item.type == "tool" then
            local id = item.id or item.callID or item.toolCallID
            if id == source.id then
              local input = item.input or (item.state and item.state.input)
              return cb(patches_from_edit_input(input, (request.resources or {})[1]), input)
            end
          end
        end
      end
    end
    cb(nil)
  end)
end

--- Show the popup for a request (with diff when it is an edit).
---@param patches? table[]
---@param source? "proposal"|"turn"|"working"
local function present(request, patches, source)
  local resources = request.resources or {}
  local message = request.message

  if request.action == "edit" and patches and #patches > 0 then
    local title = "approve edit"
    if source == "working" then title = "approve edit (current working tree)" end
    ui.patches({
      title = title,
      patches = relevant_patches(patches, resources),
      on_choice = function(choice, text)
        if not choice then
          deferred[#deferred + 1] = request
          active = nil
          paused = true
          log.notify("permission pending — use :OpencodePermissions to decide later")
          return
        end
        reply(request, choice, text)
      end,
    })
    return
  end

  local body = {
    string.format("OpenCode is asking for permission to %s.", label(request)),
    "",
  }
  for _, resource in ipairs(resources) do
    body[#body + 1] = "  " .. tostring(resource)
  end
  if message and message ~= "" then
    body[#body + 1] = ""
    body[#body + 1] = "  " .. tostring(message)
  end

  ui.confirm({
    title = "permission: " .. tostring(request.action),
    body = body,
    on_choice = function(choice, text)
      if not choice then
        deferred[#deferred + 1] = request
        active = nil
        paused = true
        log.notify("permission pending — use :OpencodePermissions to decide later")
        return
      end
      reply(request, choice, text)
    end,
  })
end

function M.next()
  if active or paused or #queue == 0 then return end
  local request = table.remove(queue, 1)
  active = request

  if request.action == "edit" then
    local proposed = patches_from_request(request)
    if proposed then return present(request, proposed, "proposal") end
    pending_patches(request, function(patches)
      if patches and #patches > 0 then return present(request, patches, "proposal") end
      session.diff({ context = 3 }, function(err, diff_patches, source)
        if err then
          log.debug("could not fetch the diff:", require("opencode-nvim.util").err_text(err))
          return present(request, nil)
        end
        present(request, diff_patches, source)
      end)
    end)
  else
    present(request, nil)
  end
end

--- Resume the queue after the user postponed decisions.
function M.resume()
  paused = false
  for _, request in ipairs(deferred) do
    queue[#queue + 1] = request
  end
  deferred = {}
  M.next()
end

function M.pending()
  local out = {}
  if active then out[#out + 1] = active end
  vim.list_extend(out, queue)
  vim.list_extend(out, deferred)
  return out
end

function M.on_event(ev)
  if ev.type == "permission.asked" then
    local request = ev.data or {}
    if not request.id then return end
    -- Only for the session the plugin is driving: without this a TUI session
    -- asking for approval popped a dialog here too.
    local current = session.id()
    if not current or request.sessionID ~= current then
      log.debug("ignoring permission from another session", tostring(request.sessionID))
      return
    end
    if known(request.id) then return end
    queue[#queue + 1] = request
    M.next()
  elseif ev.type == "permission.replied" or ev.type == "permission.rejected" then
    local data = ev.data or {}
    if active and (data.id == active.id or data.requestID == active.id) then
      active = nil
      M.next()
    end
  elseif ev.type == "session.execution.interrupted" or ev.type == "session.execution.failed"
    or ev.type == "session.execution.succeeded" then
    -- The turn is over: any dialog still waiting for an answer is stale.
    if active or #queue > 0 then
      log.debug("dropping stale permission requests after the turn ended")
    end
    active = nil
    queue = {}
    deferred = {}
    paused = false
    require("opencode-nvim.ui.diff").close_if("permission")
  end
end

--- Pick up requests that were already pending when the session attached.
function M.sync(cb)
  if not session.id() then return cb and cb() end
  api.permissions(session.id(), function(err, requests)
    if not err and type(requests) == "table" then
      for _, request in ipairs(requests) do
        if request.id and not known(request.id) then
          queue[#queue + 1] = request
        end
      end
      M.next()
    end
    if cb then cb(err) end
  end)
end

function M.select()
  local pending_requests = M.pending()
  if #pending_requests == 0 then
    log.notify("no pending permissions")
    return
  end
  local items = {}
  for index, request in ipairs(pending_requests) do
    items[#items + 1] = string.format("%d) %s — %s", index, label(request),
      table.concat(request.resources or {}, " "))
  end
  require("opencode-nvim.ui.picker").pick(items, { name = "pending permissions" }, function(choice)
    if not choice then return end
    local index = tonumber(choice:match("^(%d+)"))
    if not index then return end
    queue = {}
    deferred = {}
    active = nil
    paused = false
    queue[1] = pending_requests[index]
    M.next()
  end)
end

return M
