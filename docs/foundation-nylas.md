# Foundation Nylas inbox connection

Foundation exposes narrowly scoped Nylas v3 tools through its existing agent control plane.
The provider, model and conversation session stay unchanged. This adds no new UI surface;
the existing conversation, tool results and approval cards are used.

Private configuration lives at `<workspace>/.otto/nylas.json`:

```json
{
  "credentialExecutable": "/absolute/private/nylas-credential",
  "region": "us",
  "accountsByProfileID": {
    "lowercase-profile-uuid": ["work@example.com"]
  }
}
```

The helper receives no arguments and returns only the API key on stdout. The app captures
it privately once per application lifetime, including concurrent calls, and keeps it in
memory. Do not run this helper in an agent transcript. Use an existing scoped credential
resolver; never put an API key in this configuration, source control or bot instructions.
Credential resolution has a 60-second outer deadline; failure requires a restart after
repair, rather than repeated vault reads. Only US/EU Nylas API hosts are accepted. HTTP redirects are refused. No automatic
write retry is performed, and provider error bodies are not echoed. Each HTTP request has
a 30-second resource deadline; the MCP socket covers the bounded credential/grant/provider
chain instead of abandoning it at the ordinary ten-second timeout.

The app binds access from the caller's actual node/profile, not an actor or grant supplied
by the model. Account listings resolve current grants; subsequent calls use the corresponding
valid grant ID (cached in memory for at most five minutes). Personal accounts are excluded
unless explicitly configured. No grant ID is hardcoded into the configuration.

| Tools | Behavior |
| --- | --- |
| `nylas.accounts`, `search`, `read`, `folders`, `drafts` | No approval; reads do not mark mail read. Search/list results have pagination. |
| `nylas.sort` | Full Access permits reversible read/star/label edits. Label edits preserve unrelated labels; removing INBOX archives. Returns before state plus provider readback. Rejects trash/spam/sent/draft folder changes. |
| `nylas.draft` | Full Access permits creating/updating actual provider drafts. `replyToMessageID` threads replies. POST creates; PUT updates. Neither route sends. |
| `nylas.send` | Always requires the native approval card. Displays account, To/CC/BCC, subject, reply target and entire plain-text body. Sends explicitly supplied contents, never a mutable draft by ID. |
| `nylas.delete_permanently` | Always requires an irreversible-action card for one exact account/message/subject. Re-reads and matches the subject before DELETE with `hard_delete=true`. Never enables the provider's hard-delete feature or falls back. |

Send and permanent-delete operations declare external effects for the existing durable
receipt/deduplication mechanism. A denied/cancelled card never invokes the HTTP handler.
Oversized/hidden approval content is refused. Plain-text outbound bodies are HTML-escaped,
so they cannot conceal HTML instructions, remote images, or attachments. Attachments,
scheduled sends, bulk deletion, mailbox filters, folder deletion and calendar mutations are
not implemented by this connection. Sending reviewed draft content leaves the draft in
place; there is no silent draft deletion.

These are enforcement boundaries of the Foundation tools. Native provider Full Access
still permits ordinary local execution; bot instructions prohibit bypassing a denial with
CLI, browser, direct API or another bot. This is not a universal OS-level mail firewall.

## Validation

Run `scripts/otto-swift test --jobs 4 --filter 'NylasToolsTests|NylasTransportTimeoutTests|PermissionPromptToolTests|EmailRepliesTests|KnowledgeReadTests'`.
Tests cover account binding, single credential resolution, encoded IDs, draft versus send
routes, exact recipient previews, stale deletion targets, label preservation, refusal of
dangerous folders, redacted failures and confirmation gating under Full Access.

For live verification, resume the existing bot in the installed app. Read each configured
inbox, read a full message, save and read back a clearly labelled draft, and toggle/restore
one reversible flag with before/after receipts. Exercise send/delete cards with synthetic
targets and deny them. Never deliver a test email or permanently delete mail to prove a
guard. Keep any private receipts outside the repository.

API references: [drafts](https://developer.nylas.com/docs/reference/api/drafts/),
[message updates](https://developer.nylas.com/docs/reference/api/messages/put-messages-id/),
[deletion semantics](https://developer.nylas.com/docs/reference/api/messages/delete-message/).
