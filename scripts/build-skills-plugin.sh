#!/usr/bin/env bash
# Builds the Infisical skills plugin for Codex: takes the plugin template in infisical-skills/ (manifest and icons),
# adds the skills listed in SKILLS from the Infisical/ai-skills repository, checks the result against the rules for
# submitting a plugin to the OpenAI plugin directory, and packs it as a ZIP.
#
# Usage: scripts/build-skills-plugin.sh [--ref <git ref>] [--source <ai-skills folder>] [--out <folder>] [--version <v>]
#   --ref      branch, tag, or commit of ai-skills to take the skills from (default: main)
#   --source   a local ai-skills checkout to use instead of downloading one, to test changes to a skill
#   --out      where to write the plugin folder and the ZIP (default: dist)
#   --version  the plugin version, as a release tag such as v1.2.0 (default: the version in the template's manifest)
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

# The skills from ai-skills/skills/ that go into the plugin, by folder name. To ship a new skill, add it here, and update
# the description and longDescription in infisical-skills/.codex-plugin/plugin.json if they list what the plugin covers.
# A release sets the version from its tag.
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
version_arg=""
version_given=""

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
  sed -n '6,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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
      --version) [ $# -ge 2 ] || usage; version_arg="$2"; version_given=1; shift ;;
      -h | --help) usage ;;
      *) usage ;;
    esac
    shift
  done
  case "$out_dir" in /*) ;; *) out_dir="$(pwd)/$out_dir" ;; esac
}

require_tools() {
  local tool
  for tool in git jq zip ruby; do
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

# Usage: read_frontmatter <SKILL.md>. Parses the skill's YAML front matter, the lines between a first line --- and the
# next line ---, with a real YAML parser, and writes it as a JSON object. When there is none, it has no closing ---, it
# isn't valid YAML, or it isn't a mapping, it writes why to stderr and returns 1. Ruby's YAML library is used because
# bash, jq, and Python's standard library have no YAML parser, and a partial one would let broken headers through.
read_frontmatter() {
  ruby -ryaml -rjson -rdate -e '
    begin
      lines = File.read(ARGV[0], encoding: "UTF-8").lines
      abort "has no front matter" unless lines.first.to_s.chomp == "---"
      close = lines[1..-1].index { |line| line.chomp == "---" }
      abort "has no closing --- after its front matter" unless close
      begin
        data = YAML.safe_load(lines[1, close].join, permitted_classes: [Date, Time])
      rescue Psych::Exception => e
        abort "has front matter that is not valid YAML: #{e.message.sub(/\A\(<unknown>\): /, "")}"
      end
      abort "has front matter that is not a YAML mapping" unless data.is_a?(Hash)
      puts JSON.generate(data)
    rescue StandardError => e
      abort "could not be read: #{e.message}"
    end' "$1"
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
  # The directory also takes JPEG, WebP, and SVG, but this build can only check the size of a PNG, so it takes only
  # PNGs: an icon it can't check could be rejected only when the ZIP is uploaded. Add a check here before allowing
  # another format.
  case "$file" in
    *.png) ;;
    *) problem "interface.$2 must be a PNG file, the only format this build can check: $3"; return ;;
  esac
  size="$(png_size "$file")" || { problem "interface.$2 is not a PNG file: $3"; return; }
  width="${size% *}"
  height="${size#* }"
  [ "$width" = "$height" ] || problem "interface.$2 is not square: ${width}x$height."
  [ "$width" -ge 48 ] && [ "$width" -le 4096 ] || problem "interface.$2 must be 48 to 4096 pixels wide: $width."
}

# Usage: check_manifest <plugin folder>. Checks .codex-plugin/plugin.json against the fields that the plugin directory
# requires, and sets plugin_name and version. Each field's JSON type is checked before its contents: jq -r turns an
# object or a list into text, so {} would otherwise pass as a description.
check_manifest() {
  local manifest="$1/.codex-plugin/plugin.json" field value
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || fail "$manifest is not a JSON object."

  # Usage: json_type <path>. Writes the JSON type at the path, or "unreachable" when a parent isn't an object.
  json_type() { jq -r "try ($1 | type) catch \"unreachable\"" "$manifest"; }

  # Usage: object <path>. Records a problem unless the path holds an object. Returns 1 when it doesn't.
  object() {
    case "$(json_type "$1")" in
      object) return 0 ;;
      null) problem "${1#.} is missing." ;;
      *) problem "${1#.} must be an object." ;;
    esac
    return 1
  }

  # Usage: text <path> <required|optional> [max length]. Sets value to the text at the path, and returns 0 when the
  # field holds nonempty text. Records a problem when a required field is missing or empty, or when the field holds
  # anything but text. Returns 1 without a problem for a missing optional field, or one under a parent that isn't an
  # object, which object has reported.
  text() {
    value=""
    case "$(json_type "$1")" in
      string)
        value="$(jq -r "$1" "$manifest")"
        if [ -z "$value" ]; then
          [ "$2" = optional ] || problem "${1#.} is empty."
          return 1
        fi
        [ -z "${3:-}" ] || check_length "${1#.}" "$value" "$3"
        return 0
        ;;
      null) [ "$2" = optional ] || problem "${1#.} is missing." ;;
      unreachable) ;;
      *) problem "${1#.} must be text, not $(json_type "$1")." ;;
    esac
    return 1
  }

  plugin_name=""
  version=""
  if text .name required; then
    plugin_name="$value"
    [[ "$plugin_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#plugin_name}" -le 64 ] ||
      problem "name must be at most 64 lowercase letters, numbers, and single hyphens: $plugin_name"
  fi
  if text .version required; then
    version="$value"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problem "version must be a version such as 1.0.0: $version"
  fi
  text .description required 4000
  if object .author; then
    text .author.name required 120
    text .author.email optional 320
    text .author.url optional 2048 && check_https author.url "$value"
  fi
  text .homepage optional 2048 && check_https homepage "$value"
  text .repository optional
  text .license optional
  [ "$(jq '.keywords // [] | type == "array" and all(.[]; type == "string")' "$manifest")" = true ] ||
    problem "keywords must be a list of text."
  if text .skills required; then
    [ "$value" = "./skills/" ] || problem "skills must be ./skills/."
  fi

  # A package with any of these can't be submitted, or isn't a skills-only plugin.
  for field in hooks mcpServers apps; do
    [ "$(jq "has(\"$field\")" "$manifest")" = false ] || problem "the manifest has $field, which a skills-only plugin can't have."
  done

  object .interface || { unset -f json_type object text; return; }
  text .interface.displayName required 30
  text .interface.shortDescription required 30
  text .interface.longDescription required 4000
  text .interface.developerName required 80
  text .interface.category required
  [ "$(jq '.interface.capabilities | type == "array" and length <= 20 and all(.[]; type == "string" and length <= 120)' \
    "$manifest")" = true ] || problem "interface.capabilities must be a list of at most 20 strings of at most 120 characters."
  [ "$(jq '.interface.defaultPrompt // [] | (if type == "string" then [.] else . end)
    | type == "array" and length <= 3 and all(.[]; type == "string" and length <= 128) and (unique | length) == length' \
    "$manifest")" = true ] || problem "interface.defaultPrompt must be at most 3 different prompts of at most 128 characters."
  for field in websiteURL supportURL privacyPolicyURL termsOfServiceURL; do
    text ".interface.$field" optional 1024 && check_https "interface.$field" "$value"
  done
  text .interface.composerIcon required && check_icon "$1" composerIcon "$value"
  text .interface.logo required && check_icon "$1" logo "$value"
  unset -f json_type object text
}

# Usage: use_version <release tag>. Sets version from a release tag such as v1.2.0, or fails.
use_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version must be a release tag such as v1.2.0: $1"
  version="${1#v}"
}

# Usage: set_manifest_version <plugin folder>. Writes version into the plugin's manifest, when --version changed it.
set_manifest_version() {
  local manifest="$1/.codex-plugin/plugin.json"
  [ "$(jq -r .version "$manifest")" = "$version" ] && return
  jq --arg v "$version" '.version = $v' "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest" ||
    fail "could not set the version in $manifest."
}

# Usage: check_skill <plugin folder> <skill>. A skill needs a SKILL.md with valid YAML front matter that names it after
# its folder and describes it, both as text. The name is limited to 64 characters and the description to 1024, as the
# Agent Skills specification (agentskills.io) sets. Codex 0.169 itself loads a skill with a longer description.
check_skill() {
  local file="$1/skills/$2/SKILL.md" header name description
  [ -f "$file" ] || { problem "skills/$2 has no SKILL.md."; return; }
  header="$(read_frontmatter "$file" 2>"$tmp/frontmatter-error")" ||
    { problem "skills/$2/SKILL.md $(cat "$tmp/frontmatter-error")."; return; }
  field() { printf '%s' "$header" | jq -r "$1"; }
  case "$(field '.name | type')" in
    string)
      name="$(field .name)"
      [ "$name" = "$2" ] || problem "skills/$2/SKILL.md is named \"$name\", not \"$2\"."
      ;;
    null) problem "skills/$2/SKILL.md has no name." ;;
    *) problem "skills/$2/SKILL.md has a name that is not text." ;;
  esac
  case "$(field '.description | type')" in
    string)
      description="$(field .description)"
      [ -n "$(printf '%s' "$description" | tr -d ' \t\n')" ] || problem "skills/$2/SKILL.md has no description."
      check_length "the description of skills/$2" "$description" 1024
      ;;
    null) problem "skills/$2/SKILL.md has no description." ;;
    *) problem "skills/$2/SKILL.md has a description that is not text." ;;
  esac
  unset -f field
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

# Usage: real_path <folder>. Writes the folder's absolute path with links resolved. The folder must exist.
real_path() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Usage: overlaps <path> <path>. Returns 0 when the paths are the same, or one is inside the other.
overlaps() {
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

# Usage: set_output_path <out folder> <plugin name>. Creates the out folder and sets plugin_dir to the plugin folder's
# absolute path. Fails when the plugin folder is, holds, or is inside the template or the ai-skills checkout, because
# assemble deletes it: for example, --out set to the root of this repository. It sets a variable instead of writing the
# path, because fail in a $(...) would exit only the subshell, and the build would go on with an empty path.
set_output_path() {
  local out template source
  mkdir -p "$1" && out="$(real_path "$1")" || fail "could not create $1."
  template="$(real_path "$TEMPLATE")" || fail "could not find the template: $TEMPLATE"
  source="$(real_path "$source_dir")" || fail "could not find the ai-skills checkout: $source_dir"
  ! overlaps "$out/$2" "$template" ||
    fail "the output folder $out/$2 would replace the plugin template $template. Choose another --out."
  ! overlaps "$out/$2" "$source" ||
    fail "the output folder $out/$2 would replace the ai-skills checkout $source. Choose another --out."
  plugin_dir="$out/$2"
}

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
  # The name and version make the output paths, which assemble deletes and pack overwrites, so a bad one, such as
  # ../infisical-skills, must stop the build before anything is written.
  report_problems
  [ -z "$version_given" ] || use_version "$version_arg"
  set_output_path "$out_dir" "$plugin_name"
  [ -n "$plugin_dir" ] || fail "could not work out the output folder."
  assemble "$plugin_dir"
  set_manifest_version "$plugin_dir"
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
