# Infisical Skills

Skills that help Codex work with Infisical, taken from [Infisical/ai-skills](https://github.com/Infisical/ai-skills). This is the plugin for the OpenAI plugin directory. It holds only skills, because the directory doesn't accept plugins with hooks.

Released skills: `infisical-api`.

This folder holds the parts of the plugin that live in this repository: the manifest and the icons. The build adds the skills and packs the plugin as a ZIP, which is uploaded to the directory. The plugin isn't in this repository's marketplace, because this folder has no skills until it is built. This README isn't part of the plugin either: the build leaves it out.

## Build

From the root of this repository:

```
scripts/build-skills-plugin.sh                         # skills from ai-skills main
scripts/build-skills-plugin.sh --ref <branch|tag|sha>  # skills from another ref
scripts/build-skills-plugin.sh --source ../ai-skills   # skills from a local checkout, to test a skill change
```

It writes `dist/infisical-skills/`, the plugin folder, and `dist/infisical-skills-<version>.zip`, the package to upload. It needs git, jq, and zip.

Before packing, it checks the manifest, icons, and skills against the directory's rules, such as the length limits and no hooks or MCP servers, and fails with a list of every problem. The same input always makes the same ZIP, so you can compare builds by their SHA-256.

The summary lists the ai-skills skills that aren't in the plugin yet. It warns when an included skill tells Codex to use one of them, for example in its "Not this skill" table, because Codex won't find that skill.

## Add a skill

1. Add the skill's folder name from `ai-skills/skills/` to `SKILLS` at the top of [`scripts/build-skills-plugin.sh`](../scripts/build-skills-plugin.sh).
2. In [`.codex-plugin/plugin.json`](.codex-plugin/plugin.json), add the skill to `description` and `interface.longDescription`, and raise `version`.
3. Update the list of released skills at the top of this README.

## Test in Codex

Build the plugin, then install it in a separate Codex home through a local marketplace:

```
scripts/build-skills-plugin.sh
mkdir -p /tmp/mkt/.agents/plugins && cp -R dist/infisical-skills /tmp/mkt/
cat >/tmp/mkt/.agents/plugins/marketplace.json <<'EOF'
{"name": "local", "plugins": [{"name": "infisical-skills", "source": {"source": "local", "path": "./infisical-skills"},
  "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}, "category": "Security"}]}
EOF
export CODEX_HOME=$(mktemp -d)
ln -s ~/.codex/auth.json "$CODEX_HOME/auth.json"
codex plugin marketplace add /tmp/mkt
codex plugin add infisical-skills@local
codex
```

## Release

1. Raise `version` in [`.codex-plugin/plugin.json`](.codex-plugin/plugin.json) and merge it.
2. Push a tag `infisical-skills-v<version>`. The [release workflow](../.github/workflows/release-skills-plugin.yml) builds the ZIP from ai-skills main, checks that the tag matches the version, and publishes a GitHub release with the ZIP. The release notes record the ai-skills commit the skills came from.
3. Upload the ZIP from the release to the OpenAI plugin dashboard.

To build a ZIP without releasing, for example from an ai-skills branch, run the workflow by hand from the Actions tab and download the ZIP from the run's artifacts.

## Tests

`tests/test-build-skills-plugin.sh [bash]` tests the build: the ZIP's contents, that it is the same for the same input, and every check the build makes. It builds from a fake ai-skills checkout, so it downloads nothing. It needs git, jq, zip, and unzip. Pass a bash binary to test another version, such as `/bin/bash` (3.2) on macOS.
