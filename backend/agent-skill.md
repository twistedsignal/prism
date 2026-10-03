---
name: prism
description: Render or upload live Roblox Studio parts and models through the local Prism CLI, including batches, presets and per-call settings.
---

Run `prism agent instructions` and `prism agent describe` to discover this installation's interface. If Prism is absent from PATH, use `~/.local/bin/prism` on Linux/macOS or `%LOCALAPPDATA%\Prism\bin\prism.cmd` on Windows.

Start with `prism status --json` and `prism sessions --json`. Discover targets using `prism models --session ID --query NAME --json`. Read `prism schema --json`, `prism presets --json` and `prism fonts --json` before choosing settings. These commands require Studio in edit mode with Prism installed and localhost HTTP access allowed. The panel can remain closed.

Use `prism render` to save PNGs, `prism batch MANIFEST.json` for batches and `prism upload` only when the user requests uploads. Use explicit session ids when multiple Studio sessions are open. Prefer discovered target ids or exact path-segment arrays over ambiguous dotted names.

Presets and overrides belong to each job; they do not change saved preferences or panel settings. Outputs are not overwritten. Jobs return JSON results, including individual failures and upload asset IDs. Successful batch items remain available when another fails.

A timeout does not cancel a job. Inspect it with `prism job ID --wait --json`; never automatically repeat an upload after a timeout, lost response or backend restart. Restart Studio after upgrading an older plugin.
