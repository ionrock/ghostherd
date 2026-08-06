;;; ghostherd-notify.el --- agent state notifications for ghostherd -*- lexical-binding: t; -*-

;; Author: ghostherd contributors
;; Keywords: terminals, processes

;;; Commentary:

;; Mode-line lighter and transition alerts driven by the ghostherd
;; cache (which is itself driven by herdr's event stream).
;;
;; Per DESIGN.md:
;; - lighter in `global-mode-string': blocked and working counts,
;;   clickable, hidden when both are zero.
;; - alerts on transitions to `blocked' and `done' through
;;   `ghostherd-notify-function'.
;; - dedupe on `state_change_seq'; suppression when the pane's attach
;;   buffer is visible and focused.

;;; Code:

(require 'ghostherd)

(defcustom ghostherd-notify-function #'ghostherd-notify-message
  "Function called with (PANE STATUS) when an agent needs attention.
PANE is the herdr pane record alist; STATUS is \"blocked\" or
\"done\".  Replace to integrate alert.el, desktop notifications,
etc."
  :type 'function
  :group 'ghostherd)

(defcustom ghostherd-notify-statuses '("blocked" "done")
  "Agent statuses that trigger `ghostherd-notify-function'."
  :type '(repeat string)
  :group 'ghostherd)

(defface ghostherd-blocked '((t :inherit error :weight bold))
  "Face for blocked agents."
  :group 'ghostherd)
(defface ghostherd-working '((t :inherit success))
  "Face for working agents."
  :group 'ghostherd)
(defface ghostherd-done '((t :inherit warning))
  "Face for done (unseen) agents."
  :group 'ghostherd)
(defface ghostherd-idle '((t :inherit shadow))
  "Face for idle agents."
  :group 'ghostherd)

(defun ghostherd-notify--face (status)
  "Face for agent STATUS string."
  (pcase status
    ("blocked" 'ghostherd-blocked)
    ("working" 'ghostherd-working)
    ("done" 'ghostherd-done)
    (_ 'ghostherd-idle)))

;;;; Default notifier

(defun ghostherd-notify--pane-desc (pane)
  "Short human description of PANE."
  (let* ((wid (alist-get 'workspace_id pane))
         (w (gethash wid ghostherd--workspaces)))
    (format "%s/%s"
            (or (alist-get 'label w) wid)
            (or (alist-get 'agent pane)
                (alist-get 'pane_id pane)))))

(defun ghostherd-notify-message (pane status)
  "Default notifier: `message' with a status-faced tag."
  (message "%s %s %s"
           (propertize (format "[%s]" status)
                       'face (ghostherd-notify--face status))
           (ghostherd-notify--pane-desc pane)
           (if (equal status "blocked") "needs input" "finished")))

;;;; Transition tracking

(defvar ghostherd-notify--seen (make-hash-table :test #'equal)
  "pane_id -> last (STATUS . STATE-CHANGE-SEQ) we notified or observed.")

(defun ghostherd-notify--pane-visible-p (pane-id)
  "Non-nil when PANE-ID's attach buffer is shown in the selected window."
  (let ((buf (window-buffer (selected-window))))
    (and buf
         (equal (buffer-local-value 'ghostherd-pane-id buf) pane-id))))

(defun ghostherd-notify--on-event (name data)
  "Watch agent status events for notify-worthy transitions.
Agent status arrives on per-pane `pane.agent_status_changed'
events (flat payload: pane_id, agent, agent_status), which
ghostherd.el subscribes for every known pane."
  (when (equal name "pane.agent_status_changed")
    (when-let* ((pane-id (alist-get 'pane_id data))
                (status (alist-get 'agent_status data)))
      (let* ((prev (gethash pane-id ghostherd-notify--seen))
             (prev-status (car prev)))
        (unless (and prev (equal status prev-status))
          (puthash pane-id (cons status nil) ghostherd-notify--seen)
          (when (and prev  ; no alerts for first sight (snapshot/backlog)
                     (member status ghostherd-notify-statuses)
                     (not (ghostherd-notify--pane-visible-p pane-id)))
            (let ((pane (or (gethash pane-id ghostherd--panes) data)))
              (funcall ghostherd-notify-function pane status)))))))
  (when (member name '("pane_closed" "pane_exited"))
    (when-let* ((pane-id (alist-get 'pane_id data)))
      (remhash pane-id ghostherd-notify--seen)))
  ;; Workspace close does not emit per-pane close events; prune all
  ;; seen entries for that workspace (pane ids are prefixed "wID:").
  (when (equal name "workspace_closed")
    (when-let* ((wid (alist-get 'workspace_id data)))
      (let ((prefix (concat wid ":")))
        (maphash (lambda (pane-id _)
                   (when (string-prefix-p prefix pane-id)
                     (remhash pane-id ghostherd-notify--seen)))
                 ghostherd-notify--seen)))))

;;;; Mode-line lighter

(defvar ghostherd-notify--lighter "")

(defun ghostherd-notify--counts ()
  "Return (BLOCKED WORKING DONE) counts from the pane cache."
  (let ((blocked 0) (working 0) (done 0))
    (maphash (lambda (_ pane)
               (pcase (alist-get 'agent_status pane)
                 ("blocked" (cl-incf blocked))
                 ("working" (cl-incf working))
                 ("done" (cl-incf done))))
             ghostherd--panes)
    (list blocked working done)))

(defvar ghostherd-notify-lighter-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'ghostherd-sidebar-toggle)
    map))

(declare-function ghostherd-sidebar-toggle "ghostherd-sidebar")

(defun ghostherd-notify--update-lighter ()
  "Recompute the mode-line lighter from the cache."
  (pcase-let ((`(,blocked ,working ,done) (ghostherd-notify--counts)))
    (setq ghostherd-notify--lighter
          (if (and (zerop blocked) (zerop working) (zerop done))
              ""
            (concat
             " "
             (propertize
              (string-join
               (delq nil
                     (list
                      (when (> blocked 0)
                        (propertize (format "⚑%d" blocked)
                                    'face 'ghostherd-blocked))
                      (when (> working 0)
                        (propertize (format "▸%d" working)
                                    'face 'ghostherd-working))
                      (when (> done 0)
                        (propertize (format "✓%d" done)
                                    'face 'ghostherd-done))))
               " ")
              'help-echo "ghostherd agents: mouse-1 opens sidebar"
              'local-map ghostherd-notify-lighter-map
              'mouse-face 'mode-line-highlight))))
    (force-mode-line-update t)))

;;;; Mode

;;;###autoload
(define-minor-mode ghostherd-notify-mode
  "Global agent-state notifications and mode-line lighter."
  :global t
  :group 'ghostherd
  (if ghostherd-notify-mode
      (progn
        (add-hook 'ghostherd-client-event-functions
                  #'ghostherd-notify--on-event)
        (add-hook 'ghostherd-cache-update-hook
                  #'ghostherd-notify--update-lighter)
        (unless (memq 'ghostherd-notify--lighter global-mode-string)
          (setq global-mode-string
                (append (or global-mode-string '(""))
                        '(ghostherd-notify--lighter))))
        (ghostherd--ensure)
        ;; Seed seen-state from the cache so the replayed backlog and
        ;; snapshot contents never fire alerts.
        (maphash (lambda (pane-id pane)
                   (puthash pane-id
                            (cons (alist-get 'agent_status pane)
                                  (alist-get 'state_change_seq pane))
                            ghostherd-notify--seen))
                 ghostherd--panes)
        (ghostherd-notify--update-lighter))
    (remove-hook 'ghostherd-client-event-functions
                 #'ghostherd-notify--on-event)
    (remove-hook 'ghostherd-cache-update-hook
                 #'ghostherd-notify--update-lighter)
    (setq global-mode-string
          (delq 'ghostherd-notify--lighter global-mode-string))
    (clrhash ghostherd-notify--seen)
    (setq ghostherd-notify--lighter "")))

(provide 'ghostherd-notify)
;;; ghostherd-notify.el ends here
