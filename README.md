# Token Watch

Token Watch is an original macOS 26+ SwiftUI menu-bar utility for observing token metadata already present in local Claude Code and Codex transcript files.

## Local-only boundary

- You explicitly select the `.claude` and `.codex` folders; the app requests read-only, sandbox-scoped access.
- It decodes only whitelisted timestamp, model, and token-usage fields from `.claude/projects/**/*.jsonl` and `.codex/sessions/**/*.jsonl`. Record-type and deduplication identifiers are read in memory only, never displayed or persisted.
- Prompts, model responses, source code, paths, session IDs, credentials, account data, costs, rate limits, and provider quotas are not shown or persisted.
- The project declares no network entitlement and ships a privacy audit that rejects common networking APIs.

Recorded token totals are local transcript metadata, not an official provider quota, invoice, or account balance. Token Watch is not affiliated with or endorsed by Anthropic or OpenAI. Keep it private until you have confirmed that this local-metadata use fits your provider and organizational policies.

## Build and test

```sh
./script/audit_privacy.sh
./script/build_and_run.sh --verify
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS,arch=arm64' test
```

The app target includes the App Sandbox and user-selected read-only file-access entitlements. A locally unsigned debug build is sufficient for parser and UI development; select an appropriate signing team before distributing an app bundle.
