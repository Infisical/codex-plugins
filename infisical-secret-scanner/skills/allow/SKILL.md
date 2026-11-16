---
name: allow
description: Stop blocking prompts that contain this secret value. The Infisical hook handles it, so the value is never sent to the model.
---

The Infisical plugin's prompt hook runs `$infisical-secret-scanner:allow` and blocks the prompt, so you only see this when the hook did not run. Nothing was allowed.

Do not repeat, use, or store any value that came with this command. Tell the user only this: "The Infisical plugin's hook did not run, so $infisical-secret-scanner:allow did not allow anything, and the value you typed was sent to the model. Check that the plugin is enabled, that its hook is trusted in /hooks, and that hooks are not turned off in your Codex config."
