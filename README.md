# ghostherd

Manage [herdr](https://herdr.dev) agent terminals from Emacs.

herdr organizes AI coding agents into *spaces* (workspaces) and *tabs*,
each backed by a real terminal. ghostherd talks to the herdr API socket
and renders attached terminals inside Emacs using
[ghostel](https://github.com/dakra/ghostel) (libghostty-based terminal
emulation), so you can herd your agents without leaving Emacs:

- Switch between spaces and tabs with `completing-read`.
- Attach any agent terminal in a fully interactive Emacs buffer.
  Detaching (or killing the buffer) never kills the underlying
  process — the herdr TUI keeps working in parallel.
- A sidebar showing every space, tab, and live agent status.
- A mode-line lighter with blocked/working/done counts, plus alerts
  when an agent gets blocked or finishes while you're not looking.
- Jump straight to the next blocked agent from anywhere.

## Requirements

- Emacs 30+ built with tree-sitter-era module support (ghostel uses a
  dynamic module).
- [ghostel](https://github.com/dakra/ghostel) installed and working
  (`M-x ghostel` should give you a terminal).
- `herdr` 0.7.5+ on your `PATH` with a running server (`herdr` in a
  terminal, or its daemon). ghostherd talks to the same API socket the
  herdr TUI uses.

## Installation (straight.el)

```elisp
;; ghostel first — ghostherd requires it at attach time.
(straight-use-package
 '(ghostel :type git :host github :repo "dakra/ghostel"))

(straight-use-package
 '(ghostherd :type git :host github :repo "ionrock/ghostherd"
             :files ("lisp/*.el")))
```

Or with `use-package` integration:

```elisp
(use-package ghostel
  :straight (:type git :host github :repo "dakra/ghostel"))

(use-package ghostherd
  :straight (:type git :host github :repo "ionrock/ghostherd"
             :files ("lisp/*.el"))
  :bind-keymap ("C-c t" . ghostherd-command-map)
  :config
  (require 'ghostherd-notify)
  (require 'ghostherd-sidebar)
  (ghostherd-notify-mode 1))
```

## Quick start

1. Make sure herdr is running with at least one space.
2. `M-x ghostherd-connect` (commands do this on demand too).
3. `C-c t s` — pick a space; its active tab opens in an attach buffer.
4. `C-c t w` — toggle the sidebar.
5. `M-x ghostherd-notify-mode` — turn on alerts and the mode-line
   lighter (or enable it in your init as above).

## Example init.el

A complete configuration with every option set to its default, so you
can see what's tweakable:

```elisp
(use-package ghostherd
  :straight (:type git :host github :repo "ionrock/ghostherd"
             :files ("lisp/*.el"))
  :bind-keymap ("C-c t" . ghostherd-command-map)
  :custom
  ;; Connection
  (ghostherd-herdr-program "herdr")
  (ghostherd-socket-path nil)          ; nil = auto-discover
  (ghostherd-session nil)              ; nil = default herdr session
  (ghostherd-request-timeout 5.0)
  ;; Attach buffers
  (ghostherd-attach-buffer-name-format "*herd:%s/%s*")
  ;; Notifications
  (ghostherd-notify-function #'ghostherd-notify-message)
  (ghostherd-notify-statuses '("blocked" "done"))
  ;; Sidebar
  (ghostherd-sidebar-buffer-name "*ghostherd*")
  (ghostherd-sidebar-width 34)
  (ghostherd-sidebar-side 'left)
  (ghostherd-sidebar-refresh-interval 2.0) ; nil disables polling
  :config
  (require 'ghostherd-notify)
  (require 'ghostherd-sidebar)
  (ghostherd-notify-mode 1))
```

## Configuration options

All options live in the `ghostherd` customization group
(`M-x customize-group RET ghostherd`).

### Connection (ghostherd-client.el)

#### `ghostherd-herdr-program` (default `"herdr"`)

Name or path of the herdr executable. Used both for socket discovery
fallbacks and to spawn `herdr terminal attach <id>` inside ghostel
buffers. Set this to an absolute path if herdr isn't on the `PATH`
Emacs sees:

```elisp
(setq ghostherd-herdr-program "/opt/homebrew/bin/herdr")
```

#### `ghostherd-socket-path` (default `nil`)

Explicit path to the herdr API socket. When `nil`, the socket is
discovered in this order (mirroring herdr's own rules, where an
explicit `--session` beats the environment variable):

1. The session socket for `ghostherd-session`, when that is set
2. `$HERDR_SOCKET_PATH` (set inside herdr-spawned terminals)
3. `$XDG_CONFIG_HOME/herdr/herdr.sock` (default herdr location)

Only set this if you run herdr with a non-standard socket:

```elisp
(setq ghostherd-socket-path "~/some/where/herdr.sock")
```

#### `ghostherd-session` (default `nil`)

Named herdr session to connect to (`herdr --session NAME`). `nil`
means the default session. Ignored when `ghostherd-socket-path` is
set explicitly.

```elisp
(setq ghostherd-session "work")
```

#### `ghostherd-request-timeout` (default `5.0`)

Seconds to wait for a synchronous API response before signaling an
error. Raise it if you run herdr on a loaded machine.

### Attach buffers (ghostherd.el)

#### `ghostherd-attach-buffer-name-format` (default `"*herd:%s/%s*"`)

Format string for attach buffer names. Receives two arguments: the
space label and the tab label. Example: with the default, attaching
to tab `2` in space `normative` names the buffer `*herd:normative/2*`.

```elisp
;; Flat names: *normative:2*
(setq ghostherd-attach-buffer-name-format "*%s:%s*")
```

### Notifications (ghostherd-notify.el)

These take effect when `ghostherd-notify-mode` is enabled.

#### `ghostherd-notify-function` (default `#'ghostherd-notify-message`)

Function called with `(PANE STATUS)` when an agent transitions into a
status listed in `ghostherd-notify-statuses` *and* its buffer is not
currently visible in the selected window. `PANE` is the raw herdr
pane record (an alist with `pane_id`, `workspace_id`, `tab_id`,
`agent`, `agent_status`, ...); `STATUS` is a string like `"blocked"`.

The default echoes a colored `message`. Replace it to integrate
`alert.el` or desktop notifications:

```elisp
;; macOS notification center
(setq ghostherd-notify-function
      (lambda (pane status)
        (call-process "osascript" nil nil nil "-e"
                      (format "display notification \"%s\" with title \"herdr: %s\""
                              (or (alist-get 'agent pane) "agent")
                              status))))

;; alert.el
(setq ghostherd-notify-function
      (lambda (pane status)
        (alert (format "%s %s" (alist-get 'agent pane) status)
               :title "herdr" :severity (if (equal status "blocked") 'high 'normal))))
```

Notes on behavior:

- Only *transitions* notify. The first status observed for a pane
  (from the snapshot at connect time) never alerts, so reconnecting
  doesn't replay a wall of stale notifications.
- A pane whose attach buffer is in the selected window never alerts —
  you're already looking at it.

#### `ghostherd-notify-statuses` (default `'("blocked" "done")`)

Which agent statuses trigger the notify function. herdr reports
`"idle"`, `"working"`, `"blocked"`, and `"done"`. For alerts only when
an agent needs input:

```elisp
(setq ghostherd-notify-statuses '("blocked"))
```

#### Faces

Four faces color agent status everywhere (lighter, sidebar, echo
area). Customize via `M-x customize-face` or `set-face-attribute`:

| Face                | Default inherits    | Used for        |
|---------------------|---------------------|-----------------|
| `ghostherd-blocked` | `error`, bold       | blocked agents  |
| `ghostherd-working` | `success`           | working agents  |
| `ghostherd-done`    | `warning`           | done agents     |
| `ghostherd-idle`    | `shadow`            | idle/no agent   |

### Sidebar (ghostherd-sidebar.el)

#### `ghostherd-sidebar-buffer-name` (default `"*ghostherd*"`)

Name of the sidebar buffer.

#### `ghostherd-sidebar-width` (default `34`)

Width in columns of the sidebar side window.

#### `ghostherd-sidebar-side` (default `'left`)

Which side of the frame the sidebar occupies: `'left` or `'right`.

```elisp
(setq ghostherd-sidebar-side 'right
      ghostherd-sidebar-width 40)
```

#### `ghostherd-sidebar-refresh-interval` (default `2.0`)

Seconds between authoritative `session.snapshot` refreshes while the
sidebar is visible. Push events still update it immediately; polling
reconciles missed or unavailable events. Set this to `nil` to use only
the event stream. The timer stops when the sidebar is hidden or killed.

### Terminal layout

From the sidebar, press `l` and select one or more terminals with
`completing-read-multiple` (comma-separated). ghostherd keeps the
sidebar in a dedicated side window and asks Emacs to arrange the chosen
attach buffers in the main window area. Press `L` to restore the window
configuration that existed before the layout. Re-running `l` changes
the selected terminals without replacing that saved configuration.

The same commands are available as `M-x ghostherd-sidebar-layout` and
`M-x ghostherd-sidebar-restore-layout`.

## Keymap

`ghostherd-command-map` is a prefix map; bind it wherever you like
(`C-c t` is the suggested binding):

```elisp
(keymap-global-set "C-c t" ghostherd-command-map)
```

| Key       | Command                    | What it does                                  |
|-----------|----------------------------|-----------------------------------------------|
| `C-c t s` | `ghostherd-switch-space`   | Pick a space; attach its active tab           |
| `C-c t S` | `ghostherd-new-space`      | New space (defaults to current project root)  |
| `C-c t t` | `ghostherd-switch-tab`     | Pick a tab in the current space               |
| `C-c t c` | `ghostherd-new-tab`        | New tab in the current space, attach it       |
| `C-c t n` | `ghostherd-next-tab`       | Next tab in this buffer's space               |
| `C-c t p` | `ghostherd-previous-tab`   | Previous tab in this buffer's space           |
| `C-c t b` | `ghostherd-next-blocked`   | Jump to next blocked agent (cycles spaces)    |
| `C-c t k` | `ghostherd-close-tab`      | Close a herdr tab — kills its process, confirms |
| `C-c t r` | `ghostherd-rename-tab`     | Rename a tab                                  |
| `C-c t R` | `ghostherd-rename-space`   | Rename a space                                |
| `C-c t g` | `ghostherd-resync`         | Re-sync the cache from herdr                  |
| `C-c t w` | `ghostherd-sidebar-toggle` | Toggle the sidebar (requires ghostherd-sidebar) |

`ghostherd-next-tab`, `ghostherd-previous-tab`, and
`ghostherd-next-blocked` are `repeat-mode` aware: with
`(repeat-mode 1)`, after `C-c t n` you can keep pressing `n`/`p`/`b`.

### Inside an attach buffer

The buffer is a live ghostel terminal — keys go to the agent. Useful
extras:

- `M-x ghostherd-detach` — detach from the pane (sends herdr's
  `ctrl+b q`). The buffer's process ends; the agent keeps running.
- Killing the buffer also just detaches. **Nothing you do to Emacs
  buffers ever kills an agent** — only `ghostherd-close-tab` does,
  and it asks first.

### Sidebar keys

| Key   | What it does                                             |
|-------|----------------------------------------------------------|
| `RET` | Visit thing at point (attach tab, or space's active tab) |
| `TAB` | Fold/unfold space at point                               |
| `c`   | New tab in space at point                                |
| `C`   | New space                                                |
| `k`   | Close tab at point (confirms; kills the herdr pane)      |
| `r`   | Rename tab or space at point                             |
| `b`   | Jump to next blocked agent                               |
| `g`   | Resync from herdr                                        |
| `l`   | Select terminals and arrange them beside the sidebar      |
| `L`   | Restore the pre-layout window configuration               |
| `n`/`p` | Next/previous line                                     |
| `q`   | Hide the sidebar                                         |

Status glyphs: `⚑` blocked · `▸` working · `✓` done · `·` idle.

## Commands not on the keymap

- `ghostherd-connect` / `ghostherd-disconnect` — explicit connection
  management. Commands auto-connect, so you rarely need these.
- `ghostherd-notify-mode` — global minor mode for alerts + lighter.
  The lighter shows e.g. `⚑1 ▸2` and is clickable (mouse-1 toggles
  the sidebar).
- `ghostherd-sidebar-open` — open (and select) the sidebar.

## Extending

`ghostherd-cache-update-hook` runs after every cache change (snapshot
resync or incoming event). The sidebar and lighter are both driven by
it; your own UI can be too:

```elisp
(add-hook 'ghostherd-cache-update-hook #'my/refresh-agent-dashboard)
```

Cache accessors: `ghostherd-spaces`, `ghostherd-tabs`,
`ghostherd-tab-pane`, `ghostherd-blocked-panes`,
`ghostherd-current-space`. Raw API access:
`(ghostherd-client-request METHOD PARAMS)`.

## Tests

The suites in `test/` run against a **real herdr server** — they
create scratch workspaces (`/tmp`-rooted), drive real agent-status
transitions via `pane.report_agent`, and clean up after themselves:

```sh
emacs --batch -L lisp -l test/client-live-test.el
emacs --batch -L lisp -l test/ghostherd-live-test.el
emacs --batch -L lisp -l test/notify-live-test.el
emacs --batch -L lisp -l test/sidebar-live-test.el
```

## Design

See [DESIGN.md](DESIGN.md) for the architecture, the herdr API
surface used, and protocol findings (event names, snapshot shape,
terminal-id vs pane-id) verified against herdr 0.7.5.
