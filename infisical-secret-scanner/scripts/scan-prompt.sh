#!/usr/bin/env bash
# Infisical secret scanner: a Codex UserPromptSubmit hook.
#
# Scans each prompt on this machine with `infisical scan --pipe` and blocks it when it holds a secret that hasn't been
# allowed. It also runs the $infisical-secret-scanner:allow and $infisical-secret-scanner:disallow commands itself, so
# the value given to them is never sent to the model. Nothing is sent to Infisical.
#
# Codex reads the hook's result like this:
#   exit 2, reason on stderr  the prompt is not sent, and the reason is shown to the user only
#   exit 0                    the prompt is sent
#   anything else             the hook failed, and Codex SENDS the prompt
# Codex also sends the prompt when the hook takes longer than its timeout (60 seconds in hooks.json). So every failure
# in this script must end in block, the check runs in a worker that is killed at a deadline under that timeout, and an
# unexpected exit is turned into a block.
#
# The script blocks with exit code 2 and never writes to stdout. Codex runs hooks in the user's shell, which can print
# to stdout before the script starts (for example from ~/.zshenv), and Codex reads stdout that isn't a JSON object as
# text for the model and sends the prompt. Exit code 2 blocks whatever is on stdout.
#
# Contents: settings, output, helpers, scanning, findings, input, values, commands, check, main.

set -o pipefail

# ----------------------------------------------------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------------------------------------------------

# The commands, as the user sends them. The first name is what Codex inserts when the user picks the plugin's skill from
# the $ menu; the second is a shorter name to type.
readonly ALLOW_COMMANDS=('$infisical-secret-scanner:allow' '$infisical-allow')
readonly DISALLOW_COMMANDS=('$infisical-secret-scanner:disallow' '$infisical-disallow')
# With IDE context on, Codex puts the context before the user's request, and this line between them.
readonly REQUEST_MARKER='## My request for Codex:'
readonly LEAK_EXIT_CODE=42
# The most findings listed in a message. The rest are counted.
readonly MAX_LISTED=10

# Seconds the check may take before the prompt is blocked. It must stay under the hook timeout in hooks.json
# (60 seconds) with room to spare, because Codex sends the prompt when the hook times out. INFISICAL_SCAN_TIMEOUT can
# lower it.
readonly MAX_RUN_SECONDS=45
case "${INFISICAL_SCAN_TIMEOUT:-}" in
  '' | *[!0-9]* | 0*) RUN_SECONDS="$MAX_RUN_SECONDS" ;;
  *) RUN_SECONDS="$INFISICAL_SCAN_TIMEOUT" ;;
esac
[ "${#RUN_SECONDS}" -le 2 ] && [ "$RUN_SECONDS" -le "$MAX_RUN_SECONDS" ] || RUN_SECONDS="$MAX_RUN_SECONDS"
readonly RUN_SECONDS

# Codex gives plugin hooks PLUGIN_ROOT, the plugin's installed folder, and PLUGIN_DATA, a folder for the plugin's data
# that is kept across plugin updates. It also sets CLAUDE_PLUGIN_ROOT and CLAUDE_PLUGIN_DATA to the same values. When
# the script runs as a managed or config hook instead, neither is set: the plugin folder is the one holding this
# script, and the data folder is in the Codex home.
readonly PLUGIN_DIR="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}}"
readonly DATA_DIR="${PLUGIN_DATA:-${CLAUDE_PLUGIN_DATA:-${CODEX_HOME:-$HOME/.codex}/infisical-secret-scanner}}"
# One empty file for each allowed secret value, named after the SHA-256 hash of the value. The values themselves are
# never stored. A command only creates or deletes its own files, so sessions that change the list at the same time
# can't undo each other's changes, and no lock is needed.
readonly ALLOWLIST="$DATA_DIR/allowlist"

# Temporary folders are named with this prefix, so that ones left by a run that was killed can be found and removed.
readonly TMP_PREFIX="${TMPDIR:-/tmp}"
readonly TMP_NAME="infisical-secret-scanner"

# The scan must not reach the network: no telemetry event, no update check.
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1

readonly READ_ERROR="Infisical: could not read the prompt to scan it, so it was not sent."
readonly REPORT_ERROR="Infisical: could not read the secret scan report, so the prompt was not sent."

# Set by check.
SCAN_CONFIG=""
# A private temporary folder for the input, the prompt, values, and scan reports. Removed on exit.
tmp=""
# Set once the decision is written, so the exit trap doesn't write a second one.
decided=""

# ----------------------------------------------------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------------------------------------------------

# Usage: block <message>. Ends the turn without sending the prompt, shows the message to the user only, and exits.
# In the worker, it ends the worker with exit code 2, which run_check passes on. Never call it in a subshell, such as $(...)
# or a pipeline: it would exit only that subshell. Functions that run in one return a status instead, and the caller
# blocks.
block() {
  decided=1
  printf '%s\n' "$1" >&2
  exit 2
}

# Runs when main exits. It removes the temporary folder, and turns an exit with an error that didn't come from block,
# such as a bash error, into a block, because Codex would send the prompt.
on_exit() {
  local status=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  if [ -z "$decided" ] && [ "$status" -ne 0 ]; then
    block "Infisical: the secret scan stopped with an error (exit code $status), so the prompt was not sent."
  fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------------------------

# Reads files, or stdin when there is none, and writes their SHA-256 hashes, one per line.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi | cut -d ' ' -f 1
}

# Usage: jq_true <jq arguments>. Returns 0 only when jq prints exactly true. jq -e can't be trusted for this: jq 1.6, still
# in Debian 12, exits 0 when the filter prints nothing, such as on an empty file.
jq_true() {
  [ "$(jq "$@" 2>/dev/null)" = true ]
}

# Usage: require_tools. Blocks when a tool or file the hook needs is missing.
require_tools() {
  command -v infisical >/dev/null 2>&1 ||
    block "Infisical: the Infisical CLI is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://infisical.com/docs/cli/overview"
  command -v jq >/dev/null 2>&1 ||
    block "Infisical: jq is not installed, so prompts can't be scanned for secrets and are not sent. Install it: https://jqlang.org/download"
  [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/config/infisical-scan.toml" ] ||
    block "Infisical: could not find the plugin's scan config, so prompts can't be scanned for secrets and are not sent. Reinstall the plugin."
}

# Writes the path of the scan config: the user's config in the data folder when there is one, otherwise the plugin's.
scan_config_path() {
  if [ -f "$DATA_DIR/infisical-scan.toml" ]; then
    printf '%s' "$DATA_DIR/infisical-scan.toml"
  else
    printf '%s' "$PLUGIN_DIR/config/infisical-scan.toml"
  fi
}

# Creates the private temporary folder in $tmp, after removing ones that runs killed more than 5 minutes ago left
# behind. They can hold a prompt. A run lasts at most a minute, so no running hook's folder is removed.
make_tmp() {
  find "$TMP_PREFIX/" -maxdepth 1 -type d -name "$TMP_NAME.*" -mmin +5 -exec rm -rf {} + 2>/dev/null
  tmp="$(mktemp -d "$TMP_PREFIX/$TMP_NAME.XXXXXX")" ||
    block "Infisical: the secret scan could not create a temporary folder, so the prompt was not sent."
}

# ----------------------------------------------------------------------------------------------------------------------
# Scanning
# ----------------------------------------------------------------------------------------------------------------------

# Usage: scan <input file> <report file>. Returns 0 for no secrets and LEAK_EXIT_CODE for secrets.
#
# The scanner skips a line that holds a gitleaks:allow comment, which is common in pasted code, so the input is scanned
# with that comment changed to gitleaks_allow. The text keeps its length, so lines and columns don't move. A plain
# split and join is used, because a regex replace is slow on many matches. The scan runs from the private folder, so
# files in the user's project, such as a .infisical-scan.toml, can't change the result.
scan() {
  jq -Rsj 'split("gitleaks:allow") | join("gitleaks_allow")' "$1" >"$tmp/scan-input.txt" || block "$READ_ERROR"
  (cd "$tmp" && infisical scan --pipe --config "$SCAN_CONFIG" --silent --no-color \
    --exit-code "$LEAK_EXIT_CODE" --report-format json --report-path "$2" <"$tmp/scan-input.txt" >/dev/null 2>&1)
}

# Usage: scan_to_report <input file> <report file>. Like scan, but always leaves a JSON array of findings in the report
# file, and blocks when the scan fails.
scan_to_report() {
  local status

  scan "$1" "$2"
  status=$?
  case "$status" in
    0) echo '[]' >"$2" ;;
    "$LEAK_EXIT_CODE") ;;
    *) block "Infisical: the secret scan failed (exit code $status), so the prompt was not sent. Run 'infisical scan --pipe --config $SCAN_CONFIG' to see the error, and update the Infisical CLI if it is out of date." ;;
  esac
  jq_true 'type == "array" and all(.[]; type == "object" and (.Secret | type == "string"))' "$2" ||
    block "$REPORT_ERROR"
}

# ----------------------------------------------------------------------------------------------------------------------
# Findings
#
# A report can hold the same secret many times, for example in a pasted log. These functions work on the distinct
# secrets, in the order jq's `unique` sorts them, so a number from one function picks the same secret in the others.
# ----------------------------------------------------------------------------------------------------------------------

# Usage: secret_count <report file>. Writes the number of distinct secrets in the report.
secret_count() {
  jq '[.[].Secret] | unique | length' "$1"
}

# Usage: hash_secrets <report file> <hashes file>. Writes the SHA-256 hash of each distinct secret in the report, one
# per line. It runs one jq and one hash process for the whole report, so a report with thousands of findings stays fast.
hash_secrets() {
  local dir="$tmp/secrets" secret name count n=0

  count="$(secret_count "$1")" || block "$REPORT_ERROR"
  rm -rf "$dir" && mkdir "$dir" || block "$REPORT_ERROR"
  jq -j '[.[].Secret] | unique | .[] | (., "\u0000")' "$1" >"$dir.bin" || block "$REPORT_ERROR"
  # One file for each secret. Names are numbers padded to the same width, so the shell lists them in order.
  while IFS= read -r -d '' secret; do
    printf -v name '%08d' "$n"
    printf '%s' "$secret" >"$dir/$name" || block "$REPORT_ERROR"
    n=$((n + 1))
  done <"$dir.bin"
  # A secret that holds a NUL character would be split in two and shift every number after it.
  [ "$n" -eq "$count" ] || block "$REPORT_ERROR"

  : >"$2"
  [ "$n" -eq 0 ] && return 0
  (cd "$dir" && sha256 -- *) >"$2" || block "Infisical: could not hash the secrets found in the prompt, so it was not sent."
}

# Usage: describe_secrets <report file> <numbers file> [with lines]. Writes one line for each secret picked by a number
# in the numbers file: its rule, its first line when the third argument is given, and its first characters. Only a short
# prefix of each secret is shown, enough to find it.
describe_secrets() {
  jq -r --slurpfile pick "$2" --arg with_lines "${3:-}" --argjson max "$MAX_LISTED" '
    [group_by(.Secret)[$pick[]] | min_by([.StartLine, .StartColumn])] | sort_by([.StartLine, .StartColumn]) |
    (.[:$max][] |
      "  - \(.RuleID)" + (if $with_lines != "" then " on line \(.StartLine)" else "" end) +
      (if (.Secret | length) >= 16 then ", starts with \(.Secret[0:4])" else "" end)),
    (if length > $max then "  - and \(length - $max) more" else empty end)
  ' "$1"
}

# ----------------------------------------------------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------------------------------------------------

# Saves the prompt to $tmp/prompt.txt from the hook input in $tmp/input.json. Blocks when there is no prompt to scan,
# because an input without one would otherwise be scanned as an empty prompt and sent.
read_prompt() {
  jq_true '.prompt | type == "string"' "$tmp/input.json" &&
    jq -j '.prompt' "$tmp/input.json" >"$tmp/prompt.txt" || block "$READ_ERROR"
}

# Returns 0 when the prompt comes from a subagent. Codex writes those prompts from what the model asked for.
is_subagent_prompt() {
  jq_true '.agent_id // false | . != false' "$tmp/input.json"
}

# Saves the user's request to $tmp/request.txt: the prompt without the IDE context and without leading whitespace.
# Codex finds the request the same way, after the last marker line.
read_request() {
  jq -j --arg marker "$REQUEST_MARKER" '
    .prompt | (if contains($marker) then split($marker) | last else . end) | sub("\\A\\s+"; "")
  ' "$tmp/input.json" >"$tmp/request.txt" || block "$READ_ERROR"
}

# Usage: command_value <command>. When the request runs the command, writes the value given to it to $tmp/value.txt,
# without surrounding whitespace. Returns 1 when it doesn't. The command is matched as plain text, not as a regex,
# because it starts with $. Trailing whitespace is found by walking back from the end, because a regex is slow on a
# long run of it.
command_value() {
  jq_true -Rs --arg command "$1" 'startswith($command) and (.[($command | length):] | test("\\A(\\s|\\z)"))' \
    "$tmp/request.txt" || return 1
  jq -Rsj --arg command "$1" '
    .[($command | length):] | sub("\\A\\s+"; "") | explode as $chars |
    ([first(range(($chars | length) - 1; -1; -1) | select([$chars[.]] | inside([9, 10, 11, 12, 13, 32]) | not))] |
      first // -1) as $last |
    $chars[:$last + 1] | implode
  ' "$tmp/request.txt" >"$tmp/value.txt" || block "Infisical: could not read the value given to $1."
}

# ----------------------------------------------------------------------------------------------------------------------
# Values
# ----------------------------------------------------------------------------------------------------------------------

# Usage: is_allowed <hash>
is_allowed() {
  [ -f "$ALLOWLIST/$1" ]
}

# Usage: check_value <file holding the value given to a command>. Scans the value to $tmp/value-report.json, and blocks
# unless it is a single value: at most one secret, on one line unless the whole value is that secret, such as a private
# key. Text after the value can hold other secrets, which must never be allowed by mistake.
check_value() {
  local count

  scan_to_report "$1" "$tmp/value-report.json"
  count="$(secret_count "$tmp/value-report.json")" || block "$REPORT_ERROR"
  [ "$count" -le 1 ] ||
    block "Infisical: the value holds $count secrets. Allow or disallow one secret at a time. Nothing was changed."
  # Any line break, including the Unicode ones, ends the line.
  jq_true -Rs 'test("[\n\r\u000b\f\u0085\u2028\u2029]") | not' "$1" && return 0
  [ "$count" -eq 1 ] && jq_true --rawfile value "$1" '.[0].Secret == $value' "$tmp/value-report.json" ||
    block "Infisical: put only the secret after the command, on the same line, and send nothing else with it. Nothing was changed."
}

# Usage: value_hashes <file holding the value given to a command>. Writes to $tmp/hashes the SHA-256 hashes of what the
# command applies to: the secret the scanner found in the value, the value itself, and the value without quotes when it
# is quoted. The found secret makes a full line like TOKEN=<value> or a connection string apply to the same value that a
# scan of a prompt reports. Run check_value first.
value_hashes() {
  hash_secrets "$tmp/value-report.json" "$tmp/hashes"
  jq -Rsj 'if test("\\A([\"'"'"'`]).*\\1\\z"; "s") then .[1:-1] else empty end' "$1" >"$tmp/unquoted.txt" ||
    block "Infisical: could not read the value."
  sha256 <"$1" >>"$tmp/hashes" || block "Infisical: could not hash the value."
  if [ -s "$tmp/unquoted.txt" ]; then
    sha256 <"$tmp/unquoted.txt" >>"$tmp/hashes" || block "Infisical: could not hash the value."
  fi
}

# Writes what a command applies to, for its confirmation: the secret the scanner found in the value, or "the value".
describe_value() {
  if [ "$(secret_count "$tmp/value-report.json")" = 0 ]; then
    echo "the value you gave."
  else
    echo 0 >"$tmp/first.txt" && echo "this secret:" && describe_secrets "$tmp/value-report.json" "$tmp/first.txt"
  fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------------------------------------------------

# Usage: allow_secret <file holding the value given to the command>
allow_secret() {
  local hash described

  [ -s "$1" ] || block "Infisical: put the secret to allow after the command: ${ALLOW_COMMANDS[0]} <secret>"
  check_value "$1"
  value_hashes "$1"
  described="$(describe_value)" || block "$REPORT_ERROR"

  mkdir -p "$ALLOWLIST" || block "Infisical: could not save the allowed secret in $ALLOWLIST."
  while read -r hash; do
    : >"$ALLOWLIST/$hash" || block "Infisical: could not save the allowed secret in $ALLOWLIST."
  done <"$tmp/hashes"

  # Exit code 2 is the only way to stop a prompt without sending it, so Codex labels this confirmation as blocked.
  block "Infisical: allowed $described
Prompts that contain it are no longer blocked. To block it again, send ${DISALLOW_COMMANDS[0]} with the same value."
}

# Usage: disallow_secret <file holding the value given to the command>
disallow_secret() {
  local hash found=""

  [ -s "$1" ] || block "Infisical: put the secret to disallow after the command: ${DISALLOW_COMMANDS[0]} <secret>"
  check_value "$1"
  value_hashes "$1"

  while read -r hash; do
    is_allowed "$hash" || continue
    found=1
    rm -f "$ALLOWLIST/$hash" || block "Infisical: could not remove the secret from $ALLOWLIST, so it is still allowed."
  done <"$tmp/hashes"
  [ -n "$found" ] || block "Infisical: the secret was not allowed, so nothing changed."

  # Labeled as blocked by Codex, for the same reason as the allow_secret confirmation.
  block "Infisical: secret disallowed. Prompts that contain it will be blocked again."
}

# Runs the allow or disallow command when the request is one of them. Both end in block, so this returns only when the
# request is not a command. Only a prompt the user typed can run them: a command in a subagent prompt is scanned like
# any other text.
run_command() {
  local command

  is_subagent_prompt && return 0
  read_request
  for command in "${ALLOW_COMMANDS[@]}"; do
    command_value "$command" && allow_secret "$tmp/value.txt"
  done
  for command in "${DISALLOW_COMMANDS[@]}"; do
    command_value "$command" && disallow_secret "$tmp/value.txt"
  done
  return 0
}

# Blocks the prompt when it holds a secret that isn't allowed. Returns when it holds none.
check_prompt() {
  local hash n=0 findings

  scan_to_report "$tmp/prompt.txt" "$tmp/report.json"
  hash_secrets "$tmp/report.json" "$tmp/hashes"
  # The numbers of the secrets that aren't allowed.
  : >"$tmp/blocked.txt"
  while read -r hash; do
    is_allowed "$hash" || echo "$n" >>"$tmp/blocked.txt"
    n=$((n + 1))
  done <"$tmp/hashes"
  [ -s "$tmp/blocked.txt" ] || return 0

  findings="$(describe_secrets "$tmp/report.json" "$tmp/blocked.txt" with-lines)" || block "$REPORT_ERROR"
  block "Infisical: the prompt was not sent because it contains secrets:
$findings
Remove them and send the prompt again. To allow a value that is safe to share, send ${ALLOW_COMMANDS[0]} <value>."
}

# ----------------------------------------------------------------------------------------------------------------------
# Check
# ----------------------------------------------------------------------------------------------------------------------

# The whole check. Runs in the worker: exits 0 to send the prompt, or 2 after writing why it blocked it. It reads the
# hook input itself, so that reading it is under the deadline too.
check() {
  cat >"$tmp/input.json" || block "$READ_ERROR"
  require_tools
  read_prompt
  SCAN_CONFIG="$(scan_config_path)"

  run_command
  check_prompt
  exit 0
}

# Runs check in a worker with its own process group, and blocks when the worker passes the deadline, after killing it
# and everything it started. A single step, such as jq on a huge prompt, can't stop itself in time, and Codex sends the
# prompt when the hook passes its timeout.
#
# The worker gets the hook input on stdin, and writes why it blocked to a file that this function then shows. Writing
# it here keeps the message when the worker can't write to a terminal itself, as a background process group.
run_check() {
  local pid status reason deadline=$((SECONDS + RUN_SECONDS))

  # Job control gives the worker its own process group, so one kill stops the worker and its jq and infisical. Inside
  # the worker, job control must be off so that everything it runs stays in that group. Bash already turns it off in a
  # background subshell; set +m states it rather than relying on that.
  set -m
  {
    set +m
    check
  } <&0 2>"$tmp/reason.txt" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill -9 -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      block "Infisical: the secret scan took longer than $RUN_SECONDS seconds, so the prompt was not sent."
    fi
    sleep 0.1
  done
  wait "$pid"
  status=$?
  case "$status" in
    0) exit 0 ;;
    2)
      reason="$(cat "$tmp/reason.txt" 2>/dev/null)"
      block "${reason:-Infisical: the secret scan blocked the prompt.}"
      ;;
    *) block "Infisical: the secret scan stopped with an error (exit code $status), so the prompt was not sent." ;;
  esac
}

# ----------------------------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------------------------

main() {
  # Nothing this script runs may reach stdout. See the top of the file.
  exec >&2
  trap on_exit EXIT
  umask 077
  make_tmp
  run_check
}

main "$@"
