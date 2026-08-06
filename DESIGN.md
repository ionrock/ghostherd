# ghostherd — herdr-style agent terminal management in Emacs via ghostel

Status: exploration / design discussion. Nothing here is final.

## Goal

Manage many ghostel terminals in Emacs, grouped the way herdr groups them:

- Space (herdr calls it a "workspace"): top-level container bound to a
  project and/or directory.
- Tab: a terminal (or layout of terminals) inside a space.
- Agent awareness: know when a terminal is running an agent harness
  (claude, codex, fx, ...) and whether it is working / blocked / done /
  idle, and surface that in Emacs (sidebar, mode-line, notifications).

Two possible architectures, which are NOT mutually exclusive:

1. Standalone: pure-Emacs space/tab manager over plain ghostel buffers,
   with our own (weaker) agent detection.
2. herdr-backed: use a running herdr server as the source of truth.
   Ghostel buffers in Emacs become attached clients of herdr panes.
   herdr does detection, persistence, and lifecycle; Emacs is the UI.

## What was verified in the herdr source (github.com/herdrdev/herdr, cloned @ HEAD)

herdr is a Rust background server + attachable clients. Key facts for us:

### Socket API (docs/next/.../socket-api.mdx, src/api/)

- Local unix socket, newline-delimited JSON request/response.
  Default path: `$XDG_CONFIG_HOME/herdr/herdr.sock` (or
  `sessions/<name>/herdr.sock` for named sessions). Overridable with
  `HERDR_SOCKET_PATH`. See `src/api/server.rs::socket_path()`.
- `herdr api schema --json` prints the full JSON Schema of the protocol —
  we can generate/check our elisp client against it.
- Full CRUD on the exact model we want:
  - `workspace.create/list/get/focus/rename/move/close` (+ `--cwd`, labels)
  - `tab.create/list/get/focus/rename/move/close`
  - `pane.split/list/get/read/send_text/send_keys/close/process_info/...`
  - `agent.list/get/read/prompt/wait/rename/focus/start`
- `session.snapshot` = one-shot bootstrap of everything (focused ids,
  workspaces, tabs, panes, agents). Designed exactly for clients keeping a
  local cache — i.e., an Emacs sidebar.
- `events.subscribe` = long-lived push stream over the same socket:
  `workspace.*`, `tab.*`, `pane.created/closed/updated/agent_detected/
  agent_status_changed/exited`, `layout.updated`, etc. Perfect for keeping
  Emacs state live without polling.
  - Verified live against herdr 0.7.5: `pane.created`/`pane.updated`/
    `pane.closed`/`workspace.updated` subscribe globally, but
    `pane.agent_status_changed` requires a `pane_id` filter. So the
    sidebar keeps one global lifecycle subscription and (re)subscribes
    per-pane for agent status as panes come and go — or watches
    `pane.updated` which carries agent state on the pane record.
- Agent states: `working | blocked | done | idle | unknown`.
- Panes get env injected: `HERDR_SOCKET_PATH`, `HERDR_ENV=1`,
  `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`.

### Attaching a real terminal to a herdr pane

Two supported paths, both verified in cli-reference.mdx:

1. `herdr terminal attach <terminal_id> [--takeover]` — full interactive
   attach of the current tty to one pane. This is a normal PTY program, so
   it can run *inside a ghostel buffer* via `ghostel-exec`. Detach is
   `ctrl+b q`.
2. `herdr terminal session control <target>` — structured stream:
   stdout = newline-delimited JSON `terminal.frame` records (base64 ANSI
   bytes), stdin = JSON commands (`terminal.input`, `terminal.resize`,
   `terminal.scroll`, `terminal.release`). One controller per terminal;
   `session observe` allows N read-only watchers.

Path 1 is the pragmatic one: ghostel renders the ANSI; herdr owns the PTY.
Path 2 would let us feed frames into a ghostel VT instance ourselves, but
ghostel's elisp layer expects to own a process, so this is more work for
little gain initially.

### Detection

herdr detects agents from foreground process inspection + "screen
manifests" (bottom-of-screen pattern matching) + optional per-agent hook
integrations (`herdr integration install claude|codex|...`).
`HERDR_AGENT=<agent>` env hint exists for wrapped processes.
Reimplementing this well in elisp is a large project — this is the
strongest argument for the herdr-backed architecture.

## What was verified in ghostel (github.com/dakra/ghostel, cloned @ HEAD)

- Two layers: Zig native module (libghostty-vt, terminal state, PTY I/O)
  + elisp (`lisp/ghostel.el`, ~5.5k lines).
- `ghostel-exec BUFFER PROGRAM &optional ARGS` (public, ghostel.el:5247):
  run an arbitrary program as a ghostel terminal in BUFFER, argv passed
  verbatim, no shell. Exactly what we need to run
  `herdr terminal attach w1:p1` inside an Emacs buffer.
- `ghostel-project` + `ghostel-project-{next,previous,list-buffers}`:
  project-scoped terminals already exist — good precedent, but flat
  (no space/tab model, no agent awareness).
- Rich hook surface we can build on: `ghostel-command-start-functions`,
  `ghostel-command-finish-functions` (shell-integration command lifecycle),
  `ghostel-exit-functions`, title tracking, `ghostel-buffer-name-function`.
- `ghostel-environment` / extra-env plumbing exists for injecting env vars
  at spawn.

## Emacs built-ins evaluated for the UI layer

- `speedbar` — rejected. Frame-oriented, file-tree centric, aging API.
- `tab-bar` / `tab-line` — strong candidate. `tab-line-mode` giving
  per-window buffer tabs maps 1:1 onto "tabs within a space";
  `tab-bar` could optionally represent spaces. Both are core Emacs.
- `tabulated-list-mode` — the boring, reliable choice for a
  space/agent overview buffer (like `list-processes` / magit-process).
- `hierarchy.el` / `treemacs` / `imenu-list` — tree sidebars; treemacs is
  heavy external dep, hierarchy.el is built-in and fine for a
  space → tab → agent tree.
- `project.el` — space ⇄ project association; `project-current`,
  `project-root`, per-project buffer scoping.
- Inspiration (not deps): `perspective.el` / `tabspaces` (workspace =
  filtered buffer set), magit-section (collapsible sidebar sections).

## Proposed architecture (for discussion)

Phase 1 — herdr-backed core:

- `ghostherd-client.el`: unix-socket JSON client
  (`make-network-process :family 'local`), request/response with ids,
  plus a persistent `events.subscribe` connection. Bootstrap via
  `session.snapshot`, then apply events. Socket path discovery mirroring
  herdr's rules (XDG config, sessions dir, `HERDR_SOCKET_PATH`).
- `ghostherd.el`: model + commands.
  - Space = herdr workspace; create with `--cwd` from `project-current`.
  - Tab = herdr tab with (initially) a single pane.
  - `ghostherd-open` on a tab: create/reuse a ghostel buffer running
    `herdr terminal attach <pane_id>` via `ghostel-exec`.
  - Buffer-local vars associate ghostel buffer ⇄ workspace/tab/pane ids.
- `ghostherd-sidebar.el`: tabulated-list or magit-section-style buffer
  showing spaces → tabs → agent state, updated from events.
  Mode-line lighter: counts of blocked/working agents; optional
  notifications on `blocked`.

Phase 2 — nicer UX:

- `tab-line-mode` in ghostel windows showing the tabs of the current space.
- `ghostherd-prompt` (agent.prompt with wait), `ghostherd-read`
  (pane.read into a compilation-mode-ish buffer), jump-to-blocked-agent.

Phase 3 (optional) — standalone fallback mode when no herdr binary:
plain ghostel buffers + registry + best-effort detection via
`process-attributes`/foreground-child inspection. Explicitly degraded.

## Decisions (agreed 2026-08-06)

1. herdr is a hard requirement. No standalone/degraded mode.
2. 1 herdr tab = 1 pane. No herdr splits exposed; Emacs windows +
   multiple ghostel buffers handle side-by-side viewing.
3. Attach lifetime: start visible-only, but an attached ghostel buffer
   may stay attached until the buffer is killed — Emacs runs many
   ghostel terminals fine. Killing the buffer detaches (releases the
   controller); it never closes the herdr pane. Only explicit
   `ghostherd-close-tab` closes panes.
4. Prefix key: `C-c t` bound to `ghostherd-command-map` (users can
   rebind; `C-c t` is the documented default).
5. Notifications fire on transitions to BOTH `blocked` and `done`.

## Keymap spec

Constraint: inside a ghostel attach buffer nearly all keys must flow to
the terminal (herdr's own `ctrl+b` prefix keeps working there — detach,
literal ctrl+b, etc.). Ghostel reserves `C-c` for Emacs via
`ghostel-keymap-exceptions`, so `C-c`-prefixed bindings are the only
safe in-terminal surface.

### Global: `ghostherd-command-map` on `C-c t`

| Key | Command | Notes |
| --- | --- | --- |
| `s` | `ghostherd-switch-space` | completing-read, annotated with agent status |
| `S` | `ghostherd-new-space` | cwd from `project-current`, else prompt |
| `t` | `ghostherd-switch-tab` | within current space |
| `c` | `ghostherd-new-tab` | new terminal in current space |
| `n` / `p` | `ghostherd-next-tab` / `ghostherd-previous-tab` | repeat-mode: `C-c t n n n` |
| `b` | `ghostherd-next-blocked` | cycle blocked agents across ALL spaces |
| `w` | `ghostherd-sidebar-toggle` | |
| `k` | `ghostherd-close-tab` | confirms; the ONLY pane-killing command |
| `r` / `R` | `ghostherd-rename-tab` / `ghostherd-rename-space` | |
| `.` | `ghostherd-prompt-agent` | `agent.prompt` on current tab's agent |
| `g` | `ghostherd-resync` | force `session.snapshot` refresh |

### Sidebar mode (single keys, magit-style)

`RET` visit · `TAB` fold section · `c`/`C` new tab/space at point ·
`k` close at point · `r` rename · `b` next blocked · `g` refresh ·
`q` quit window. Rows: space → tabs, each with a state face.

### Attach buffers

Only the global map, plus buffer-local `C-c C-q` =
`ghostherd-detach` (sends `ctrl+b q`), since remembering herdr's chord
inside Emacs is friction.

## Notification spec

Event-driven off the subscription stream (no polling); dedupe on
`state_change_seq` so a transition never fires twice.

1. Mode-line lighter in `global-mode-string`, always on when connected:
   e.g. `⚑2 ▸3` (2 blocked, 3 working). Clickable → sidebar. Hidden
   when both counts are 0.
2. Transition alerts through `ghostherd-notify-function`, fired on
   transitions to `blocked` and `done` (decision 5). Default:
   `message` + warning-faced lighter. Pluggable for alert.el /
   `osascript display notification` etc. (Same shape as ghostel's
   `ghostel-notification-function`.)
3. Suppression: no alert for a pane whose attach buffer is currently
   visible and focused (mirrors ghostel's command-finish suppression).
   `done` alerts also suppressed if herdr already flipped the pane to
   `idle` (seen) before we render.
4. Faces `ghostherd-blocked` / `-working` / `-done` / `-idle`, used in
   sidebar, completing-read annotations, and the lighter.

Out of scope for v1: sounds, desktop notifications by default, any
binding that shadows herdr's in-terminal prefix.

## Open questions (superseded — kept for history)

1. herdr-required or herdr-optional? Phase 3 costs real complexity;
   detection quality without herdr will be poor.
2. Pane granularity: expose herdr pane *splits* in Emacs, or keep
   1 tab = 1 pane and let Emacs windows do splitting? (Emacs windows +
   multiple attached ghostel buffers per space seems more natural.)
3. Attach mechanics: one long-lived attach per visible tab only, or keep
   attaches alive for background tabs too (cost: one `herdr terminal
   attach` process per pane)? herdr allows read via `pane.read` without
   attaching — background tabs may not need live attaches at all.
4. Detach/kill semantics: killing a ghostel buffer should detach, not
   close the herdr pane. Explicit `ghostherd-close-tab` closes the pane.
5. Does `terminal attach` takeover fight with an attached herdr TUI
   client? (Docs say one controller per terminal; needs a live test.)
6. Name: working title `ghostherd`.

## Verified live (herdr 0.7.5 running locally, socket at ~/.config/herdr/herdr.sock)

- `ping` → `{"type":"pong","version":"0.7.5","protocol":17,...}`.
- `session.snapshot` → `result.snapshot` with keys: version, protocol,
  focused_workspace_id/tab_id/pane_id, workspaces, tabs, panes, layouts,
  agents. Agent records carry: `agent` (e.g. "fx"), `agent_status`
  ("idle"...), `terminal_title`, `workspace_id`, `tab_id`, `pane_id`,
  `cwd`, `foreground_cwd`, `state_change_seq`, `revision`. This is
  everything the sidebar needs, including live detection of fx itself.
- `events.subscribe` acknowledged with `subscription_started` for global
  pane/workspace lifecycle events; `pane.agent_status_changed` requires
  `pane_id`.
- `herdr api schema --json` works: top-level `schemas` with
  `request`, `success_response`, `error_response`, `event`,
  `subscription_event` — usable for generating/checking the elisp client.

## Attach test results (2026-08-06, herdr 0.7.5, Emacs 30.2, ghostel v0.49.0 module)

Method: created scratch workspace `wE` (`herdr workspace create --cwd /tmp
--label ghostherd-test`), ran `ghostel-exec` on
`herdr terminal attach <id>` in `emacs --batch`, sent input via
`ghostel-send-string`, verified pane content via `herdr pane read`.
Workspace closed after the test.

Findings:

- `herdr terminal attach` takes a **terminal_id** (`term_...`), NOT a
  pane id (`wE:p1`). Passing a pane id fails with "terminal wE:p1 not
  found". terminal_id is on every pane/agent record in
  `session.snapshot`, so this is just a mapping detail for the client.
- `terminal attach` is a ratatui program: it needs a real tty (panics
  under plain pipes: "Device not configured") and runs alt-screen.
  Under ghostel's PTY it started fine.
- INPUT PATH VERIFIED end-to-end: `ghostel-send-string` in the attached
  ghostel buffer → herdr → pane shell. Marker command
  `echo ghostherd-marker-$((40+2))` executed in the pane; `herdr pane
  read wE:p1 --source visible` showed `ghostherd-marker-42` output.
- `ctrl+b q` (`"\x02q"`) detached cleanly; attach process exited,
  pane survived.
- RENDER PATH NOT YET VERIFIED: in `emacs --batch` the ghostel buffer
  stayed empty (ghostel redraw needs redisplay/timers that batch mode
  doesn't run properly). Needs a quick interactive-Emacs check; low
  risk given input/detach work and ghostel renders ratatui apps in
  normal use.

## Protocol findings from implementation (herdr 0.7.5, all verified live)

Facts the docs do not spell out, discovered while building and testing:

1. Pushed events are `{"event":"workspace_closed","data":{...}}` —
   underscore names; dotted names are only for subscribing.  EXCEPT
   `pane.agent_status_changed`, which keeps its dotted name on push
   and has a flat payload `{pane_id, agent, agent_status}`.
2. One connection accepts exactly ONE `events.subscribe` request
   (a second gets no ack, silently).  Changing subscriptions means
   reconnecting.
3. Agent status transitions are ONLY observable via per-pane
   `pane.agent_status_changed` subscriptions (`pane_id` required, no
   wildcard).  `pane.updated` does not fire for status changes.  So
   ghostherd subscribes per known pane and reconnects when new panes
   appear (additions only; removals are inert).
4. herdr replays a large event backlog (proportional to server
   uptime) to every new subscriber, before live events.  The stream
   is at-least-once and can interleave stale creates after newer
   events.  Countermeasures in ghostherd.el: creates never overwrite
   cache entries; tombstones for closed workspaces/tabs/panes;
   pane `revision` ordering; snapshots authoritative in both
   directions (clear tombstones for listed, add for missing);
   subscribe only to snapshot- or response-verified panes.
5. Subscribing to a dead pane rejects the WHOLE subscribe with
   `pane_not_found` (connection then useless).  Recovery: tombstone
   the named pane, fresh snapshot, reconnect.
6. `tab.rename`/`workspace.rename` take `label`, not `name`.  Their
   events are flat patches `{tab_id|workspace_id, label}`.
7. `pane.report_agent` (`source`, `agent`, `state`) drives real
   state machinery — ideal for tests.  Valid states are only
   idle/working/blocked/unknown; herdr derives `done` itself from a
   working→idle transition (done = finished-and-unseen).

## Remaining verification steps

- Interactive Emacs: confirm the attached buffer *renders* (batch-mode
  limitation above).
- Hold a subscription open while an agent changes state and confirm the
  pushed event payload shape.
- Confirm `terminal attach` interaction with an already-attached herdr
  TUI client (takeover semantics).

## Repo layout (planned)

    ghostherd/
      DESIGN.md            <- this file
      lisp/
        ghostherd.el
        ghostherd-client.el
        ghostherd-sidebar.el
      test/
