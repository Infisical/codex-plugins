# Infisical Plugins for Codex

This repository holds Infisical's plugins for Codex. Each folder at the root of the repository holds one plugin, with a README that explains how to install, build, test, and release it.

## Plugins

| Plugin | What it does | How it ships |
|--------|--------------|--------------|
| [Infisical Secret Scanner](infisical-secret-scanner/README.md) (`infisical-secret-scanner`) | Blocks Codex prompts that contain secrets before they reach the model, with a hook that scans each prompt on your machine. | This repository's marketplace: `codex plugin marketplace add Infisical/codex-plugins` |
| [Infisical Skills](infisical-skills/README.md) (`infisical-skills`) | Skills that help Codex work with Infisical, from [Infisical/ai-skills](https://github.com/Infisical/ai-skills). | A ZIP uploaded to the OpenAI plugin directory |

## Add a plugin

1. Make a folder at the root of the repository. Give it the name of the plugin.
2. Put the plugin manifest in `<plugin>/.codex-plugin/plugin.json`. Put the skills, hooks, scripts, and config of the plugin in the same folder. A plugin can only use files in its own folder, because Codex copies only that folder when it installs the plugin.
3. To ship it in this repository's marketplace, add it to [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) with `"source": {"source": "local", "path": "./<plugin>"}`.
4. Add a README to the plugin's folder, and add the plugin to the table above.

Tests are in [`tests/`](tests) and run in [CI](.github/workflows/test.yml). Each plugin's README lists its tests.
