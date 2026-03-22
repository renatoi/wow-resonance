.PHONY: lint format format-check update-globals

# Download/update WoW API globals for luacheck
update-globals:
	python3 tools/update_wow_globals.py

# Run luacheck (downloads globals if missing)
lint: .luacheckrc_wow
	luacheck Core.lua Options.lua Locales.lua data/ Resonance_Data/data/

# Format source files in-place (data/ excluded via stylua.toml)
format:
	stylua .

# Check formatting without modifying files
format-check:
	stylua --check .

# Auto-download globals if missing
.luacheckrc_wow:
	python3 tools/update_wow_globals.py
