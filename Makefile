NVIM ?= nvim

.PHONY: test e2e lint tags

test: lint
	$(NVIM) -l tests/discovery_spec.lua
	$(NVIM) -l tests/http_spec.lua
	$(NVIM) -l tests/sse_spec.lua
	$(NVIM) -l tests/form_spec.lua
	$(NVIM) -l tests/panel_spec.lua

e2e:
	$(NVIM) -l tests/e2e.lua

e2e-approval:
	$(NVIM) -l tests/e2e_approval.lua

probe:
	$(NVIM) -l tests/probe_permissions.lua

lint:
	$(NVIM) -l tests/lint.lua

ui-smoke:
	tests/ui_smoke.sh

e2e-form:
	$(NVIM) -l tests/e2e_form.lua

probe-hang:
	PROBE_SECONDS=90 $(NVIM) -l tests/probe_hang.lua

e2e-panel:
	$(NVIM) -l tests/e2e_panel.lua

tags:
	$(NVIM) --headless -c "helptags doc" -c "qa!"
