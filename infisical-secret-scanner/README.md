# Infisical for Codex

This plugin blocks Codex prompts that contain secrets, such as API keys, tokens, private keys, and database connection strings, before they reach the model.

Everything runs on your machine. The plugin scans each prompt with the Infisical CLI's secret scanner and sends nothing to Infisical. You don't need an Infisical account or a login.

## How it works

1. When you send a prompt, a `UserPromptSubmit` hook scans its text with `infisical scan --pipe`. Pasted text is scanned too, and so is the IDE context that Codex adds to the prompt, such as selected code.
2. If the scan finds no secret, or only secrets you allowed, the prompt goes to the model.
3. If it finds a secret, the prompt is not sent. You see which rules matched, on which line, and the first characters of each secret. Codex doesn't add a blocked prompt to the conversation, so the model never sees it.

A `gitleaks:allow` comment, which is common in pasted code, doesn't hide a secret from the scan.

The hook blocks the prompt when it can't do its job: when the CLI or `jq` is missing, when the scan fails, when the check takes longer than 45 seconds (well under Codex's 60-second hook timeout), or when the script stops with an error. At 45 seconds it stops the check and every process it started. It blocks with exit code 2, so text that your shell prints when it starts can't turn a block into a pass.

Codex itself sends the prompt when it can't run the hook at all: before you trust the hook, after a plugin update until you trust it again, and when hooks are turned off. See [Trust the hook](#trust-the-hook) and [Limits](#limits).

## Requirements

- [Infisical CLI](https://infisical.com/docs/cli/overview). The plugin is tested with 0.44.13 and 0.45.8.
- [jq](https://jqlang.org/download)
- bash 3.2 or later. The plugin runs on macOS and Linux.
- Codex 0.169.0 or later. Tested with the Codex CLI.

## Install

```
codex plugin marketplace add Infisical/codex-plugins
codex plugin add infisical-secret-scanner@infisical
```

You can also install it from `/plugins` in Codex. Then [trust the hook](#trust-the-hook).

## Trust the hook

Codex doesn't run a plugin's hooks until you trust them, and the plugin does nothing until then. After you install the plugin:

1. Start a new Codex session and run `/hooks`. If Codex was already running when you installed the plugin from the command line, quit it and start it again.
2. Select `UserPromptSubmit`, which shows 1 hook to review.
3. Press `t` to trust it, or `Enter` to review it first.

Codex records the trust against the hook and the plugin's files. When a plugin update changes them, Codex stops running the hook until you trust it again in `/hooks`.

## Allow a secret

If a value is safe to share with the model, for example a test key, allow it:

```
$infisical-secret-scanner:allow <secret>
```

Type `$infisical-secret-scanner:allow`, or type `$infisical` and pick `allow` from the menu, then the value. `$infisical-allow <secret>` is a shorter name for the same command.

The hook handles this command itself and blocks the prompt, so the value is never sent to the model. That's why Codex shows the confirmation under "Blocked by hook". The confirmation shows the rule and the first characters of the secret it allowed. Prompts that contain the value are no longer blocked.

You can pass the bare value, a quoted value, or a whole line such as `STRIPE_KEY=sk_test_...`. Allow one secret at a time, so that a secret you didn't mean to allow is never allowed by mistake:

- The plugin refuses a value that holds more than one secret.
- The value must be on one line, with nothing on the lines after it. The one exception is a secret that spans lines by itself, such as a private key: send the command followed by the whole key, and nothing else.

The plugin stores only the SHA-256 hash of each allowed value, as the name of an empty file in `~/.codex/plugins/data/infisical-secret-scanner-infisical/allowlist/`. To clear all of them, delete that folder.

To stop allowing a value, disallow it:

```
$infisical-secret-scanner:disallow <secret>
```

`$infisical-disallow <secret>` is a shorter name for it. The hook handles this command the same way, so the value is never sent to the model. Pass the same value, quoted value, or line that you passed to allow.

The command must be at the start of your prompt. A command later in the prompt, such as in text you pasted, is scanned like any other text. With IDE context on, it must be at the start of your request, after the context Codex adds.

Only a prompt you type can allow or disallow a secret. When Codex sends a prompt to a subagent, the model wrote it, so the plugin scans a command in it like any other text.

## Scan rules

The plugin scans with [`config/infisical-scan.toml`](config/infisical-scan.toml): the CLI's default rules, plus an allowlist for placeholder values such as `<your-token>`. A `.infisical-scan.toml` in your project does not change the scan.

To use your own rules, put a config at `~/.codex/plugins/data/infisical-secret-scanner-infisical/infisical-scan.toml`. It replaces the plugin's config. Start it with this block to keep the default rules:

```toml
[extend]
useDefault = true
```

## Require it for every developer

A developer can turn off the plugin, or not trust its hook, in their own Codex config. To require the scan, an administrator can run the same script as a managed hook instead. Managed hooks are trusted by policy and can't be turned off from `/hooks`. Codex doesn't copy managed hook scripts, so put this folder on each machine, for example at `/opt/infisical-secret-scanner`, and add this to the system `requirements.toml`:

```toml
[features]
hooks = true

[hooks]
managed_dir = "/opt/infisical-secret-scanner"

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "bash /opt/infisical-secret-scanner/scripts/scan-prompt.sh"
timeout = 60
```

This setup is tested on Linux with Codex 0.169.0: the hook runs without a trust step, and it keeps running when a developer sets `hooks = false` in their own config.

When the script runs without the plugin, it keeps the allowlist and your own scan config in `~/.codex/infisical-secret-scanner/` (or `$CODEX_HOME/infisical-secret-scanner/`) instead of the plugin's data folder. See [Codex hooks](https://learn.chatgpt.com/docs/hooks) for managed hook settings.

## Limits

- The plugin scans only the text of the prompt. It doesn't scan files you mention with `@` (the prompt holds only the path), files Codex reads with its tools, or images.
- Codex sends the prompt when it can't run the hook: before you trust it, after a plugin update until you trust it again, and when hooks are turned off. The script blocks on its own failures, but it can't block when it doesn't run.
- Codex runs the hook command with your account's shell, such as `zsh -c`. The command works in sh, bash, zsh, and tcsh.
- A blocked prompt never reaches the model and is not saved in the session files. The Codex TUI still saves the text you type, including the value you pass to allow or disallow, to `~/.codex/history.jsonl` as soon as you send it. To stop that, set `persistence = "none"` under `[history]` in `~/.codex/config.toml`.
- Plugins with hooks aren't listed in OpenAI's public plugin directory. Install this plugin from this marketplace.
- The plugin doesn't run on Windows yet.
- If Codex kills the hook, the hook's private temporary folder, which holds the prompt, stays in your temporary folder until a later run removes it, at least 5 minutes after.

## Test locally

From the root of this repository:

```
codex plugin marketplace add ./
codex plugin add infisical-secret-scanner@infisical
```

Then start a new Codex session and trust the hook in `/hooks`. Run the install commands and `codex` with the same `CODEX_HOME`. If you test in a separate Codex home, export `CODEX_HOME` before you install, and start Codex from the same terminal; otherwise the plugin is installed in one home and Codex reads another, and `/hooks` shows no hooks. See [tests](../tests) for the automated tests.
