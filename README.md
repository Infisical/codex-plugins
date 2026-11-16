# Infisical Plugins for Codex

This repository is the Infisical plugin marketplace for Codex. Each folder at the root of the repository holds one plugin.

## Quick start

```
codex plugin marketplace add Infisical/codex-plugins
codex plugin add infisical-secret-scanner@infisical
```

Then start a new Codex session, run `/hooks`, and trust the plugin's hook. Codex doesn't run a plugin's hooks until you trust them.

## Plugins

### Infisical Secret Scanner

**Plugin ID**: `infisical-secret-scanner@infisical`

Blocks Codex prompts that contain secrets, such as API keys, tokens, and private keys, before they reach the model. The plugin scans each prompt on your machine with the Infisical CLI and sends nothing to Infisical. See the [plugin README](infisical-secret-scanner/README.md).

## Add a plugin

1. Make a folder at the root of the repository. Give it the name of the plugin.
2. Put the plugin manifest in `<plugin>/.codex-plugin/plugin.json`. Put the skills, hooks, scripts, and config of the plugin in the same folder. A plugin can only use files in its own folder, because Codex copies only that folder when it installs the plugin.
3. Add the plugin to [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) with `"source": {"source": "local", "path": "./<plugin>"}`.
4. Add the plugin to the list in this README.

## Test locally

Add the marketplace from your local copy of the repository:

```
codex plugin marketplace add ./
codex plugin add <plugin>@infisical
```

Then start a new Codex session and trust the plugin's hooks in `/hooks`. Run the install commands and `codex` with the same `CODEX_HOME`. To test without changing your own Codex config, use a separate Codex home in one terminal:

```
export CODEX_HOME=$(mktemp -d)
ln -s ~/.codex/auth.json "$CODEX_HOME/auth.json"
codex plugin marketplace add ./
codex plugin add <plugin>@infisical
codex
```

If `/hooks` shows no hooks, run `echo $CODEX_HOME` in the terminal where you started Codex. The plugin is installed only in the Codex home that was set when you ran `codex plugin add`.

Codex installs a copy of the plugin, so after a change, run `codex plugin remove <plugin>@infisical` and add it again, then trust its hooks again in `/hooks`.

## Tests

The tests need the Infisical CLI, jq, and pgrep and pkill (procps on Linux).

- `tests/test-scan-prompt.sh [bash]` tests the secret scanner's hook script on its own: prompts, allow and disallow, failures, config, and concurrent sessions. It checks every result the way Codex reads it, so a result that would let Codex send the prompt fails the test. Pass a bash binary to test another version, such as `/bin/bash` (3.2) on macOS.
- `tests/test-codex-e2e.sh` installs the plugin into a new, empty Codex home and sends prompts through `codex exec`. It needs a logged-in Codex and makes a few small model requests. All secrets in both tests are fake and made at run time.
- `tests/trust-hooks.py <plugin id>` trusts a plugin's hooks through `codex app-server`, the same way `/hooks` does. The end-to-end test uses it.
