# zswitch

Menu bar app for fast switching between multiple GLM Coding Plan accounts in ZCode.

## How it works

- ZCode stores the account login in `~/.zcode/v2/credentials.json`
  (`oauth:zai:access_token`, `oauth:zai:user_info`, `zcodejwttoken`,
  `oauth:active_provider`), each value AES-256-GCM encrypted with a key derived
  from `zcode-credential-fallback:darwin:<home>:<user>` (or the
  `ZCODE_CREDENTIAL_SECRET` env var). The app reads that file fresh on every
  credential load, so swapping the file switches accounts.
- zswitch snapshots whole `credentials.json` files per account — it never needs
  to decrypt to switch (only to show account labels). Snapshots live in
  `~/.zswitch/accounts/<id>/` (`credentials.json` + `meta.json`).

## Usage

1. Log into account A in ZCode → menu bar 🔄 icon → **Add Account — Capture
   Current Login…** → name it.
2. Log into account B in ZCode → capture again.
3. Click any account in the menu to switch. zswitch first stashes the current
   login back to its snapshot (so refreshed tokens are never lost), atomically
   swaps in the target snapshot, then restarts ZCode.

**Task safety:** before switching it checks whether a task is running
(`~/.zcode-status/thinking|tool` fresher than `done` — written by your ZCode
hooks — plus fresh `~/.zcode/cli/exec/sess_*` activity and a read-only
`tasks-index.sqlite` query). If ZCode is busy you get a "Switch Anyway?" prompt.

## Build / install

```sh
./build.sh   # → ~/Applications/zswitch.app
```

Requires Xcode command line tools. "Launch at Login" in the menu registers a
login item (SMAppService).

## Testing hooks

- `open "zswitch://menu"` — toggle the menu open/closed
- `open "zswitch://capture"` — open the capture dialog

## Files

| Path | Purpose |
|---|---|
| `~/.zswitch/accounts/` | per-account snapshots |
| `~/.zswitch/state.json` | last active userId |
| `main.swift` | the whole app (~500 lines Swift/AppKit) |
