;;; client-live-test.el --- live tests against a running herdr -*- lexical-binding: t; -*-

;; Run: emacs --batch -L lisp -l test/client-live-test.el
;; Requires a running herdr server on the default socket.

(require 'ghostherd-client)

(defvar gh-test--failures 0)

(defun gh-test (name ok &optional detail)
  (message "%s %s%s" (if ok "PASS" "FAIL") name
           (if detail (format " — %s" detail) ""))
  (unless ok (setq gh-test--failures (1+ gh-test--failures))))

;; 1. socket path discovery
(let ((path (ghostherd-client-socket-path)))
  (gh-test "socket-path-discovery"
           (and (string-suffix-p "herdr/herdr.sock" path)
                (file-exists-p path))
           path))

;; explicit override wins
(let ((ghostherd-socket-path "/tmp/explicit.sock"))
  (gh-test "socket-path-explicit-override"
           (equal (ghostherd-client-socket-path) "/tmp/explicit.sock")))

;; session-scoped path
(let ((ghostherd-session "work"))
  (gh-test "socket-path-session"
           (string-suffix-p "herdr/sessions/work/herdr.sock"
                            (ghostherd-client-socket-path))))

;; 2. ping
(let ((pong (ghostherd-client-ping)))
  (gh-test "ping"
           (and (equal (alist-get 'type pong) "pong")
                (numberp (alist-get 'protocol pong)))
           (format "version=%s protocol=%s"
                   (alist-get 'version pong) (alist-get 'protocol pong))))

;; 3. snapshot
(let ((snap (ghostherd-client-snapshot)))
  (gh-test "snapshot-shape"
           (and (listp (alist-get 'workspaces snap))
                (listp (alist-get 'tabs snap))
                (listp (alist-get 'panes snap))
                (listp (alist-get 'agents snap)))
           (format "%d workspaces, %d tabs, %d panes, %d agents"
                   (length (alist-get 'workspaces snap))
                   (length (alist-get 'tabs snap))
                   (length (alist-get 'panes snap))
                   (length (alist-get 'agents snap))))
  (let ((pane (car (alist-get 'panes snap))))
    (gh-test "pane-record-has-terminal-id"
             (and pane (stringp (alist-get 'terminal_id pane)))
             (alist-get 'terminal_id pane))))

;; 4. error handling: bogus method
(gh-test "api-error-signalled"
         (condition-case err
             (progn (ghostherd-client-request "no.such.method") nil)
           (ghostherd-api-error t)
           (error (format "wrong signal: %S" err))))

;; 5. workspace CRUD round-trip
(let* ((created (ghostherd-client-request
                 "workspace.create"
                 `((cwd . "/tmp") (label . "gh-client-test"))))
       (wid (alist-get 'workspace_id (alist-get 'workspace created))))
  (gh-test "workspace-create" (stringp wid) wid)
  (let* ((listed (ghostherd-client-request "workspace.list"))
         (labels (mapcar (lambda (w) (alist-get 'label w))
                         (alist-get 'workspaces listed))))
    (gh-test "workspace-list-contains-created"
             (member "gh-client-test" labels)))
  ;; 6. events: subscribe, then close the test workspace and expect
  ;; a workspace.closed event to arrive.
  (let ((got-event nil))
    ;; herdr replays a backlog of recent events to new subscribers, so
    ;; filter for OUR workspace id instead of taking the first close.
    (add-hook 'ghostherd-client-event-functions
              (lambda (name data)
                (when (and (equal name "workspace_closed")
                           (equal (alist-get 'workspace_id data) wid))
                  (setq got-event data))))
    (ghostherd-client-events-connect)
    (gh-test "events-connected"
             (process-live-p ghostherd-client--events-proc))
    ;; give the ack a moment, then trigger
    (let ((end (+ (float-time) 1.0)))
      (while (< (float-time) end) (accept-process-output nil 0.05)))
    (ghostherd-client-request "workspace.close" `((workspace_id . ,wid)))
    ;; herdr replays the full event backlog to new subscribers before
    ;; delivering live events; the backlog grows with server uptime,
    ;; so allow a generous window.
    (let ((end (+ (float-time) 15.0)))
      (while (and (not got-event) (< (float-time) end))
        (accept-process-output nil 0.05)))
    (gh-test "events-workspace-closed-received"
             (and got-event
                  (equal (alist-get 'workspace_id got-event) wid))
             (format "want=%s got=%S" wid got-event))
    (ghostherd-client-events-disconnect)
    (gh-test "events-disconnected" (null ghostherd-client--events-proc))))

(message "---")
(if (zerop gh-test--failures)
    (message "ALL PASS")
  (progn (message "%d FAILURES" gh-test--failures)
         (kill-emacs 1)))
