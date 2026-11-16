#!/usr/bin/env bash
# Builds the Infisical skills plugin for Codex: takes the plugin template in infisical-skills/ (manifest and icons),
# adds the skills listed in SKILLS from the Infisical/ai-skills repository, checks the result against the rules for
# submitting a plugin to the OpenAI plugin directory, and packs it as a ZIP.
#
# Usage: scripts/build-skills-plugin.sh [--ref <git ref>] [--source <ai-skills folder>] [--out <folder>]
#   --ref     branch, tag, or commit of ai-skills to take the skills from (default: main)
#   --source  a local ai-skills checkout to use instead of downloading one, to test changes to a skill
#   --out     where to write the plugin folder and the ZIP (default: dist)
#
# It writes <out>/infisical-skills/, the plugin folder, which can be installed in Codex to test it, and
# <out>/infisical-skills-<version>.zip, the package to upload. The ZIP is the same for the same template and skills, so
# two builds can be compared by their SHA-256. When GITHUB_OUTPUT is set, the script also writes zip, version, and
# source_commit to it, for the release workflow.
#
# The summary lists the ai-skills skills that are not in the plugin yet, and warns when an included skill tells the model
# to use one of them: the skills point to each other, for example in their "Not this skill" tables.
#
# Contents: settings, output, helpers, fetching, checks, packing, main.

set -o pipefail

# ----------------------------------------------------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------------------------------------------------

# The skills from ai-skills/skills/ that go into the plugin, by folder name. To ship a new skill, add it here, update the
# description and longDescription in infisical-skills/.codex-plugin/plugin.json if they list what the plugin covers, and
# raise the version there.
readonly SKILLS=(
  infisical-api
)

readonly SOURCE_REPO="https://github.com/Infisical/ai-skills.git"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PLUGIN_TEMPLATE sets another template folder, for the tests.
readonly TEMPLATE="${PLUGIN_TEMPLATE:-$REPO_ROOT/infisical-skills}"

# Every file in the ZIP gets this time, so that the same input makes the same ZIP.
readonly FILE_TIME="198001010000"

# Set by parse_args.
ref="main"
source_dir=""
out_dir="$REPO_ROOT/dist"

# A temporary folder for the download. Removed on exit.
tmp=""
# Set by fetch_source.
source_commit=""
# Set by check_manifest.
plugin_name=""
version=""

# ----------------------------------------------------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------------------------------------------------

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '6,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# Problems found by the checks. They are all reported before the build fails.
problems=()

problem() {
  problems+=("$1")
}

on_exit() {
  [ -n "$tmp" ] && rm -rf "$tmp"
}

# ----------------------------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) [ $# -ge 2 ] || usage; ref="$2"; shift ;;
      --source) [ $# -ge 2 ] || usage; source_dir="$2"; shift ;;
      --out) [ $# -ge 2 ] || usage; out_dir="$2"; shift ;;
      -h | --help) usage ;;
      *) usage ;;
    esac
    shift
  done
  case "$out_dir" in /*) ;; *) out_dir="$(pwd)/$out_dir" ;; esac
}

require_tools() {
  local tool
  for tool in git jq zip; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed."
  done
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | cut -d ' ' -f 1
}

# Usage: frontmatter_field <SKILL.md> <field>. Writes the value of a top-level field in the YAML front matter. Handles
# plain and quoted values on one line, and folded (>) and literal (|) blocks, which are joined into one line.
frontmatter_field() {
  awk -v field="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    collecting {
      if ($0 ~ /^[ \t]/ || $0 == "") { sub(/^[ \t]+/, ""); value = value (value == "" ? "" : " ") $0; next }
      exit
    }
    index($0, field ":") == 1 {
      value = substr($0, length(field) + 2)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      if (value ~ /^[>|][-+]?$/) { value = ""; collecting = 1; next }
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
      exit
    }
    END { sub(/[ \t]+$/, "", value); printf "%s", value }' "$1"
}

# Usage: png_size <file>. Writes the width and height of a PNG, from its IHDR chunk, or returns 1 when it is not a PNG.
png_size() {
  local header
  header="$(od -An -tx1 -N24 "$1" 2>/dev/null | tr -d ' \n')"
  [ "${header:0:16}" = "89504e470d0a1a0a" ] || return 1
  printf '%d %d' "0x${header:32:8}" "0x${header:40:8}"
}

# ----------------------------------------------------------------------------------------------------------------------
# Fetching
# ----------------------------------------------------------------------------------------------------------------------

# Sets source_dir to an ai-skills checkout at ref, downloading it unless --source was given, and source_commit to its
# commit.
fetch_source() {
  if [ -n "$source_dir" ]; then
    [ -d "$source_dir/skills" ] || fail "$source_dir has no skills folder. Is it an ai-skills checkout?"
    source_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" || source_commit="unknown"
    [ -z "$(git -C "$source_dir" status --porcelain -- skills 2>/dev/null)" ] ||
      source_commit="$source_commit (with uncommitted changes)"
    return
  fi
  source_dir="$tmp/ai-skills"
  git init -q "$source_dir" &&
    git -C "$source_dir" fetch -q --depth 1 "$SOURCE_REPO" "$ref" &&
    git -C "$source_dir" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
    fail "could not download $ref from $SOURCE_REPO."
  source_commit="$(git -C "$source_dir" rev-parse HEAD)"
}

# ----------------------------------------------------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------------------------------------------------

# Usage: check_length <what> <value> <max>.
check_length() {
  [ "${#2}" -le "$3" ] || problem "$1 is ${#2} characters long; the limit is $3."
}

# Usage: check_https <what> <value>. An empty value is allowed: the field is optional.
check_https() {
  [ -z "$2" ] || case "$2" in https://*) ;; *) problem "$1 must be an https URL: $2" ;; esac
}

# Usage: check_icon <plugin folder> <field> <path>. An icon must be a square image of 48 to 4096 pixels, at most 5 MiB.
check_icon() {
  local file size width height
  case "$3" in
    '') problem "interface.$2 is missing."; return ;;
    ./*) ;;
    *) problem "interface.$2 must start with ./: $3" ;;
  esac
  file="$1/${3#./}"
  [ -f "$file" ] || { problem "interface.$2 points to a missing file: $3"; return; }
  [ "$(wc -c <"$file")" -le $((5 * 1024 * 1024)) ] || problem "interface.$2 is larger than 5 MiB."
  case "$file" in
    *.png)
      size="$(png_size "$file")" || { problem "interface.$2 is not a PNG file: $3"; return; }
      width="${size% *}"
      height="${size#* }"
      [ "$width" = "$height" ] || problem "interface.$2 is not square: ${width}x$height."
      [ "$width" -ge 48 ] && [ "$width" -le 4096 ] || problem "interface.$2 must be 48 to 4096 pixels wide: $width."
      ;;
    *.jpg | *.jpeg | *.webp | *.svg) ;;
    *) problem "interface.$2 must be a PNG, JPEG, WebP, or SVG file: $3" ;;
  esac
}

# Usage: check_manifest <plugin folder>. Checks .codex-plugin/plugin.json against the fields that the plugin directory
# requires, and sets plugin_name and version.
check_manifest() {
  local manifest="$1/.codex-plugin/plugin.json" field
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || fail "$manifest is not a JSON object."
  jq_field() { jq -r "$1 // \"\"" "$manifest"; }

  plugin_name="$(jq_field .name)"
  version="$(jq_field .version)"
  [[ "$plugin_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#plugin_name}" -le 64 ] ||
    problem "name must be at most 64 lowercase letters, numbers, and single hyphens: $plugin_name"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problem "version must be a version such as 1.0.0: $version"
  [ -n "$(jq_field .description)" ] || problem "description is missing."
  check_length description "$(jq_field .description)" 4000
  [ -n "$(jq_field .author.name)" ] || problem "author.name is missing."
  check_length author.name "$(jq_field .author.name)" 120
  check_https author.url "$(jq_field .author.url)"
  check_https homepage "$(jq_field .homepage)"
  [ "$(jq_field .skills)" = "./skills/" ] || problem "skills must be ./skills/."

  # A package with any of these can't be submitted, or isn't a skills-only plugin.
  for field in hooks mcpServers apps; do
    [ "$(jq "has(\"$field\")" "$manifest")" = false ] || problem "the manifest has $field, which a skills-only plugin can't have."
  done

  for field in displayName shortDescription; do
    [ -n "$(jq_field ".interface.$field")" ] || problem "interface.$field is missing."
    check_length "interface.$field" "$(jq_field ".interface.$field")" 30
  done
  [ -n "$(jq_field .interface.longDescription)" ] || problem "interface.longDescription is missing."
  check_length interface.longDescription "$(jq_field .interface.longDescription)" 4000
  [ -n "$(jq_field .interface.developerName)" ] || problem "interface.developerName is missing."
  check_length interface.developerName "$(jq_field .interface.developerName)" 80
  [ -n "$(jq_field .interface.category)" ] || problem "interface.category is missing."
  [ "$(jq '.interface.capabilities | type == "array" and length <= 20 and all(.[]; type == "string" and length <= 120)' \
    "$manifest")" = true ] || problem "interface.capabilities must be a list of at most 20 strings of at most 120 characters."
  [ "$(jq '.interface.defaultPrompt // [] | (if type == "string" then [.] else . end)
    | type == "array" and length <= 3 and all(.[]; type == "string" and length <= 128) and (unique | length) == length' \
    "$manifest")" = true ] || problem "interface.defaultPrompt must be at most 3 different prompts of at most 128 characters."
  for field in websiteURL supportURL privacyPolicyURL termsOfServiceURL; do
    check_https "interface.$field" "$(jq_field ".interface.$field")"
    check_length "interface.$field" "$(jq_field ".interface.$field")" 1024
  done
  check_icon "$1" composerIcon "$(jq_field .interface.composerIcon)"
  check_icon "$1" logo "$(jq_field .interface.logo)"
  unset -f jq_field
}

# Usage: check_skill <plugin folder> <skill>. A skill needs a SKILL.md whose front matter names it after its folder and
# describes it. Codex limits the name to 64 characters and the description to 1024.
check_skill() {
  local file="$1/skills/$2/SKILL.md" name description
  [ -f "$file" ] || { problem "skills/$2 has no SKILL.md."; return; }
  [ "$(head -n 1 "$file")" = "---" ] || { problem "skills/$2/SKILL.md has no front matter."; return; }
  name="$(frontmatter_field "$file" name)"
  description="$(frontmatter_field "$file" description)"
  [ "$name" = "$2" ] || problem "skills/$2/SKILL.md is named \"$name\", not \"$2\"."
  [ -n "$description" ] || problem "skills/$2/SKILL.md has no description."
  check_length "the description of skills/$2" "$description" 1024
}

# Usage: check_files <plugin folder>. The package must not hold hooks, MCP or app config, or links.
check_files() {
  local found
  found="$(cd "$1" && find . \( -path ./hooks -o -name .mcp.json -o -name mcp.json -o -name '*.app.json' \
    -o -name .app.json \) -print | head -n 5)"
  [ -z "$found" ] || problem "the plugin has files that a skills-only plugin can't have: $(echo $found)"
  found="$(cd "$1" && find . -type l -print | head -n 5)"
  [ -z "$found" ] || problem "the plugin has symbolic links, which a ZIP can't keep: $(echo $found)"
}

check_skill_list() {
  local repeated
  [ "${#SKILLS[@]}" -gt 0 ] || problem "SKILLS lists no skills."
  repeated="$(printf '%s\n' "${SKILLS[@]}" | sort | uniq -d)"
  [ -z "$repeated" ] || problem "SKILLS lists a skill more than once: $(echo $repeated)"
}

report_problems() {
  [ "${#problems[@]}" -eq 0 ] && return
  printf 'The plugin has %s problem(s):\n' "${#problems[@]}" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
}

# ----------------------------------------------------------------------------------------------------------------------
# Coverage
# ----------------------------------------------------------------------------------------------------------------------

# Usage: is_listed <skill>. Returns 0 when the skill is in SKILLS.
is_listed() {
  local skill
  for skill in "${SKILLS[@]}"; do
    [ "$skill" = "$1" ] && return 0
  done
  return 1
}

# Writes the skills in ai-skills that are not in SKILLS, one per line.
excluded_skills() {
  local dir
  for dir in "$source_dir"/skills/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    is_listed "$(basename "$dir")" || basename "$dir"
  done
}

# Usage: dangling_references <plugin folder> <excluded skills>. Writes "<skill>: <names>" for each included skill that
# names, in backticks, a skill that is not included.
dangling_references() {
  local skill other names
  for skill in "${SKILLS[@]}"; do
    names=""
    for other in $2; do
      grep -rqF "\`$other\`" "$1/skills/$skill" && names="$names${names:+, }$other"
    done
    [ -z "$names" ] || printf '%s: %s\n' "$skill" "$names"
  done
}

# ----------------------------------------------------------------------------------------------------------------------
# Packing
# ----------------------------------------------------------------------------------------------------------------------

# Usage: assemble <plugin folder>. Copies the template and the skills into the folder. The template's README.md is for
# the people who maintain the plugin, so it is left out.
assemble() {
  local skill
  rm -rf "$1" && mkdir -p "$1" || fail "could not create $1."
  cp -R "$TEMPLATE/." "$1/" || fail "could not copy the template."
  rm -rf "$1/skills" "$1/README.md" && mkdir -p "$1/skills"
  for skill in "${SKILLS[@]}"; do
    [ -d "$source_dir/skills/$skill" ] || { problem "ai-skills has no skills/$skill."; continue; }
    cp -R "$source_dir/skills/$skill" "$1/skills/$skill" || fail "could not copy skills/$skill."
  done
  find "$1" -name .DS_Store -delete
}

# Usage: pack <plugin folder> <zip>. Packs the folder's contents, with the manifest at the top of the ZIP. Files are
# added in a fixed order, with a fixed time and mode, and without extra attributes, so the same input makes the same ZIP.
pack() {
  rm -f "$2"
  find "$1" -exec env TZ=UTC touch -t "$FILE_TIME" {} + && chmod -R u=rwX,go=rX "$1" || fail "could not prepare $1."
  (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | TZ=UTC zip -X -q -@ "$2") || fail "could not write $2."
}

# ----------------------------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------------------------

main() {
  local plugin_dir zip skill excluded dangling
  parse_args "$@"
  require_tools
  trap on_exit EXIT
  umask 022
  tmp="$(mktemp -d)" || fail "could not create a temporary folder."
  [ -f "$TEMPLATE/.codex-plugin/plugin.json" ] || fail "the plugin template is missing: $TEMPLATE"

  fetch_source
  check_skill_list
  check_manifest "$TEMPLATE"
  plugin_dir="$out_dir/$plugin_name"
  assemble "$plugin_dir"
  check_files "$plugin_dir"
  for skill in "${SKILLS[@]}"; do
    [ -d "$plugin_dir/skills/$skill" ] && check_skill "$plugin_dir" "$skill"
  done
  report_problems

  zip="$out_dir/$plugin_name-$version.zip"
  pack "$plugin_dir" "$zip"
  excluded="$(excluded_skills)"
  dangling="$(dangling_references "$plugin_dir" "$excluded")"

  printf 'Built %s %s\n' "$plugin_name" "$version"
  printf '  skills:  %s (%s)\n' "${SKILLS[*]}" "${#SKILLS[@]}"
  [ -z "$excluded" ] || printf '  not included from ai-skills: %s\n' "$(echo $excluded)"
  printf '  source:  %s at %s\n' "${SOURCE_REPO%.git}" "$source_commit"
  printf '  folder:  %s\n' "$plugin_dir"
  printf '  zip:     %s\n' "$zip"
  printf '  sha256:  %s\n' "$(sha256 "$zip")"
  if [ -n "$dangling" ]; then
    printf '\nwarning: these skills point to skills that are not in the plugin, so Codex will not find them:\n'
    printf '%s\n' "$dangling" | sed 's/^/  /'
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'zip=%s\nversion=%s\nsource_commit=%s\n' "$zip" "$version" "$source_commit" >>"$GITHUB_OUTPUT"
  fi
}

main "$@"
