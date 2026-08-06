;;; sidebar-live-test.el --- live tests for ghostherd-sidebar -*- lexical-binding: t; -*-

;; Run: emacs --batch -L lisp -l test/sidebar-live-test.el
;; Rendering into a real buffer works fine in batch (unlike terminal
;; redisplay), so this covers render, text properties, folding, and
;; live updates.

(require 'ghostherd-sidebar)

(defvar gh-test--failures 0)
(defun gh-test (name ok &optional detail)
  (message "%s %s%s" (if ok "PASS" "FAIL") name
           (if detail (format " — %s" detail) ""))
  (unless ok (setq gh-test--failures (1+ gh-test--failures))))

(defun gh-test--wait-for (pred &optional secs)
  (let ((end (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun gh-sidebar-text ()
  (with-current-buffer ghostherd-sidebar-buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(ghostherd-connect)

;; Use get-buffer-create + render directly: display-buffer side windows
;; are unavailable in batch.
(let ((buf (get-buffer-create ghostherd-sidebar-buffer-name)))
  (with-current-buffer buf
    (ghostherd-sidebar-mode)
    (add-hook 'ghostherd-cache-update-hook #'ghostherd-sidebar--render)))
(ghostherd-sidebar--render)

;; 1. real spaces are listed
(gh-test "renders-existing-spaces"
         (string-match-p "normative" (gh-sidebar-text))
         (format "%d chars" (length (gh-sidebar-text))))

;; 2. create a scratch space; event-driven re-render picks it up
(defvar gh-wid (ghostherd-new-space "/tmp" "gh-sidebar-test"))
(gh-test "auto-rerender-on-create"
         (gh-test--wait-for
          (lambda () (string-match-p "gh-sidebar-test" (gh-sidebar-text)))))

;; 3. tab lines carry tab-id text property
(with-current-buffer ghostherd-sidebar-buffer-name
  (goto-char (point-min))
  (search-forward "gh-sidebar-test")
  (forward-line 1)
  (gh-test "tab-line-has-tab-property"
           (equal (get-text-property (point) 'ghostherd-workspace-id) gh-wid)
           (format "tab-id=%s"
                   (get-text-property (point) 'ghostherd-tab-id)))
  ;; 4. space line carries workspace property, no tab property
  (forward-line -1)
  (gh-test "space-line-props"
           (and (equal (get-text-property (point) 'ghostherd-workspace-id)
                       gh-wid)
                (null (get-text-property (point) 'ghostherd-tab-id)))))

;; 5. agent status shows up after a report (event-driven)
(let ((pid (format "%s:p1" gh-wid)))
  (ghostherd-client-request
   "pane.report_agent"
   `((pane_id . ,pid) (source . "test:sidebar") (agent . "claude")
     (state . "blocked")))
  (gh-test "blocked-glyph-appears"
           (gh-test--wait-for
            (lambda ()
              (with-current-buffer ghostherd-sidebar-buffer-name
                (save-excursion
                  (goto-char (point-min))
                  (and (search-forward "gh-sidebar-test" nil t)
                       (progn (forward-line 1)
                              (string-match-p
                               "⚑"
                               (buffer-substring-no-properties
                                (point) (line-end-position)))))))))
           (with-current-buffer ghostherd-sidebar-buffer-name
             (save-excursion
               (goto-char (point-min))
               (search-forward "gh-sidebar-test" nil t)
               (forward-line 1)
               (buffer-substring-no-properties (point) (line-end-position)))))
  ;; 6. agent name rendered on the tab line
  (gh-test "agent-name-rendered"
           (with-current-buffer ghostherd-sidebar-buffer-name
             (save-excursion
               (goto-char (point-min))
               (and (search-forward "gh-sidebar-test" nil t)
                    (progn (forward-line 1)
                           (string-match-p
                            "claude"
                            (buffer-substring-no-properties
                             (point) (line-end-position)))))))))

;; 7. folding hides tabs
(with-current-buffer ghostherd-sidebar-buffer-name
  (goto-char (point-min))
  (search-forward "gh-sidebar-test")
  (beginning-of-line)
  (ghostherd-sidebar-toggle-fold))
(gh-test "fold-hides-tabs"
         (with-current-buffer ghostherd-sidebar-buffer-name
           (save-excursion
             (goto-char (point-min))
             (search-forward "gh-sidebar-test")
             (forward-line 1)
             ;; next line is either another space (▶/▼ prefix) or eob
             (or (eobp)
                 (member (char-after) '(?▶ ?▼))))))

;; 8. unfold restores
(with-current-buffer ghostherd-sidebar-buffer-name
  (goto-char (point-min))
  (search-forward "gh-sidebar-test")
  (beginning-of-line)
  (ghostherd-sidebar-toggle-fold))
(gh-test "unfold-restores-tabs"
         (with-current-buffer ghostherd-sidebar-buffer-name
           (save-excursion
             (goto-char (point-min))
             (search-forward "gh-sidebar-test")
             (forward-line 1)
             (get-text-property (point) 'ghostherd-tab-id))))

;; 9. visit on a tab line targets the right tab (stub attach; batch
;; cannot spawn ghostel)
(defvar gh-visited nil)
(cl-letf (((symbol-function 'ghostherd--attach)
           (lambda (tab-id &optional _display) (setq gh-visited tab-id))))
  (with-current-buffer ghostherd-sidebar-buffer-name
    (goto-char (point-min))
    (search-forward "gh-sidebar-test")
    (forward-line 1)
    (ghostherd-sidebar-visit)))
(gh-test "visit-targets-tab"
         (equal gh-visited (format "%s:t1" gh-wid))
         gh-visited)

;; 10. closing the space removes it from the sidebar
(ghostherd-client-request "workspace.close" `((workspace_id . ,gh-wid)))
(gh-test "close-removes-from-sidebar"
         (gh-test--wait-for
          (lambda ()
            (not (string-match-p "gh-sidebar-test" (gh-sidebar-text))))))

(ghostherd-disconnect)
(message "---")
(if (zerop gh-test--failures)
    (message "ALL PASS")
  (progn (message "%d FAILURES" gh-test--failures) (kill-emacs 1)))
