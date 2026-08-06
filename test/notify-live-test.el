;;; notify-live-test.el --- live tests for ghostherd-notify -*- lexical-binding: t; -*-

;; Run: emacs --batch -L lisp -l test/notify-live-test.el
;; Drives real agent state transitions with pane.report_agent.

(require 'ghostherd-notify)

(defvar gh-test--failures 0)
(defun gh-test (name ok &optional detail)
  (message "%s %s%s" (if ok "PASS" "FAIL") name
           (if detail (format " — %s" detail) ""))
  (unless ok (setq gh-test--failures (1+ gh-test--failures))))

(defun gh-test--pump (secs)
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end) (accept-process-output nil 0.05))))

(defvar gh-test--alerts nil)
(setq ghostherd-notify-function
      (lambda (pane status)
        (push (cons (alist-get 'pane_id pane) status) gh-test--alerts)))

;; Setup: scratch workspace, notify mode on.
(ghostherd-connect)
(defvar gh-wid (ghostherd-new-space "/tmp" "gh-notify-test"))
(defvar gh-pid (format "%s:p1" gh-wid))
(gh-test--pump 1.0)
(ghostherd-notify-mode 1)

;; 1. lighter initially reflects existing agents (idle/working counts
;; from your real agents are fine; just require a string).
(gh-test "lighter-is-string" (stringp ghostherd-notify--lighter))

;; Valid report states are idle/working/blocked/unknown ("done" is
;; derived by herdr from working->idle transitions).
(defun gh-report (state)
  (ghostherd-client-request
   "pane.report_agent"
   `((pane_id . ,gh-pid) (source . "test:ghostherd") (agent . "claude")
     (state . ,state))))

;; 2. working: no alert, lighter counts it
(gh-report "working")
(gh-test--pump 1.5)
(gh-test "working-no-alert" (null gh-test--alerts)
         (format "%S" gh-test--alerts))
(let ((counts (ghostherd-notify--counts)))
  (gh-test "working-counted" (> (nth 1 counts) 0)
           (format "blocked=%d working=%d done=%d"
                   (nth 0 counts) (nth 1 counts) (nth 2 counts))))
(gh-test "lighter-shows-working"
         (string-match-p "▸" ghostherd-notify--lighter)
         ghostherd-notify--lighter)

;; 3. blocked: alert fires once
(gh-report "blocked")
(gh-test--pump 1.5)
(gh-test "blocked-alert-fired"
         (equal gh-test--alerts (list (cons gh-pid "blocked")))
         (format "%S" gh-test--alerts))
(gh-test "lighter-shows-blocked"
         (string-match-p "⚑" ghostherd-notify--lighter)
         ghostherd-notify--lighter)

;; 4. repeated blocked report: no duplicate alert
(gh-report "blocked")
(gh-test--pump 1.5)
(gh-test "blocked-no-duplicate"
         (= (length gh-test--alerts) 1)
         (format "%S" gh-test--alerts))

;; 5. working -> idle: herdr surfaces this as "done" (finished,
;; unseen) — verified against 0.7.5.  Second alert expected.
(gh-report "working")
(gh-test--pump 1.0)
(gh-report "idle")
(gh-test--pump 1.5)
(gh-test "done-alert-fired"
         (equal (caar gh-test--alerts) gh-pid)
         (format "%S" gh-test--alerts))
(gh-test "done-alert-status"
         (equal (cdar gh-test--alerts) "done")
         (format "%S" (cdar gh-test--alerts)))

;; 7. teardown: closing the workspace clears pane from seen-table
(ghostherd-client-request "workspace.close" `((workspace_id . ,gh-wid)))
(gh-test--pump 1.5)
(gh-test "close-clears-seen"
         (null (gethash gh-pid ghostherd-notify--seen)))

;; 8. mode off: lighter removed from global-mode-string
(ghostherd-notify-mode -1)
(gh-test "mode-off-removes-lighter"
         (and (not (memq 'ghostherd-notify--lighter global-mode-string))
              (equal ghostherd-notify--lighter "")))

(ghostherd-disconnect)
(message "---")
(if (zerop gh-test--failures)
    (message "ALL PASS")
  (progn (message "%d FAILURES" gh-test--failures) (kill-emacs 1)))
