.PHONY: check

# Lua syntax and TOC checks, as CI runs them (needs sh and Lua 5.1's luac).
check:
	sh scripts/check.sh
