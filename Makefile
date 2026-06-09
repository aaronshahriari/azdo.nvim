.PHONY: test

# Self-contained tests: no Neovim source build required, just a `nvim` on PATH.
test:
	nvim -l test/az_spec.lua
