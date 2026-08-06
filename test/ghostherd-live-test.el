;;; ghostherd-live-test.el --- live tests for ghostherd.el -*- lexical-binding: t; -*-

;; Run: emacs --batch -L lisp -l test/ghostherd-live-test.el
;; Requires a running herdr server.  Creates and removes a scratch
;; workspace labelled gh-core-test.  Does not test ghostel attach
;; rendering (batch limitation, see DESIGN.md).

(require 'ghostherd)

(defvar gh-test--failures 0)
(defun gh-test (name ok &optional detail)
  (message "%s %s%s" (if ok "PASS" "FAIL") name
           (if detail (format " — %s" detail) ""))
  (unless ok (setq gh-test--failures (1+ gh-test--failures))))

(defun gh-test--pump (secs)
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end) (accept-process-output nil 0.05))))

(defun gh-test--wait-for (pred &optional secs)
  "Pump until PRED returns non-nil or SECS (default 15) elapse.
Returns PRED's final value.  Generous default because herdr
replays a full (uptime-proportional) backlog on every reconnect."
  (let ((end (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.05))
    (funcall pred)))

;; 1. connect: subscribes and bootstraps cache
(ghostherd-connect)
(gh-test "connect-populates-cache"
         (> (hash-table-count ghostherd--workspaces) 0)
         (format "%d spaces, %d tabs, %d panes"
                 (hash-table-count ghostherd--workspaces)
                 (hash-table-count ghostherd--tabs)
                 (hash-table-count ghostherd--panes)))

;; 2. accessors agree with herdr's own ordering
(let ((spaces (ghostherd-spaces)))
  (gh-test "spaces-ordered"
           (equal (mapcar (lambda (w) (alist-get 'number w)) spaces)
                  (sort (mapcar (lambda (w) (alist-get 'number w)) spaces) #'<))))

;; 3. new-space creates workspace, caches it, sets current
(let ((wid (ghostherd-new-space "/tmp" "gh-core-test")))
  (gh-test "new-space-returns-id" (stringp wid) wid)
  (gh-test "new-space-cached" (gethash wid ghostherd--workspaces))
  (gh-test "new-space-sets-current"
           (equal (ghostherd-current-space) wid))

  ;; 4. its root tab and pane are cached
  (let ((tabs (ghostherd-tabs wid)))
    (gh-test "new-space-has-tab" (= (length tabs) 1))
    (let* ((tab-id (alist-get 'tab_id (car tabs)))
           (pane (ghostherd-tab-pane tab-id)))
      (gh-test "tab-pane-lookup" (and pane (alist-get 'terminal_id pane))
               (alist-get 'terminal_id pane))

      ;; 5. new-tab
      (let ((tab2 (ghostherd-new-tab "second")))
        (gh-test "new-tab-returns-id" (stringp tab2) tab2)
        (gh-test--pump 1.0)
        (gh-test "new-tab-in-cache-with-pane"
                 (and (gethash tab2 ghostherd--tabs)
                      (ghostherd-tab-pane tab2)))

        ;; 6. tabs-around cycling
        (let ((around (ghostherd--tabs-around tab-id)))
          (gh-test "tabs-around-cycles"
                   (and (equal (nth 1 around) tab-id)
                        (equal (nth 2 around) tab2)
                        (equal (nth 0 around) tab2))
                   (format "%S" around)))

        ;; 7. rename tab; event should update cache
        (ghostherd-rename-tab tab2 "renamed-tab")
        (gh-test "rename-tab-event-updates-cache"
                 (gh-test--wait-for
                  (lambda ()
                    (equal (alist-get 'label (gethash tab2 ghostherd--tabs))
                           "renamed-tab")))
                 (alist-get 'label (gethash tab2 ghostherd--tabs)))

        ;; 8. rename space; event should update cache
        (ghostherd-rename-space wid "gh-core-renamed")
        (gh-test "rename-space-event-updates-cache"
                 (gh-test--wait-for
                  (lambda ()
                    (equal (alist-get 'label
                                      (gethash wid ghostherd--workspaces))
                           "gh-core-renamed"))))

        ;; 9. attach buffer name derives from labels
        (gh-test "attach-buffer-name"
                 (equal (ghostherd--attach-buffer-name wid tab2)
                        "*herd:gh-core-renamed/renamed-tab*")
                 (ghostherd--attach-buffer-name wid tab2))

        ;; 10. tab.close via API; event removes tab and pane from cache
        (ghostherd-client-request "tab.close" `((tab_id . ,tab2)))
        (gh-test "tab-close-event-evicts"
                 (gh-test--wait-for
                  (lambda ()
                    (and (null (gethash tab2 ghostherd--tabs))
                         (null (ghostherd-tab-pane tab2)))))))))

  ;; 11. blocked-panes: no blocked agents in scratch space; function works
  (gh-test "blocked-panes-listp" (listp (ghostherd-blocked-panes))
           (format "%d blocked now" (length (ghostherd-blocked-panes))))

  ;; 12. workspace close evicts everything for that space
  (ghostherd-client-request "workspace.close" `((workspace_id . ,wid)))
  (gh-test "workspace-close-evicts-space"
           (gh-test--wait-for
            (lambda () (null (gethash wid ghostherd--workspaces)))))
  (gh-test "workspace-close-evicts-tabs"
           (gh-test--wait-for
            (lambda () (null (ghostherd-tabs wid)))))
  ;; current-space falls back to a live space
  (gh-test "current-space-fallback"
           (and (ghostherd-current-space)
                (gethash (ghostherd-current-space) ghostherd--workspaces))
           (ghostherd-current-space)))

(ghostherd-disconnect)
(gh-test "disconnect" (null ghostherd--connected))

(message "---")
(if (zerop gh-test--failures)
    (message "ALL PASS")
  (progn (message "%d FAILURES" gh-test--failures) (kill-emacs 1)))
