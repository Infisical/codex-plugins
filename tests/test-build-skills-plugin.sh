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

# Usage: copy_template <folder>. Copies the real plugin template to the folder, with a fixed name and version, so that
# the tests don't depend on them: a release raises the version in the real template.
copy_template() {
  cp -R "$REPO/infisical-skills" "$1" &&
    jq '.name = "infisical-skills" | .version = "1.0.0"' "$1/.codex-plugin/plugin.json" >"$1/plugin.json.tmp" &&
    mv "$1/plugin.json.tmp" "$1/.codex-plugin/plugin.json"
}

# Usage: new_template. Copies the real plugin template and writes its path.
new_template() {
  local dir="$WORK/template-$RANDOM$RANDOM"
  copy_template "$dir"
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

# Usage: bad_header <description> <SKILL.md content> <text in the error>. Builds with that SKILL.md and expects the
# build to fail with the text, and to write no ZIP.
bad_header() {
  local src
  src="$(new_source)"
  printf -- "$2" >"$src/skills/infisical-api/SKILL.md"
  rm -rf "$WORK/out"
  build "$src" "$TPL"
  expect "$1" 1 "$3"
  check "$1: no ZIP" test ! -e "$WORK/out/infisical-skills-1.0.0.zip"
}

bad_header "an unterminated quoted description fails" \
  '---\nname: infisical-api\ndescription: "unterminated\n---\n' "is not valid YAML"
bad_header "an unterminated single-quoted name fails" \
  "---\nname: 'infisical-api\ndescription: x\n---\n" "is not valid YAML"
bad_header "an unclosed list fails" \
  '---\nname: infisical-api\ndescription: x\ntriggers: [a, b\n---\n' "is not valid YAML"
bad_header "a bad indentation fails" \
  '---\nname: infisical-api\n  description: x\n---\n' "is not valid YAML"
bad_header "a tab indentation fails" \
  '---\nname: infisical-api\ndescription: x\ntriggers:\n\t- a\n---\n' "is not valid YAML"
bad_header "front matter without a closing --- fails" \
  '---\nname: infisical-api\ndescription: x\n\n# Infisical API\n' "has no closing --- after its front matter"
bad_header "front matter that is a list fails" \
  '---\n- name: infisical-api\n- description: x\n---\n' "is not a YAML mapping"
bad_header "empty front matter fails" '---\n---\n# Body\n' "is not a YAML mapping"
bad_header "a description that is a list fails" \
  '---\nname: infisical-api\ndescription:\n  - x\n---\n' "has a description that is not text"
bad_header "a name that is a number fails" '---\nname: 42\ndescription: x\n---\n' "has a name that is not text"
bad_header "a missing name fails" '---\ndescription: x\n---\n' "has no name"
bad_header "a blank description fails" '---\nname: infisical-api\ndescription: "  "\n---\n' "has no description"
bad_header "an empty file fails" '' "has no front matter"

# Valid YAML that a line-by-line reader gets wrong.
SRC="$(new_source)"
printf -- '---\r\nname: infisical-api\r\ndescription: Windows line endings.\r\n---\r\n# Body\r\n' \
  >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "front matter with Windows line endings" 0 "Built"
SRC="$(new_source)"
printf -- '---\nname: infisical-api # the folder name\ndescription: |\n  Two\n  lines.\nupdated: 2026-01-01\n---\n' \
  >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "comments, literal blocks, and dates in front matter" 0 "Built"
SRC="$(new_source)"
printf -- '---\nname: infisical-api\ndescription: "Uses --- inside a value."\n---\nbody\n---\n' \
  >"$SRC/skills/infisical-api/SKILL.md"
build "$SRC" "$TPL"
expect "a later --- line in the body is not part of the front matter" 0 "Built"

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

# A field that holds an object or a list instead of text fails, with one problem that names the field, and no ZIP. jq -r
# turns {} and [] into nonempty text, so these passed the content checks before the types were checked.
# Usage: not_text <jq path> <value>.
not_text() {
  local tpl
  tpl="$(new_template)"
  edit_manifest "$tpl" "$1 = $2"
  build "$SRC" "$tpl"
  expect "$1 = $2 fails" 1 "1 problem(s)" "${1#.} must be"
  check "$1 = $2 writes no ZIP" test -z "$(ls "$WORK/out"/*.zip 2>/dev/null)"
}

not_text .description '{}'
not_text .interface.displayName '[]'
not_text .name 42
not_text .version 1
not_text .skills '["./skills/"]'
not_text .author.name '{}'
not_text .author.email 'false'
not_text .author.url '{"url": "https://infisical.com"}'
not_text .homepage '[]'
not_text .repository '{}'
not_text .license '["MIT"]'
not_text .interface.shortDescription '{}'
not_text .interface.longDescription '[]'
not_text .interface.developerName 7
not_text .interface.category '[]'
not_text .interface.websiteURL '["https://infisical.com"]'
not_text .interface.supportURL '{}'
not_text .interface.composerIcon '["./assets/icon.png"]'
not_text .interface.logo '{"a": 1}'
not_text .author '"Infisical"'
not_text .interface '"Infisical"'
not_text .interface '[]'
bad_manifest "keywords that aren't a list of text fail" '.keywords = "secrets"' "keywords must be a list of text"
bad_manifest "an empty description fails" '.description = ""' "description is empty"
bad_manifest "an empty display name fails" '.interface.displayName = ""' "interface.displayName is empty"
bad_manifest "a missing interface fails" 'del(.interface)' "interface is missing"
bad_manifest "a missing author fails" 'del(.author)' "author is missing"
TPL="$(new_template)"
edit_manifest "$TPL" 'del(.homepage, .repository, .license, .keywords, .author.email, .author.url, .interface.websiteURL,
  .interface.privacyPolicyURL, .interface.termsOfServiceURL, .interface.defaultPrompt)'
build "$SRC" "$TPL"
expect "optional fields can be left out" 0 "Built"

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

# Usage: png <file> <width> <height>. Writes the start of a PNG, up to the size in its IHDR chunk, which is all the
# check reads.
png() {
  local hex i
  hex="$(printf '%08x%08x' "$2" "$3")"
  {
    printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR'
    for ((i = 0; i < 16; i += 2)); do printf "\\x${hex:i:2}"; done
  } >"$1"
}

for size in 48 4096; do
  TPL="$(new_template)"
  png "$TPL/assets/icon.png" "$size" "$size"
  build "$SRC" "$TPL"
  expect "a ${size}x$size icon passes" 0 "Built"
done
TPL="$(new_template)"
png "$TPL/assets/icon.png" 4097 4097
build "$SRC" "$TPL"
expect "an icon over 4096 pixels fails" 1 "must be 48 to 4096 pixels wide: 4097"

# Only PNG icons are taken, because the build can't check the size of the other formats.
for icon in logo.jpg logo.jpeg logo.webp logo.svg logo; do
  TPL="$(new_template)"
  case "$icon" in
    *.jpg | *.jpeg) printf '\xff\xd8\xff\xe0\0\x10JFIF\0' >"$TPL/assets/$icon" ;; # The start of a JPEG.
    *.svg) printf '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="10"/>' >"$TPL/assets/$icon" ;;
    *) printf 'text' >"$TPL/assets/$icon" ;;
  esac
  edit_manifest "$TPL" ".interface.logo = \"./assets/$icon\""
  build "$SRC" "$TPL"
  expect "a $icon icon fails" 1 "interface.logo must be a PNG file, the only format this build can check"
done
TPL="$(new_template)"
cp "$TPL/assets/logo.png" "$TPL/assets/logo.jpg"
edit_manifest "$TPL" '.interface.logo = "./assets/logo.jpg"'
build "$SRC" "$TPL"
expect "a PNG named .jpg fails" 1 "interface.logo must be a PNG file"
TPL="$(new_template)"
printf 'text, not an image' >"$TPL/assets/logo.png"
build "$SRC" "$TPL"
expect "a text file named .png fails" 1 "interface.logo is not a PNG file"

TPL="$(new_template)"
echo 'not json' >"$TPL/.codex-plugin/plugin.json"
build "$SRC" "$TPL"
expect "a manifest that is not JSON fails" 1 "is not a JSON object"

# ----------------------------------------------------------------------------------------------------------------------
echo "Output paths"
# ----------------------------------------------------------------------------------------------------------------------

# The build deletes the plugin folder before it fills it, so these lay out a repository like this one, with the template
# at <root>/infisical-skills, and check that a bad name or --out fails before anything is deleted.

# Usage: new_root. Makes <root>/infisical-skills (the template), <root>/dist, and <root>/ai-skills (the source), and
# writes the root's path.
new_root() {
  local root="$WORK/root-$RANDOM$RANDOM"
  mkdir -p "$root/dist"
  copy_template "$root/infisical-skills"
  cp -R "$(new_source)" "$root/ai-skills"
  echo keep >"$root/dist/existing.txt"
  echo "$root"
}

# Usage: build_in <root> <arguments>. Builds with the root's template and source.
build_in() {
  local root="$1"
  shift
  OUT="$(PLUGIN_TEMPLATE="$root/infisical-skills" "$BASH_BIN" "$SCRIPT" --source "$root/ai-skills" "$@" 2>&1)"
  CODE=$?
}

# Usage: intact <root>. Returns 0 when the template, the source, and the existing output are all still there.
intact() {
  [ -f "$1/infisical-skills/.codex-plugin/plugin.json" ] && [ -f "$1/infisical-skills/assets/logo.png" ] &&
    [ -f "$1/ai-skills/skills/infisical-api/SKILL.md" ] && [ "$(cat "$1/dist/existing.txt" 2>/dev/null)" = keep ]
}

for name in ../infisical-skills .. "." "a/b" "../ai-skills"; do
  ROOT="$(new_root)"
  edit_manifest "$ROOT/infisical-skills" ".name = \"$name\""
  build_in "$ROOT" --out "$ROOT/dist"
  expect "the name '$name' fails before anything is written" 1 "name must be"
  check "the name '$name' leaves the template, the source, and dist alone" intact "$ROOT"
  check "the name '$name' writes nothing to dist" test "$(ls "$ROOT/dist")" = existing.txt
done

ROOT="$(new_root)"
edit_manifest "$ROOT/infisical-skills" '.name = "../infisical-skills" | del(.description)'
build_in "$ROOT" --out "$ROOT/dist"
expect "a bad name is reported with the other manifest problems" 1 "2 problem(s)" "name must be" "description is missing"
check "the template is still there" intact "$ROOT"

ROOT="$(new_root)"
build_in "$ROOT" --out "$ROOT"
expect "--out at the template's parent fails" 1 "would replace the plugin template"
check "--out at the template's parent leaves the template alone" intact "$ROOT"

ROOT="$(new_root)"
(cd "$ROOT" && PLUGIN_TEMPLATE="$ROOT/infisical-skills" "$BASH_BIN" "$SCRIPT" --source ai-skills --out . >/dev/null 2>&1)
check "a relative --out . at the root leaves the template alone" intact "$ROOT"

ROOT="$(new_root)"
build_in "$ROOT" --out "$ROOT/infisical-skills/out"
expect "--out inside the template fails" 1 "would replace the plugin template"
check "--out inside the template leaves it alone" intact "$ROOT"
check "--out inside the template writes nothing in it" test ! -e "$ROOT/infisical-skills/out/infisical-skills"

ROOT="$(new_root)"
ln -s "$ROOT" "$WORK/link-$RANDOM" && LINK="$(ls -d "$WORK"/link-* | tail -n 1)"
build_in "$ROOT" --out "$LINK"
expect "--out through a link to the template's parent fails" 1 "would replace the plugin template"
check "--out through a link leaves the template alone" intact "$ROOT"

ROOT="$(new_root)"
mkdir -p "$ROOT/other"
mv "$ROOT/ai-skills" "$ROOT/other/infisical-skills"
OUT="$(PLUGIN_TEMPLATE="$ROOT/infisical-skills" "$BASH_BIN" "$SCRIPT" --source "$ROOT/other/infisical-skills" \
  --out "$ROOT/other" 2>&1)"
CODE=$?
expect "an output folder that is the ai-skills checkout fails" 1 "would replace the ai-skills checkout"
check "the ai-skills checkout is left alone" test -f "$ROOT/other/infisical-skills/skills/infisical-api/SKILL.md"

ROOT="$(new_root)"
build_in "$ROOT" --out "$ROOT/dist"
expect "a normal build next to the template works" 0 "Built infisical-skills"
check "a normal build leaves the template and source alone" intact "$ROOT"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
  printf '  - %s\n' "${failures[@]}"
  exit 1
}
