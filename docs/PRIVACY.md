# Privacy

Orbit for Claude Code runs entirely on your Mac.

- **What it reads**: the OAuth token Claude Code stores in your keychain (or `~/.claude/.credentials.json`), Claude Code's session files under `~/.claude`, the tail of session transcripts for context-window numbers, today's transcript files for token totals, and the Claude desktop app's local Cowork session records.
- **Where data goes**: the token is sent only to `api.anthropic.com` (usage and profile) and, when refreshing, to `platform.claude.com`. Service status is fetched from `status.claude.com` without any credentials. Nothing else leaves the machine.
- **What it stores**: a small `snapshot.json` (usage numbers, session names, status) in the app's own App Group container, and your settings. No conversation content is stored or displayed beyond session titles.
- **Telemetry**: none. No analytics, no crash reporting.
- **Third parties**: none.

Orbit is an unofficial project and is not affiliated with Anthropic.
