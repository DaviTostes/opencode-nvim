--- Reads an image from the system clipboard or from a file.
---
--- Mirrors what the OpenCode TUI does: the platform clipboard tools are tried in
--- order and the clipboard result is normalized to PNG, so the server only ever
--- sees image/png.
local M = {}

--- Run a command and return its raw stdout, or nil when it fails or is empty.
---@param argv string[]
---@param timeout integer
---@return string?
local function capture(argv, timeout)
  local ok, result = pcall(function()
    -- text = false: the image bytes are binary and must not be decoded as UTF-8.
    local process = vim.system(argv, { text = false })
    local completed = process:wait(timeout)
    -- `wait` gives up on the timeout but leaves the process running (a blocked
    -- clipboard tool would otherwise hang around); kill it.
    if not completed then pcall(function() process:kill("sigkill") end) end
    return completed
  end)
  if not ok or type(result) ~= "table" or result.code ~= 0 then return nil end
  local out = result.stdout
  if type(out) ~= "string" or out == "" then return nil end
  return out
end

local function as_image(data)
  if type(data) ~= "string" or data == "" then return nil end
  return { data = vim.base64.encode(data), mime = "image/png" }
end

--- macOS: ask osascript to write the clipboard PNG to a temp file.
---@return table?
local function macos()
  local path = vim.fn.tempname() .. ".png"
  local quoted = string.format('POSIX file "%s"', path)
  pcall(function()
    vim.system({
      "osascript",
      "-e", 'set imageData to the clipboard as "PNGf"',
      "-e", string.format("set fileRef to open for access %s with write permission", quoted),
      "-e", "set eof fileRef to 0",
      "-e", "write imageData to fileRef",
      "-e", "close access fileRef",
    }, { text = true }):wait(3000)
  end)
  local data = vim.fn.filereadable(path) == 1 and vim.fn.readblob(path) or nil
  vim.fn.delete(path)
  if type(data) == "string" and #data > 0 then
    return { data = vim.base64.encode(data), mime = "image/png" }
  end
  return nil
end

--- Windows (and WSL): PowerShell saves the clipboard bitmap as base64 PNG.
---@return table?
local function windows()
  local script = table.concat({
    "Add-Type -AssemblyName System.Windows.Forms;",
    "$img = [System.Windows.Forms.Clipboard]::GetImage();",
    "if ($img) { $ms = New-Object System.IO.MemoryStream;",
    "$img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png);",
    "[System.Convert]::ToBase64String($ms.ToArray()) }",
  }, " ")
  local out = capture({ "powershell.exe", "-NonInteractive", "-NoProfile", "-command", script }, 5000)
  if not out then return nil end
  out = vim.trim(out)
  if out == "" then return nil end
  return { data = out, mime = "image/png" }
end

--- Grab the clipboard image.
---@return { data: string, mime: string }? image base64 data (no data: prefix)
---@return string? err
function M.image()
  local os = jit and jit.os or ""
  if os == "OSX" then return macos() end
  if os == "Windows" or vim.fn.has("wsl") == 1 then return windows() end

  local image = as_image(capture({ "wl-paste", "-t", "image/png" }, 1500))
  if image then return image end
  image = as_image(capture({ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }, 1500))
  if image then return image end
  return nil, "no image in the clipboard"
end

--- Read an image file as an attachment payload.
---@param path string
---@return { data: string, mime: string, name: string }? image
---@return string? err
function M.file(path)
  if not path or path == "" then return nil, "no image path given" end
  if vim.fn.filereadable(path) ~= 1 then return nil, path .. " is not readable" end
  local ext = path:lower():match("%.([%w]+)$") or ""
  local known = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
  }
  local resolved = known[ext]
  if not resolved then
    return nil, string.format("%s is not a supported image (png, jpg, jpeg, gif, webp)", path)
  end
  local data = vim.fn.readblob(path)
  if type(data) ~= "string" or #data == 0 then return nil, "could not read " .. path end
  -- The V2 server rejects a decoded attachment larger than 20 MiB.
  if #data > 20 * 1024 * 1024 then return nil, path .. " is larger than 20 MiB" end
  return { data = vim.base64.encode(data), mime = resolved, name = vim.fn.fnamemodify(path, ":t") }
end

return M
