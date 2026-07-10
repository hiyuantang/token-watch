# Token Watch

Token Watch is an original macOS 26+ SwiftUI menu-bar utility for observing token metadata already present in local Claude Code, Codex, and OpenCode data.

## Local-only boundary

- The app auto-discovers `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`, and `~/.local/share/opencode/opencode.db` on launch. Access is read-only; no folder picker is shown.
- For Claude Code and Codex it decodes only whitelisted timestamp, model, and token-usage fields from the JSONL transcripts. For OpenCode it reads only the `session` table's token-total columns and `model` id from `opencode.db` via the system `sqlite3` CLI. Record-type and deduplication identifiers are read in memory only, never displayed or persisted.
- Prompts, model responses, source code, paths, session IDs, credentials, account data, rate limits, and provider quotas are not shown or persisted.
- The project declares no network entitlement and ships a privacy audit that rejects common networking APIs.
- An optional **estimated cost** is derived locally by multiplying observed token totals against a static, hand-maintained catalog of published API rates (`docs/pricing.md`, `TokenWatch/Support/Pricing.swift`). It is an illustration, not an invoice: batch, peak, fast-mode, data-residency, and write-premium pricing are not modeled.

Recorded token totals and the derived cost estimate are local transcript metadata, not an official provider quota, invoice, or account balance. Token Watch is not affiliated with or endorsed by any provider. Keep it private until you have confirmed that this local-metadata use fits your provider and organizational policies.

## Build and test

```sh
./script/audit_privacy.sh
./script/build_and_run.sh --verify
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS,arch=arm64' test
```

The app target ships with no App Sandbox and no network entitlement. A locally unsigned debug build is sufficient for parser and UI development; select an appropriate signing team before distributing an app bundle.
