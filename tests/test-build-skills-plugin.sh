#!/usr/bin/env bash
# Tests for scripts/build-skills-plugin.sh. They build from a fake ai-skills checkout (--source) and a copy of the plugin
# template (PLUGIN_TEMPLATE), so they don't download anything, and check the ZIP and every rule the script enforces.
#
# Usage: tests/test-build-skills-plugin.sh [bash binary]. Needs git, jq, zip, and unzip.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/build-skills-plugin.sh"
BASH_BIN="${1:-bash}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

passed=0
failed=0
failures=()

# ----------------------------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------------------------

ok() {
  passed=$((passed + 1))
  echo "  ok    $1"
}

fail() {
  failed=$((failed + 1))
  failures+=("$1")
  echo "  FAIL  $1"
  echo "$OUT" | sed 's/^/        | /' | head -n 20
}

# Usage: new_source. Makes a fake ai-skills checkout with a valid infisical-api skill, commits it, and writes its path.
new_source() {
  local dir="$WORK/source-$RANDOM$RANDOM"
  mkdir -p "$dir/skills/infisical-api/references" "$dir/skills/other-skill"
  cat >"$dir/skills/infisical-api/SKILL.md" <<'EOF'
---
name: infisical-api
description: Use the Infisical REST API.
triggers:
  - infisical API
---

# Infisical API
EOF
  echo "# Auth" >"$dir/skills/infisical-api/references/authentication.md"
  printf -- '---\nname: other-skill\ndescription: Not in the plugin.\n---\n' >"$dir/skills/other-skill/SKILL.md"
  mkdir -p "$dir/evals"
  echo "not shipped" >"$dir/evals/README.md"
  git init -q "$dir" && git -C "$dir" add -A && git -C "$dir" commit -qm init
  echo "$dir"
}

# Usage: new_template. Copies the real plugin template and writes its path.
new_template() {
  local dir="$WORK/template-$RANDOM$RANDOM"
  cp -R "$REPO/infisical-skills" "$dir"
  echo "$dir"
}

# Usage: build <source> <template> [arguments]. Runs the script and sets OUT and CODE. The output folder is $WORK/out.
build() {
  local source="$1" template="$2"
  shift 2
  rm -rf "$WORK/out"
  OUT="$(PLUGIN_TEMPLATE="$template" "$BASH_BIN" "$SCRIPT" --source "$source" --out "$WORK/out" "$@" 2>&1)"
  CODE=$?
}

# Usage: expect <description> <exit code> [text that OUT must hold...].
expect() {
  local description="$1" code="$2" text
  shift 2
  if [ "$CODE" != "$code" ]; then
    fail "$description: exit code $CODE, expected $code"
    return
  fi
  for text in "$@"; do
    case "$OUT" in
      *"$text"*) ;;
      *)
        fail "$description: the output does not hold \"$text\""
        return
        ;;
    esac
  done
  ok "$description"
}

check() {
  local description="$1"
  shift
  if "$@"; then ok "$description"; else fail "$description"; fi
}

# Usage: edit_manifest <template> <jq filter>.
edit_manifest() {
  local file="$1/.codex-plugin/plugin.json"
  jq "$2" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

for tool in git jq zip unzip; do
  command -v "$tool" >/dev/null || { echo "The tests need $tool." >&2; exit 1; }
done

# ----------------------------------------------------------------------------------------------------------------------
echo "Building"
# ----------------------------------------------------------------------------------------------------------------------

SRC="$(new_source)"
TPL="$(new_template)"
build "$SRC" "$TPL"
expect "builds the plugin" 0 "Built infisical-skills 1.0.0" "skills:  infisical-api (1)" "$(git -C "$SRC" rev-parse HEAD)"
ZIP="$WORK/out/infisical-skills-1.0.0.zip"
check "writes the ZIP" test -f "$ZIP"
check "writes the plugin folder" test -f "$WORK/out/infisical-skills/.codex-plugin/plugin.json"
LIST="$(unzip -Z1 "$ZIP" | LC_ALL=C sort)"
EXPECTED="$(printf '%s\n' .codex-plugin/plugin.json assets/icon.png assets/logo.png \
  skills/infisical-api/SKILL.md skills/infisical-api/references/authentication.md | LC_ALL=C sort)"
OUT="$LIST"
check "the ZIP holds the manifest at its top, the icons, and only the listed skill, without the README" test "$LIST" = "$EXPECTED"
check "the manifest in the ZIP is the template's" \
  bash -c 'unzip -p "$1" .codex-plugin/plugin.json | cmp -s - "$2/.codex-plugin/plugin.json"' _ "$ZIP" "$TPL"
check "the skill in the ZIP is the source's" \
  bash -c 'unzip -p "$1" skills/infisical-api/SKILL.md | cmp -s - "$2/skills/infisical-api/SKILL.md"' _ "$ZIP" "$SRC"
check "the template is not changed" test ! -e "$TPL/skills"

SUM1="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
sleep 1
touch "$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
SUM2="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
OUT="$SUM1 $SUM2"
check "the same input makes the same ZIP, whatever the file times" test "$SUM1" = "$SUM2"
OUT="$(PLUGIN_TEMPLATE="$TPL" TZ=Asia/Tokyo "$BASH_BIN" "$SCRIPT" --source "$SRC" --out "$WORK/out" 2>&1)"
SUM3="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
check "the same input makes the same ZIP in another time zone" test "$SUM1" = "$SUM3"

echo "changed" >>"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a source with uncommitted changes says so" 0 "with uncommitted changes"
git -C "$SRC" checkout -q -- .

touch "$TPL/.DS_Store" "$SRC/skills/infisical-api/.DS_Store"
build "$SRC" "$TPL"
OUT="$(unzip -Z1 "$ZIP")"
check "leaves out .DS_Store files" bash -c '! printf "%s" "$1" | grep -q DS_Store' _ "$OUT"
rm -f "$TPL/.DS_Store" "$SRC/skills/infisical-api/.DS_Store"

mkdir -p "$WORK/out/infisical-skills/skills/stale"
echo old >"$WORK/out/infisical-skills/skills/stale/SKILL.md"
OUT="$(PLUGIN_TEMPLATE="$TPL" "$BASH_BIN" "$SCRIPT" --source "$SRC" --out "$WORK/out" 2>&1)"
OUT="$(unzip -Z1 "$ZIP")"
check "a rebuild drops files from the previous build" bash -c '! printf "%s" "$1" | grep -q stale' _ "$OUT"

GITHUB_OUTPUT="$WORK/github-output" build "$SRC" "$TPL"
OUT="$(cat "$WORK/github-output")"
check "writes the GitHub outputs" bash -c 'printf "%s" "$1" | grep -qx "version=1.0.0" &&
  printf "%s" "$1" | grep -qx "zip=$2" && printf "%s" "$1" | grep -q "^source_commit=[0-9a-f]\{40\}$"' _ "$OUT" "$ZIP"

# A skill whose description is a folded YAML block.
SRC2="$(new_source)"
printf -- '---\nname: infisical-api\ndescription: >\n  Use the Infisical\n  REST API.\n---\n' >"$SRC2/skills/infisical-api/SKILL.md"
build "$SRC2" "$TPL"
expect "reads a folded description" 0 "Built"

build "$SRC" "$TPL"
expect "lists the ai-skills skills that are not included" 0 "not included from ai-skills: other-skill"
case "$OUT" in *warning:*) fail "warns about references when there are none" ;; *) ok "no warning without references" ;; esac

SRC3="$(new_source)"
printf '\n| Something else | `other-skill` |\n' >>"$SRC3/skills/infisical-api/SKILL.md"
printf 'See `other-skill`.\n' >>"$SRC3/skills/infisical-api/references/authentication.md"
build "$SRC3" "$TPL"
expect "warns when an included skill points to a skill that is not included" 0 \
  "warning: these skills point to skills that are not in the plugin" "  infisical-api: other-skill"

# --version takes a release tag, and the ZIP's manifest gets its version. The template keeps its own.
GITHUB_OUTPUT="$WORK/github-output" build "$SRC" "$TPL" --version v2.3.4
expect "--version v2.3.4 builds version 2.3.4" 0 "Built infisical-skills 2.3.4" "infisical-skills-2.3.4.zip"
ZIP="$WORK/out/infisical-skills-2.3.4.zip"
OUT="$(unzip -p "$ZIP" .codex-plugin/plugin.json)"
check "the manifest in the ZIP has the version" test "$(printf '%s' "$OUT" | jq -r .version)" = 2.3.4
check "the rest of the manifest is the template's" \
  test "$(printf '%s' "$OUT" | jq -S 'del(.version)')" = "$(jq -S 'del(.version)' "$TPL/.codex-plugin/plugin.json")"
check "the template keeps its version" test "$(jq -r .version "$TPL/.codex-plugin/plugin.json")" = 1.0.0
OUT="$(cat "$WORK/github-output")"
check "the GitHub outputs have the version" bash -c 'printf "%s" "$1" | grep -qx "version=2.3.4"' _ "$OUT"
build "$SRC" "$TPL" --version v1.0.0
check "--version equal to the template's keeps the manifest byte for byte" \
  bash -c 'unzip -p "$1" .codex-plugin/plugin.json | cmp -s - "$2/.codex-plugin/plugin.json"' _ \
  "$WORK/out/infisical-skills-1.0.0.zip" "$TPL"
for tag in 1.2.3 infisical-skills-v1.2.3 v1.2 v1.2.3-beta V1.2.3 latest ""; do
  build "$SRC" "$TPL" --version "$tag"
  expect "--version '$tag' fails" 1 "--version must be a release tag such as v1.2.0"
done
build "$SRC" "$TPL" --version
expect "--version without a value shows the usage" 2 "Usage:"

build "$SRC" "$TPL" --bogus
expect "an unknown option shows the usage" 2 "Usage:"
build "$WORK/nowhere" "$TPL"
expect "a source without skills fails" 1 "has no skills folder"

# ----------------------------------------------------------------------------------------------------------------------
echo "Skill checks"
# ----------------------------------------------------------------------------------------------------------------------

SRC="$(new_source)"
rm -rf "$SRC/skills/infisical-api"
build "$SRC" "$TPL"
expect "a missing skill fails" 1 "ai-skills has no skills/infisical-api"
check "a failed build writes no ZIP" test ! -e "$WORK/out/infisical-skills-1.0.0.zip"

SRC="$(new_source)"
rm "$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a skill without SKILL.md fails" 1 "has no SKILL.md"

SRC="$(new_source)"
printf -- '---\nname: something-else\ndescription: x\n---\n' >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a skill named apart from its folder fails" 1 "is named \"something-else\", not \"infisical-api\""

SRC="$(new_source)"
printf -- '---\nname: infisical-api\n---\n' >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a skill without a description fails" 1 "has no description"

SRC="$(new_source)"
printf -- '---\nname: infisical-api\ndescription: %s\n---\n' "$(printf 'x%.0s' $(seq 1 1025))" \
  >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a description over 1024 characters fails" 1 "1025 characters long; the limit is 1024"

SRC="$(new_source)"
printf '# no front matter\n' >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a skill without front matter fails" 1 "has no front matter"

SRC="$(new_source)"
printf -- "---\nname: 'infisical-api'\ndescription: \"Quoted.\"\n---\n" >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "quoted front matter values" 0 "Built"

SRC="$(new_source)"
mkdir -p "$SRC/skills/infisical-api/hooks"
echo '{}' >"$SRC/skills/infisical-api/.mcp.json"
ln -s SKILL.md "$SRC/skills/infisical-api/link.md"
build "$SRC" "$TPL"
expect "MCP config and links in a skill fail" 1 ".mcp.json" "symbolic links"

# ----------------------------------------------------------------------------------------------------------------------
echo "Manifest checks"
# ----------------------------------------------------------------------------------------------------------------------

SRC="$(new_source)"

# Usage: bad_manifest <description> <jq filter> <text in the error>.
bad_manifest() {
  local tpl
  tpl="$(new_template)"
  edit_manifest "$tpl" "$2"
  build "$SRC" "$tpl"
  expect "$1" 1 "$3"
}

bad_manifest "a manifest with hooks fails" '.hooks = "./hooks/hooks.json"' "has hooks"
bad_manifest "a manifest with an MCP server fails" '.mcpServers = "./.mcp.json"' "has mcpServers"
bad_manifest "an invalid name fails" '.name = "Infisical_Plugin"' "name must be"
bad_manifest "an invalid version fails" '.version = "v1"' "version must be"
bad_manifest "a missing description fails" 'del(.description)' "description is missing"
bad_manifest "a missing author name fails" 'del(.author.name)' "author.name is missing"
bad_manifest "a long display name fails" '.interface.displayName = "Infisical Secrets Management Pro"' \
  "interface.displayName is 32 characters long; the limit is 30"
bad_manifest "a long short description fails" '.interface.shortDescription = "Manage all of your secrets with Infisical"' \
  "interface.shortDescription is"
bad_manifest "four default prompts fail" '.interface.defaultPrompt = ["a","b","c","d"]' "defaultPrompt"
bad_manifest "repeated default prompts fail" '.interface.defaultPrompt = ["a","a"]' "defaultPrompt"
bad_manifest "a long default prompt fails" ".interface.defaultPrompt = [\"$(printf 'x%.0s' $(seq 1 129))\"]" "defaultPrompt"
bad_manifest "capabilities that aren't a list fail" '.interface.capabilities = "Read"' "capabilities"
bad_manifest "an http URL fails" '.interface.websiteURL = "http://infisical.com"' "must be an https URL"
bad_manifest "a missing category fails" 'del(.interface.category)' "interface.category is missing"
bad_manifest "a missing logo fails" 'del(.interface.logo)' "interface.logo is missing"
bad_manifest "an icon path without ./ fails" '.interface.logo = "assets/logo.png"' "must start with ./"
bad_manifest "a missing icon file fails" '.interface.composerIcon = "./assets/nope.png"' "points to a missing file"
bad_manifest "a skills path other than ./skills/ fails" '.skills = "./other/"' "skills must be ./skills/"
bad_manifest "several problems are all reported" 'del(.description) | .version = "x"' "2 problem(s)"

TPL="$(new_template)"
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x40\0\0\0\x20' >"$TPL/assets/icon.png"
build "$SRC" "$TPL"
expect "an icon that is not square fails" 1 "is not square: 64x32"
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x20\0\0\0\x20' >"$TPL/assets/icon.png"
build "$SRC" "$TPL"
expect "an icon under 48 pixels fails" 1 "must be 48 to 4096 pixels wide: 32"
printf 'not a png' >"$TPL/assets/icon.png"
build "$SRC" "$TPL"
expect "an icon that is not a PNG fails" 1 "is not a PNG file"

TPL="$(new_template)"
echo 'not json' >"$TPL/.codex-plugin/plugin.json"
build "$SRC" "$TPL"
expect "a manifest that is not JSON fails" 1 "is not a JSON object"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
  printf '  - %s\n' "${failures[@]}"
  exit 1
}
