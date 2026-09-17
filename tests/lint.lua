-- Static checks: every file loads, and no local is used before its definition.
--
-- The second one is not pedantry: a `local function` declared after its use
-- resolves to a *global*, so it fails at the worst possible moment (inside a
-- callback). It has bitten this plugin three times, always in code that the
-- headless tests cannot reach. Run with: make lint
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local failures = 0
local function fail(message)
  failures = failures + 1
  io.write("FAIL " .. message .. "\n")
end

local files = vim.fn.glob(root .. "/lua/**/*.lua", false, true)
vim.list_extend(files, vim.fn.glob(root .. "/tests/*.lua", false, true))
vim.list_extend(files, vim.fn.glob(root .. "/plugin/*.lua", false, true))

for _, file in ipairs(files) do
  local chunk, err = loadfile(file)
  if not chunk then
    fail(string.format("%s: %s", file, tostring(err)))
  end
end
io.write(string.format("ok  %d files loaded\n", #files))

for _, file in ipairs(files) do
  local lines = vim.fn.readfile(file)
  -- local names, the line where they are first defined, and how many times
  local defined, definitions = {}, {}
  for index, line in ipairs(lines) do
    local name = line:match("^%s*local function%s+([%w_]+)") or line:match("^%s*local%s+([%w_]+)%s*=")
    if name then
      definitions[name] = (definitions[name] or 0) + 1
      if not defined[name] then defined[name] = index end
    end
  end
  -- a name defined more than once may be redefined in inner scopes (callbacks,
  -- inline closures), where this static heuristic cannot tell the scopes apart
  for name, count in pairs(definitions) do
    if count > 1 then defined[name] = nil end
  end
  for name, at in pairs(defined) do
    for index = 1, at - 1 do
      local line = lines[index]
      local is_comment = line:match("^%s*%-%-")
      if not is_comment and not line:match("local%s+" .. vim.pesc(name) .. "%f[%W]")
        and line:match("%f[%w_]" .. vim.pesc(name) .. "%s*%(") and not line:match("[%w_%.]" .. vim.pesc(name)) then
        -- a parameter or an earlier local with the same name is a false positive;
        -- only report when the name is not declared anywhere before
        local declared_before = false
        for earlier = 1, index - 1 do
          if lines[earlier]:match("%f[%w_]local%s+" .. vim.pesc(name) .. "%f[%W]") or
            lines[earlier]:match("function%s+[%w_%.]*" .. vim.pesc(name) .. "%s*%(") or
            lines[earlier]:match("[%(%s,]" .. vim.pesc(name) .. "%s*[,%)]") then
            declared_before = true
            break
          end
        end
        if not declared_before then
          fail(string.format("%s:%d: '%s' is used before it is defined (line %d)", file, index, name, at))
        end
      end
    end
  end
end

io.write(string.format("\n%d problemas\n", failures))
os.exit(failures == 0 and 0 or 1)
