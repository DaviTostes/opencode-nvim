NVIM ?= nvim

.PHONY: test e2e lint tags

test:
	$(NVIM) -l tests/http_spec.lua
	$(NVIM) -l tests/sse_spec.lua
	$(NVIM) -l tests/panel_spec.lua

e2e:
	$(NVIM) -l tests/e2e.lua

e2e-approval:
	$(NVIM) -l tests/e2e_approval.lua

probe:
	$(NVIM) -l tests/probe_permissions.lua

e2e-panel:
	$(NVIM) -l tests/e2e_panel.lua

lint:
	$(NVIM) --headless -c "lua vim.tbl_map(function(f) local c, e = loadfile(f); if not c then print('SYNTAX '..f..': '..tostring(e)) end end, vim.fn.glob('lua/**/*.lua', false, true))" -c "qa!"

tags:
	$(NVIM) --headless -c "helptags doc" -c "qa!"
