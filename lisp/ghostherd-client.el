;;; ghostherd-client.el --- herdr socket API client -*- lexical-binding: t; -*-

;; Author: ghostherd contributors
;; Keywords: terminals, processes
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; JSON client for the herdr socket API (newline-delimited JSON over a
;; local unix socket).  Provides:
;;
;; - socket path discovery mirroring herdr's rules
;; - synchronous request/response (`ghostherd-client-request')
;; - a persistent event subscription connection with callbacks
;; - a local cache bootstrapped from `session.snapshot' and kept
;;   current from subscription events
;;
;; herdr protocol facts this file relies on (verified against herdr
;; 0.7.5, protocol 17):
;; - requests: {"id":..., "method":..., "params":{...}}\n
;; - success:  {"id":..., "result":{...}}\n
;; - error:    {"id":..., "error":{"code":...,"message":...}}\n
;; - `events.subscribe' acks with result.type "subscription_started",
;;   then pushes event objects on the same connection.  Pushed events
;;   are shaped {"event":"workspace_closed","data":{...}} — note the
;;   underscore event names (subscriptions use dotted names) and the
;;   payload nested under `data'.
;; - herdr REPLAYS a backlog of recent events to new subscribers.
;;   Consumers must treat the stream as at-least-once and dedupe:
;;   bootstrap from `session.snapshot' AFTER connecting, ignore events
;;   for unknown/closed resources, and use `state_change_seq' /
;;   `revision' ordering for agent state.
;; - `pane.agent_status_changed' subscriptions require a `pane_id';
;;   global lifecycle events (pane.created/updated/closed,
;;   workspace.*, tab.*) do not.

;;; Code:

(require 'json)
(require 'cl-lib)

(defgroup ghostherd nil
  "Manage herdr agent terminals from Emacs via ghostel."
  :group 'terminals
  :prefix "ghostherd-")

(defcustom ghostherd-herdr-program "herdr"
  "Name or path of the herdr executable."
  :type 'string)

(defcustom ghostherd-socket-path nil
  "Explicit path to the herdr API socket.
When nil, the path is discovered: $HERDR_SOCKET_PATH, then the
session socket for `ghostherd-session', then the default
$XDG_CONFIG_HOME/herdr/herdr.sock."
  :type '(choice (const :tag "Discover" nil) file))

(defcustom ghostherd-session nil
  "Named herdr session to connect to, or nil for the default session."
  :type '(choice (const :tag "Default session" nil) string))

(defcustom ghostherd-request-timeout 5.0
  "Seconds to wait for a synchronous herdr API response."
  :type 'number)

(defcustom ghostherd-herdr-auto-start t
  "When non-nil, start a herdr server if none is running.
On connection failure (missing socket or refused connection),
ghostherd spawns a detached headless server (`herdr server',
plus `--session' when `ghostherd-session' is set) and retries
until `ghostherd-herdr-start-timeout' elapses."
  :type 'boolean)

(defcustom ghostherd-herdr-start-timeout 10.0
  "Seconds to wait for an auto-started herdr server to accept connections."
  :type 'number)

(defvar ghostherd-client--request-counter 0
  "Monotonic counter used to build request ids.")

;;;; Socket path discovery

(defun ghostherd-client--config-dir ()
  "Return herdr's config directory."
  (let ((xdg (getenv "XDG_CONFIG_HOME")))
    (expand-file-name "herdr" (if (and xdg (not (string-empty-p xdg)))
                                  xdg
                                "~/.config"))))

(defun ghostherd-client-socket-path ()
  "Return the herdr API socket path, mirroring herdr's discovery rules.
Precedence (matches herdr src/server/socket_paths.rs): explicit
`ghostherd-socket-path', then an explicit `ghostherd-session' (like
herdr's --session flag, which beats the env var), then
$HERDR_SOCKET_PATH, then the default session socket."
  (or ghostherd-socket-path
      (and ghostherd-session
           (expand-file-name (format "sessions/%s/herdr.sock" ghostherd-session)
                             (ghostherd-client--config-dir)))
      (let ((env (getenv "HERDR_SOCKET_PATH")))
        (and env (not (string-empty-p env)) env))
      (expand-file-name "herdr.sock" (ghostherd-client--config-dir))))

;;;; Low-level connection

(defun ghostherd-client--connect (name filter sentinel path)
  "Open a socket connection to PATH.
NAME names the process; FILTER and SENTINEL are attached to it."
  (make-network-process
   :name name
   :family 'local
   :service path
   :coding 'utf-8-unix
   :noquery t
   :filter filter
   :sentinel (or sentinel #'ignore)))

(defun ghostherd-client--start-herdr (path)
  "Start a detached headless herdr server and wait for PATH to accept.
Spawns via a shell with nohup so the server survives Emacs exiting.
Signals an error when the socket is not accepting connections within
`ghostherd-herdr-start-timeout' seconds."
  (let* ((args (append (list "server")
                       (and ghostherd-session
                            (list "--session" ghostherd-session))))
         (cmd (concat "nohup "
                      (mapconcat #'shell-quote-argument
                                 (cons ghostherd-herdr-program args) " ")
                      " >/dev/null 2>&1 &")))
    (message "ghostherd: herdr not running, starting `%s server'..."
             ghostherd-herdr-program)
    (call-process-shell-command cmd)
    (let ((deadline (+ (float-time) ghostherd-herdr-start-timeout)))
      (catch 'up
        (while (< (float-time) deadline)
          (when (file-exists-p path)
            (condition-case nil
                (let ((probe (make-network-process
                              :name "ghostherd-herdr-probe"
                              :family 'local :service path :noquery t)))
                  (delete-process probe)
                  (message "ghostherd: herdr server started")
                  (throw 'up t))
              (file-error nil)))
          (sleep-for 0.2))
        (error "ghostherd: started herdr but %s did not accept connections within %gs"
               path ghostherd-herdr-start-timeout)))))

(defun ghostherd-client--open (name filter &optional sentinel)
  "Open a connection to the herdr socket.
NAME names the process; FILTER and SENTINEL are attached to it.
When the socket is missing or refuses connections (herdr not
running) and `ghostherd-herdr-auto-start' is non-nil, starts a
headless herdr server first.  Signals an error when herdr stays
unreachable."
  (let ((path (ghostherd-client-socket-path)))
    (condition-case err
        (progn
          (unless (file-exists-p path)
            (signal 'file-missing
                    (list "herdr socket not found (is herdr running?)" path)))
          (ghostherd-client--connect name filter sentinel path))
      (file-error
       (unless ghostherd-herdr-auto-start
         (signal (car err) (cdr err)))
       (ghostherd-client--start-herdr path)
       (ghostherd-client--connect name filter sentinel path)))))

(defun ghostherd-client--json-encode (object)
  "Encode OBJECT as a JSON line for herdr."
  (concat (json-serialize object :null-object :null :false-object :false)
          "\n"))

(defun ghostherd-client--json-parse (line)
  "Parse one JSON LINE from herdr into an alist tree."
  (json-parse-string line
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

;;;; Synchronous request

(defun ghostherd-client-request (method &optional params)
  "Send METHOD with PARAMS to herdr and return the `result' alist.
Opens a fresh connection per request (herdr supports this; the CLI
does the same).  Signals `ghostherd-api-error' on an error response
and `error' on timeout."
  (let* ((id (format "gh_%d" (cl-incf ghostherd-client--request-counter)))
         (buffer "")
         (response nil)
         (proc (ghostherd-client--open
                (format "ghostherd-req-%s" id)
                (lambda (_proc chunk)
                  (setq buffer (concat buffer chunk))
                  (when (string-suffix-p "\n" buffer)
                    (setq response (ghostherd-client--json-parse
                                    (string-trim buffer))))))))
    (unwind-protect
        (progn
          (process-send-string
           proc
           (ghostherd-client--json-encode
            `((id . ,id)
              (method . ,method)
              (params . ,(or params (make-hash-table :size 1))))))
          (let ((deadline (+ (float-time) ghostherd-request-timeout)))
            (while (and (not response) (< (float-time) deadline))
              (accept-process-output proc 0.05)))
          (unless response
            (error "ghostherd: timeout waiting for %s" method))
          (let ((err (alist-get 'error response)))
            (when err
              (signal 'ghostherd-api-error
                      (list method
                            (alist-get 'code err)
                            (alist-get 'message err)))))
          (alist-get 'result response))
      (when (process-live-p proc)
        (delete-process proc)))))

(define-error 'ghostherd-api-error "herdr API error")

;;;; Convenience wrappers

(defun ghostherd-client-ping ()
  "Ping the herdr server; return the pong result alist."
  (ghostherd-client-request "ping"))

(defun ghostherd-client-snapshot ()
  "Return the `session.snapshot' snapshot alist."
  (alist-get 'snapshot (ghostherd-client-request "session.snapshot")))

;;;; Event subscription connection

(defvar ghostherd-client--events-proc nil
  "Live event subscription process, or nil.")

(defvar ghostherd-client--events-buffer ""
  "Partial line buffer for the event connection.")

(defvar ghostherd-client-event-functions nil
  "Abnormal hook run with (EVENT-NAME DATA) per pushed event.
EVENT-NAME is the underscore-style string herdr pushes, e.g.
\"workspace_closed\" or \"pane_updated\".  DATA is the event's
`data' alist.")

(defvar ghostherd-client-disconnect-functions nil
  "Abnormal hook run with the sentinel event string when the
event connection dies.")

(defvar ghostherd-client-subscribe-error-functions nil
  "Abnormal hook run with the error alist when `events.subscribe'
is rejected.  The connection is already closed when this runs;
handlers should refresh state and reconnect.")

(defconst ghostherd-client--global-subscriptions
  '("workspace.created" "workspace.updated" "workspace.renamed"
    "workspace.moved" "workspace.closed" "workspace.focused"
    "tab.created" "tab.closed" "tab.focused" "tab.renamed" "tab.moved"
    "pane.created" "pane.updated" "pane.closed" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected")
  "Event types subscribed globally (no resource filter needed).
Agent state arrives on `pane.updated' pane records, so per-pane
`pane.agent_status_changed' subscriptions are not required for the
cache or notifications.")

(defun ghostherd-client--events-filter (_proc chunk)
  "Accumulate CHUNK, dispatch complete event lines."
  (setq ghostherd-client--events-buffer
        (concat ghostherd-client--events-buffer chunk))
  (while (string-match "\n" ghostherd-client--events-buffer)
    (let ((line (substring ghostherd-client--events-buffer 0 (match-beginning 0))))
      (setq ghostherd-client--events-buffer
            (substring ghostherd-client--events-buffer (match-end 0)))
      (unless (string-empty-p (string-trim line))
        (let ((event (condition-case err
                         (ghostherd-client--json-parse line)
                       (error
                        (message "ghostherd: bad event line: %s" err)
                        nil))))
          (when event
            (cond
             ;; Subscription ack (success or failure) — not an event.
             ((and (alist-get 'id event)
                   (or (alist-get 'result event) (alist-get 'error event)))
              (let ((err (alist-get 'error event)))
                (when err
                  ;; Recoverable: e.g. a per-pane subscription raced a
                  ;; pane close.  Drop the connection and let
                  ;; subscribers resync; do not signal from a filter.
                  (message "ghostherd: events.subscribe rejected: %s"
                           (alist-get 'message err))
                  (ghostherd-client-events-disconnect)
                  (run-hook-with-args
                   'ghostherd-client-subscribe-error-functions err))))
             ((alist-get 'event event)
              (run-hook-with-args 'ghostherd-client-event-functions
                                  (alist-get 'event event)
                                  (alist-get 'data event)))
             (t
              (message "ghostherd: unrecognized line on event socket: %S"
                       event)))))))))

(defun ghostherd-client--events-sentinel (_proc event)
  "Handle event connection death, run disconnect hooks with EVENT."
  (setq ghostherd-client--events-proc nil)
  (run-hook-with-args 'ghostherd-client-disconnect-functions event))

(defvar ghostherd-client-extra-subscriptions nil
  "Extra subscription specs (alists) appended to the global set.
herdr accepts exactly ONE `events.subscribe' request per connection,
so changing this list requires `ghostherd-client-events-reconnect'.
Used for per-pane `pane.agent_status_changed' subscriptions, which
require a `pane_id' and are the only way to observe agent status
transitions (they do not emit `pane.updated').")

(defun ghostherd-client--subscription-specs ()
  "Return the full subscription spec list for a new connection."
  (append
   (mapcar (lambda (type) `((type . ,type)))
           ghostherd-client--global-subscriptions)
   ghostherd-client-extra-subscriptions))

(defun ghostherd-client-events-connect ()
  "Open (or return) the persistent event subscription connection.
Subscribes to the global set plus
`ghostherd-client-extra-subscriptions'."
  (or (and ghostherd-client--events-proc
           (process-live-p ghostherd-client--events-proc)
           ghostherd-client--events-proc)
      (let ((proc (ghostherd-client--open
                   "ghostherd-events"
                   #'ghostherd-client--events-filter
                   #'ghostherd-client--events-sentinel)))
        (setq ghostherd-client--events-buffer "")
        (process-send-string
         proc
         (ghostherd-client--json-encode
          `((id . "gh_sub")
            (method . "events.subscribe")
            (params
             . ((subscriptions
                 . ,(vconcat (ghostherd-client--subscription-specs))))))))
        (setq ghostherd-client--events-proc proc))))

(defun ghostherd-client-events-reconnect ()
  "Tear down and reopen the event connection with current subscriptions.
Safe to call from event handlers: the actual reconnect happens on a
zero-delay timer.  herdr replays a backlog to new subscribers, so
consumers must already tolerate duplicate events."
  (run-at-time
   0 nil
   (lambda ()
     (when (and ghostherd-client--events-proc
                (process-live-p ghostherd-client--events-proc))
       ;; Silence the sentinel-driven disconnect hooks for an
       ;; intentional reconnect.
       (set-process-sentinel ghostherd-client--events-proc #'ignore)
       (delete-process ghostherd-client--events-proc))
     (setq ghostherd-client--events-proc nil)
     (ghostherd-client-events-connect))))

(defun ghostherd-client-events-disconnect ()
  "Close the event subscription connection if open."
  (when (and ghostherd-client--events-proc
             (process-live-p ghostherd-client--events-proc))
    (delete-process ghostherd-client--events-proc))
  (setq ghostherd-client--events-proc nil))

(provide 'ghostherd-client)
;;; ghostherd-client.el ends here
