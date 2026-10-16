.PHONY: test lint

test:
	nvim --headless --clean -u tests/minimal_init.lua -l tests/run.lua

lint:
	stylua --check lua plugin tests
