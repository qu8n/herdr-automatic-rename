# herdr-automatic-rename developer tasks.

.PHONY: test lint

# Run the full test suite (needs bash + jq only).
test:
	@./tests/run.sh

# Optional static analysis, if shellcheck is installed. The shell hooks are
# per-shell (zsh/fish) so only the portable bash sources are checked.
lint:
	@command -v shellcheck >/dev/null 2>&1 \
		&& shellcheck -s bash automatic-rename.sh naming.sh shell/hook.bash tests/*.sh \
		|| echo "shellcheck not installed; skipping"
