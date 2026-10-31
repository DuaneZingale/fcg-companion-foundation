# FCG Foundation — local Otto pilot

This fork evaluates Otto as the desktop conversation and agent runtime for Companion OS.
The existing Companion OS repository, applications, databases and services stay in place.

Current local policy (2026-10-31): knowledge reads and result retrieval require no approval.
Write safeguards remain distinct from the host Codex Full Access setting. Earlier pilot
results below are historical; see the unprompted read integration for the current behavior.

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

## Earlier approval integration result — 2026-10-31

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


## Unprompted read integration — 2026-10-31

`knowledge.read` performs one structured read and returns the result inline. It accepts only
identity, roster/work searches, Lore search and Lore page reads. The agent cannot choose an
actor, executable, shell command or write operation. A private workspace file,
`.otto/knowledge-bridge.json`, binds profile UUIDs (lowercase keys) to canonical actors and an
absolute read-only helper executable. It contains no credentials. Without this optional
configuration, the tool is absent. Unknown profiles fail closed; the existing bridge retains
its source scopes, Lore path confinement and FCG-only relationship-document restriction.

`terminal.wait` and `terminal.read_output` no longer ask to read an existing command's result.
`terminal.run` retains its complete-command confirmation because an arbitrary shell command
cannot be classified as a safe read from its name. Reading the output never asks a second time.

Both provider adapters now grant individual registered read tools, including in read-only
mode. They also retain the existing separate handoff for tools with app-owned confirmation
cards outside read-only mode. These lists never grant the entire MCP server. Scope checks,
connection availability and profile privacy checks still apply; no prompt does not mean no
authorization boundary. Provider callbacks and tools declaring external effects are excluded
from the read grant. `surface.set` is correctly classified as a reversible UI mutation.

### Existing write boundaries

- Gmail send/reply and SMTP send require the app's full-message confirmation. Gmail drafts are
  reversible and do not have that confirmation gate. Connection and send scopes still apply.
- Calendar creation has its existing confirmation card.
- Globally destructive tools (routine deletion, worktree cleanup, closing all nodes) require
  a scope not issued to agent tokens, as well as confirmation. Memory deletion is recoverable
  and restricted to user-initiated calls. Ordinary document/slide edits have different rules;
  not every tool containing “delete” uses the global destructive gate.
- Arbitrary terminal commands retain their command card; provider-native execution uses the
  bot's own permission mode. App cards are not disabled by the provider-bypass preference.
- Host Codex Full Access and Foundation bot permissions are separate. Full Access native
  commands can reach outside these tool-specific guards. These guards are not a universal
  email/delete firewall. This change does not change either global provider configuration or
  the existing bots' permission modes, and it adds no knowledge-write capability.

This is a tool/runtime change with no new UI surface, so no Glyph layer is added.


Validation: 68 targeted tests passed. After a full app restart, both original native
conversations returned a fresh dated Neon receipt through `knowledge.read`, with zero approval
cards and no terminal fallback. The private helper was also pinned to its existing credential
scope so GUI launch directories do not affect connection lookup. A transient tool disconnect
cleared after restart. Existing app files and global provider settings remained unchanged.
Detailed receipts, native session IDs and rollback material remain in private local evidence.


## Full Access for the two Foundation bots — 2026-10-31

The private FCG and Fenwick profiles and their canonical conversations now use `unrestricted`
(the existing UI calls this “Bypass permissions”). Provider-global configuration and the original Companion OS
remain unchanged. Their current role instructions permit ordinary requested edits and drafts
without questions, but require a fresh exact-action decision for sending email or permanently
deleting data. Email must use the app's configured send tools; permanent local deletion must
use the app's guarded `terminal.run`. Denial stops that action without an alternative route.

The provider adapters additionally grant individually registered reversible app tools in Full
Access, so document edits do not fail at the provider layer. Tools declaring external effects,
destructive scope, app confirmation or provider-internal status do not enter that edit list.
The existing question and approval callbacks are individually reachable in Full Access so a
human decision can still be requested. No MCP server-wide grant is added. App send/command
cards and destructive scope restrictions remain enforced by the registry/supervisor.

This is deliberately not a claim of OS-level interception: unrestricted native tools can
operate outside app guards. The cross-route rule is a bot instruction; the protected app
tools enforce their own gates in code. A requirement to technically intercept every arbitrary
shell/API/browser send or deletion would require a different execution boundary from Full
Access. No such universal interception is claimed by this pilot.


Validation: 54 focused tests passed. In the installed app, both original bots edited and read
back isolated files without approval, then displayed both the full-message email approval
callback and a permanent-delete command card in Full Access. All four protected-action cards
were denied. Neither delete command launched, both files remain intact, and no email sender
was invoked (email delivery was not exercised). Both native session IDs and Full Access settings
survived restart. Private receipts retain the evidence and rollback information.

Claude Full Access omits the redundant provider `--permission-prompt-tool` registration,
which otherwise hides that callback from the model's tool catalog. App-level confirmations
remain enforced through the existing control plane; other Claude modes retain the provider
permission callback. This fixes discoverability without disabling any app confirmation.
