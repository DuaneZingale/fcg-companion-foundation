# FCG Foundation — local Otto pilot

This fork evaluates Otto as the desktop conversation and agent runtime for Companion OS.
The existing Companion OS repository, applications, databases and services stay in place.

Current local status (2026-10-31): both companions have completed live knowledge reads through
explicit in-app approvals. See the approval integration result below; the first pilot's blocker
is retained as historical evidence.

## Baseline

Upstream starting point: `maxtrigify/Otto` at
`728011af7dc3576151835199032214fb196d0a9c`.

The first pilot keeps the upstream Swift runtime and UI unchanged. Its local application
bundle is named **FCG Foundation** with identifier `com.freshcutgrass.foundation.dev`.
The installer retains LICENSE, NOTICE and third-party notices. No upstream application icon
is installed. This is a local development pilot, not a redistributed branded release.

## Build and install

Follow AGENTS.md. Work on a separate `codex/...` worktree created with
`scripts/otto-worktree`. Use `scripts/otto-swift`, the committed dependency lock, and a
dedicated `OTTO_SWIFT_STATE_ROOT`. Do not build over another app's active cache.

After a successful guarded debug build, run:

```sh
python3 scripts/install-foundation.py --bin-dir /absolute/path/to/guarded/build/debug
```

The installer refuses to overwrite an existing Foundation bundle. Quit it and retain a
backup before any replacement. It does not install a launch agent, create a signing identity,
modify provider-global settings, start a background watcher, or migrate the existing FCG app.

## Private configuration

Member profiles, conversation history, source receipts, credentials and business knowledge
must never be committed to this public fork. The pilot uses a separate private workspace.
Otto's app-level persistence still uses its upstream `Library/Application Support/Otto`
location; check for an existing Otto or Muse installation before initializing it. A different
bundle identifier alone does not isolate these hard-coded paths.

FCG and Fenwick retain their canonical actor identities. Load each member's own Neon identity
and Lore; do not make Fenwick inherit FCG's personality. Existing native conversations remain
owned by their existing harness. New Foundation conversations are explicitly new conversations,
not a claimed migration or continuation of another app's session.

The initial knowledge connection is read-only. Use the existing private Companion knowledge
implementation and source credentials outside this repository. No new business-write,
external-send or autonomous-scheduling authority is established by importing a bot profile.

## Acceptance

1. Send a real prompt through the running app and receive the actual provider response.
2. Verify one harmless workspace file read through the agent, with a real tool receipt.
3. Quit and relaunch the app. Resume the same conversation and provider session; verify recall
   of a synthetic phrase without placing the phrase into the follow-up prompt.
4. Add FCG and Fenwick from verified private sources, then verify a response from each and a
   real scoped knowledge read. Record source dates and session identities privately.

Build success is not conversation proof. Saved text alone is not provider-session continuity.
Phone, voice, CarPlay, cloud execution and migration of existing conversations are later work.
No custom UI is authored in this bootstrap, so no Glyph review layer is added in this phase.

## Pilot result — 2026-10-30

- Guarded debug build, local packaging and signature verification passed.
- The running app completed a real Codex conversation and a synthetic workspace file read.
- After a full app quit and relaunch, Codex resumed the same native session and recalled both
  the phrase and file check code without either answer in the follow-up prompt.
- FCG and Fenwick responded with their distinct source-backed identities. Fenwick's Claude
  conversation also recalled its test phrase after a full restart in the same native session.
- Private identity sources and the read-only knowledge helper were checked separately.
  **Agent-initiated live knowledge is not accepted yet:** Codex rejected Otto `terminal.run`
  with `MCP tool call requires approval, but approval policy is never`. The lookup did not run.
  No broader approval setting was enabled and the blocked call was not retried through another route.
- Existing Companion OS files matched their pre-install preservation manifest.

Session IDs, source snapshots and detailed receipts stay in the private local evidence folder.
The next integration task is an approval-preserving knowledge connection; profile snapshots
must not be described as live retrieval. Upstream UI labels and app-level storage paths remain.

## Approval integration result — 2026-10-31

`terminal.run`, `terminal.wait` and `terminal.read_output` now require Otto confirmation.
The existing provider adapters hand off only these individually guarded tools to Otto; there
is no server-wide grant, global configuration edit or switch to unrestricted permissions.
The registry still checks scopes before confirmation, and read-only launches gain no grant.

The command card shows the shell and entire command. Oversized commands and hidden control
characters are refused instead of being truncated. Output retrieval has its own card naming
the terminal. Approve permits that call; Deny prevents execution or output disclosure. A later
call requires another decision. The existing provider-bypass preference does not bypass these
explicit terminal cards. This intentionally means a lookup may ask twice: run, then read.

Validation: 64 targeted tests passed across the provider permission, application control,
terminal waiting and permission-prompt suites. Coverage includes real shell execution only
after approval, denial, cancellation, scope enforcement, subsequent calls needing approval,
output withholding on denial, and full command display. In the installed app, an intentionally
denied FCG lookup stopped without creating a command terminal. FCG/Codex and Fenwick/Claude
then each returned a fresh dated knowledge receipt after command and output approval.

An additional local collision was found: the desktop app claimed writer locks for Foundation
sessions in the default Codex home. The private installation now uses Otto's existing named
provider-account isolation for FCG, with the same login and a separate session store. Only
Foundation's FCG journals were copied; source history remains intact. Do not share session or
lock directories with another active host, and do not kill the desktop app to release a lock.
Fenwick retains his original Claude session and provider configuration.

The installed build, rollback bundles, isolated account configuration and detailed verification
receipts remain local. Private knowledge, login material and session histories are not in this fork.
