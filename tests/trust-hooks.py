#!/usr/bin/env python3
"""Trusts a plugin's Codex hooks the way the /hooks screen in the Codex TUI does.

It starts `codex app-server`, lists the hooks with `hooks/list`, and writes the current hash of each of the plugin's
hooks to `hooks.state` in the user's config.toml with `config/batchWrite`. Codex runs a non-managed hook only when its
hash is trusted, and asks again after the plugin changes.

Usage: tests/trust-hooks.py <plugin id, such as infisical-secret-scanner@infisical> [cwd]
Uses the Codex home in CODEX_HOME, like Codex. Prints the trust status of each of the plugin's hooks before trusting.
"""

import json
import subprocess
import sys


def request(proc, request_id, method, params):
    proc.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    for line in proc.stdout:
        message = json.loads(line)
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise SystemExit(f"{method} failed: {message['error']}")
        return message["result"]
    raise SystemExit(f"codex app-server exited before answering {method}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    plugin_id = sys.argv[1]
    cwd = sys.argv[2] if len(sys.argv) > 2 else None

    proc = subprocess.Popen(
        ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
    )
    try:
        request(proc, 1, "initialize", {"clientInfo": {"name": "infisical-trust-hooks", "version": "1.0.0"}})
        proc.stdin.write(json.dumps({"method": "initialized"}) + "\n")
        proc.stdin.flush()

        listing = request(proc, 2, "hooks/list", {"cwds": [cwd] if cwd else []})
        hooks = [hook for entry in listing["data"] for hook in entry["hooks"] if hook.get("pluginId") == plugin_id]
        if not hooks:
            raise SystemExit(f"no hooks found for {plugin_id}; is the plugin installed and enabled?")
        for hook in hooks:
            print(f"{hook['key']}: {hook['trustStatus']}")

        state = {hook["key"]: {"trusted_hash": hook["currentHash"]} for hook in hooks}
        request(
            proc,
            3,
            "config/batchWrite",
            {
                "edits": [{"keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"}],
                "reloadUserConfig": True,
            },
        )
        print(f"trusted {len(hooks)} hook(s) for {plugin_id}")
    finally:
        proc.stdin.close()
        proc.terminate()
        proc.wait()


if __name__ == "__main__":
    main()
