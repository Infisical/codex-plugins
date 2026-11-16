#!/usr/bin/env bash
# End-to-end tests: installs the plugin from this repository into a new, empty Codex home and sends prompts through
# `codex exec`. Prompts that pass are answered by the model, so this needs a logged-in Codex (it links auth.json from
# ~/.codex, or from SOURCE_CODEX_HOME) and makes a few small model requests. Every secret is fake and made at run time.
#
# Usage: tests/test-codex-e2e.sh

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ID="infisical-secret-scanner@infisical"
SOURCE_HOME="${SOURCE_CODEX_HOME:-$HOME/.codex}"
ANSWER="PINEAPPLE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CODEX_HOME="$WORK/codex-home"
mkdir -p "$CODEX_HOME" "$WORK/cwd"
ln -s "$SOURCE_HOME/auth.json" "$CODEX_HOME/auth.json"
DATA="$CODEX_HOME/plugins/data/infisical-secret-scanner-infisical"

passed=0
failed=0
failures=()

random_alnum() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
}

GH1="ghp_$(random_alnum 36)"
GH2="ghp_$(random_alnum 36)"
GH3="ghp_$(random_alnum 36)"

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  failed=$((failed + 1))
  failures+=("$1")
  printf '  FAIL  %s\n' "$1"
  printf '%s\n' "$OUTPUT" | grep -v '^\s*$' | tail -15 | sed 's/^/        /'
}

# Usage: send <prompt> [codex exec options]. Sets OUTPUT and RESULT: blocked (the hook blocked the prompt and the model
# was not called), answered (the prompt reached the model, which Codex shows with "tokens used"), or unknown. The
# model's reply is not checked, because a model can refuse a prompt that holds a credential.
send() {
  local prompt="$1" blocked=0 answered=0
  shift
  OUTPUT="$(cd "$WORK/cwd" && codex exec --skip-git-repo-check -s read-only "$@" "$prompt" </dev/null 2>&1)"
  printf '%s\n' "$OUTPUT" | grep -q '^hook: UserPromptSubmit Blocked' && blocked=1
  printf '%s\n' "$OUTPUT" | grep -q '^tokens used' && answered=1
  case "$blocked$answered" in
    10) RESULT=blocked ;;
    01) RESULT=answered ;;
    *) RESULT=unknown ;;
  esac
}

# Usage: expect <name> <blocked|answered>
expect() {
  [ "$RESULT" = "$2" ] && ok "$1" || fail "$1 (wanted $2, got $RESULT)"
}

hook_ran() {
  printf '%s\n' "$OUTPUT" | grep -q '^hook: UserPromptSubmit'
}

ask() {
  printf '%s Reply with just the word %s and nothing else.' "$1" "$ANSWER"
}

echo "Testing with $(codex --version) in $CODEX_HOME"

echo "Install"
codex plugin marketplace add "$REPO" >/dev/null 2>&1 && ok "marketplace added" || fail "marketplace added"
codex plugin add "$PLUGIN_ID" >/dev/null 2>&1 && ok "plugin installed" || fail "plugin installed"

echo "Before the hook is trusted"
send "$(ask "Token: $GH1.")" --ephemeral
hook_ran && fail "an untrusted hook does not run" || ok "an untrusted hook does not run (Codex sends the prompt)"

echo "Trust"
OUTPUT="$(python3 -I "$REPO/tests/trust-hooks.py" "$PLUGIN_ID" "$WORK/cwd" 2>&1)"
[[ "$OUTPUT" == *"trusted 1 hook(s)"* ]] && ok "hook trusted through codex app-server" || fail "hook trusted through codex app-server"

echo "Prompts"
send "$(ask "Hello.")" --ephemeral
expect "a clean prompt is answered" answered
hook_ran && ok "the trusted hook ran" || fail "the trusted hook ran"
send "$(ask "My token is $GH1.")" --ephemeral
expect "a prompt with a secret is blocked" blocked
send "$(ask "Line one.
Line two has export GITHUB_TOKEN=$GH2 in it.")" --ephemeral
expect "a secret on the second line is blocked" blocked

echo "Allow and disallow"
send "\$infisical-secret-scanner:allow $GH1" --ephemeral
expect "allow is handled by the hook" blocked
[ -n "$(ls "$DATA/allowlist" 2>/dev/null)" ] && ok "allow stored a hash in PLUGIN_DATA" || fail "allow stored a hash in PLUGIN_DATA"
send "$(ask "My token is $GH1.")" --ephemeral
expect "the allowed secret is answered" answered
send "$(ask "Tokens: $GH1 and $GH2.")" --ephemeral
expect "an allowed secret next to another one is blocked" blocked
send "\$infisical-secret-scanner:disallow $GH1" --ephemeral
expect "disallow is handled by the hook" blocked
send "$(ask "My token is $GH1.")" --ephemeral
expect "the disallowed secret is blocked" blocked
send "\$infisical-allow GITHUB_TOKEN=$GH3" --ephemeral
expect "the short allow command is handled by the hook" blocked
send "$(ask "Use $GH3 for it.")" --ephemeral
expect "a secret allowed with the short command is answered" answered
send "\$infisical-disallow GITHUB_TOKEN=$GH3" --ephemeral
expect "the short disallow command is handled by the hook" blocked
send "$(ask "Use $GH3 for it.")" --ephemeral
expect "a secret disallowed with the short command is blocked" blocked

echo "Session files"
send "$(ask "Saved token $GH2.")"
expect "a blocked prompt in a saved session" blocked
if grep -rqF "$GH2" "$CODEX_HOME/sessions" 2>/dev/null; then
  fail "a blocked prompt is not written to the session files"
else
  ok "a blocked prompt is not written to the session files"
fi
marker="marker-$(random_alnum 12)"
send "$(ask "Saved $marker.")"
grep -rqF "$marker" "$CODEX_HOME/sessions" 2>/dev/null &&
  ok "a sent prompt is written to the session files (the check above can find text)" ||
  fail "a sent prompt is written to the session files (the check above can find text)"

echo "Plugin changes"
cache="$(find "$CODEX_HOME/plugins/cache" -path '*infisical-secret-scanner/*/scripts/scan-prompt.sh' | head -1)"
cp "$cache" "$WORK/scan-prompt.sh.bak"
echo "# changed" >>"$cache"
# Codex checks the plugin's contents against the trusted hash when the hook runs. On a mismatch the hook fails, and
# Codex sends the prompt until the user trusts the hook again.
send "$(ask "Token: $GH1.")" --ephemeral
expect "a changed plugin's hook fails until trusted again, and Codex sends the prompt" answered
cp "$WORK/scan-prompt.sh.bak" "$cache"
send "$(ask "Token: $GH1.")" --ephemeral
expect "the restored plugin's hook runs again" blocked

echo "Shell startup output"
# Codex runs hook commands with the user's account shell, such as "zsh -c". zsh reads ~/.zshenv first, and anything it
# prints to stdout comes before what the hook writes there. That breaks a JSON answer, so Codex sends the prompt, which
# is why the hook blocks with exit code 2 instead. ZDOTDIR makes zsh read a .zshenv that prints a line.
mkdir -p "$WORK/zdotdir"
echo 'echo "Welcome! Your .zshenv printed this."' >"$WORK/zdotdir/.zshenv"
control_home="$WORK/codex-home-control"
mkdir -p "$control_home"
ln -s "$SOURCE_HOME/auth.json" "$control_home/auth.json"
cat >"$control_home/config.toml" <<'EOF'
[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "cat >/dev/null; echo '{\"decision\": \"block\", \"reason\": \"JSON block\"}'"
EOF
OUTPUT="$(cd "$WORK/cwd" && CODEX_HOME="$control_home" ZDOTDIR="$WORK/zdotdir" codex exec --ephemeral \
  --skip-git-repo-check -s read-only --dangerously-bypass-hook-trust "$(ask "Hello.")" </dev/null 2>&1)"
if printf '%s\n' "$OUTPUT" | grep -q '^tokens used'; then
  ok "control: with shell startup output, a hook that blocks with JSON lets the prompt through"
  ZDOTDIR="$WORK/zdotdir" send "$(ask "Token: $GH2.")" --ephemeral
  expect "with shell startup output, the plugin still blocks a secret" blocked
else
  echo "  skip  shell startup output: the hook shell here is not zsh, or Codex ignores the output"
fi

echo "Config hook without the plugin (as a managed hook would run it)"
export CODEX_HOME="$WORK/codex-home-config"
mkdir -p "$CODEX_HOME"
ln -s "$SOURCE_HOME/auth.json" "$CODEX_HOME/auth.json"
cat >"$CODEX_HOME/config.toml" <<EOF
[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "bash '$REPO/infisical-secret-scanner/scripts/scan-prompt.sh'"
timeout = 60
EOF
send "$(ask "Token: $GH1.")" --ephemeral --dangerously-bypass-hook-trust
expect "a config hook blocks a secret" blocked
send "\$infisical-allow $GH1" --ephemeral --dangerously-bypass-hook-trust
expect "a config hook handles allow" blocked
[ -n "$(ls "$CODEX_HOME/infisical-secret-scanner/allowlist" 2>/dev/null)" ] &&
  ok "a config hook keeps the allowlist in CODEX_HOME" || fail "a config hook keeps the allowlist in CODEX_HOME"
send "$(ask "Token: $GH1.")" --ephemeral --dangerously-bypass-hook-trust
expect "a config hook answers an allowed secret" answered

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
  printf '  - %s\n' "${failures[@]}"
  exit 1
}
