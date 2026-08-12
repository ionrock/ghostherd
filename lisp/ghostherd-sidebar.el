;;; ghostherd-sidebar.el --- space/tab/agent sidebar for ghostherd -*- lexical-binding: t; -*-

;; Author: ghostherd contributors
;; Keywords: terminals, processes

;;; Commentary:

;; A sidebar buffer showing spaces -> tabs with live agent state,
;; rebuilt from the ghostherd cache on every cache update.
;;
;; Keys (single keys, magit-style; see DESIGN.md):
;;   RET   visit thing at point (attach tab / first tab of space)
;;   TAB   fold/unfold space at point
;;   c     new tab in space at point
;;   C     new space
;;   k     close tab at point (confirms; kills the herdr pane)
;;   r     rename thing at point
;;   b     jump to next blocked agent
;;   g     resync from herdr
;;   l     lay out selected terminals beside the sidebar
;;   L     restore the previous window configuration
;;   n/p   next/previous line
;;   q     quit window

;;; Code:

(require 'ghostherd)
(require 'ghostherd-notify)                   ; faces

(defcustom ghostherd-sidebar-buffer-name "*ghostherd*"
  "Name of the sidebar buffer."
  :type 'string
  :group 'ghostherd)

(defcustom ghostherd-sidebar-width 34
  "Width of the sidebar side window."
  :type 'integer
  :group 'ghostherd)

(defcustom ghostherd-sidebar-side 'left
  "Which side the sidebar window uses."
  :type '(choice (const left) (const right))
  :group 'ghostherd)

(defcustom ghostherd-sidebar-refresh-interval 2.0
  "Seconds between authoritative sidebar refreshes.
Nil disables periodic refresh.  Event-driven updates remain active."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'ghostherd)

(defvar ghostherd-sidebar--folded (make-hash-table :test #'equal)
  "workspace_id -> t when the space's tabs are hidden.")

(defvar ghostherd-sidebar--refresh-timer nil
  "Timer used to reconcile the visible sidebar with herdr.")

(defvar ghostherd-sidebar--refreshing nil
  "Non-nil while a periodic sidebar refresh is in progress.")

(defvar ghostherd-sidebar--saved-configurations (make-hash-table :test #'eq)
  "Frame to window configuration saved before a ghostherd layout.")

(defun ghostherd-sidebar--forget-frame (frame)
  "Forget any saved layout for deleted FRAME."
  (remhash frame ghostherd-sidebar--saved-configurations))

(add-hook 'delete-frame-functions #'ghostherd-sidebar--forget-frame)

;;;; Status glyphs

(defun ghostherd-sidebar--status-glyph (status)
  "Return a propertized glyph for agent STATUS."
  (pcase status
    ("blocked" (propertize "⚑" 'face 'ghostherd-blocked))
    ("working" (propertize "▸" 'face 'ghostherd-working))
    ("done"    (propertize "✓" 'face 'ghostherd-done))
    ("idle"    (propertize "·" 'face 'ghostherd-idle))
    (_         (propertize " " 'face 'ghostherd-idle))))

;;;; Rendering

(defun ghostherd-sidebar--insert-space (w)
  "Insert workspace record W and its tabs."
  (let* ((wid (alist-get 'workspace_id w))
         (folded (gethash wid ghostherd-sidebar--folded))
         (status (alist-get 'agent_status w))
         (start (point)))
    (insert (format "%s %s %s\n"
                    (if folded "▶" "▼")
                    (ghostherd-sidebar--status-glyph status)
                    (propertize (format "%s" (alist-get 'label w))
                                'face 'bold)))
    (add-text-properties start (point)
                         `(ghostherd-workspace-id ,wid))
    (unless folded
      (dolist (tab (ghostherd-tabs wid))
        (let* ((tab-id (alist-get 'tab_id tab))
               (pane (ghostherd-tab-pane tab-id))
               (agent (and pane (alist-get 'agent pane)))
               (pane-status (and pane (alist-get 'agent_status pane)))
               (tstart (point)))
          (insert (format "   %s %s%s\n"
                          (ghostherd-sidebar--status-glyph pane-status)
                          (alist-get 'label tab)
                          (if agent
                              (propertize (format "  %s" agent)
                                          'face 'ghostherd-idle)
                            "")))
          (add-text-properties tstart (point)
                               `(ghostherd-workspace-id ,wid
                                 ghostherd-tab-id ,tab-id)))))))

(defun ghostherd-sidebar--render ()
  "Rebuild the sidebar buffer from the cache."
  (when-let* ((buf (get-buffer ghostherd-sidebar-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (if (null (ghostherd-spaces))
            (insert (propertize "no spaces\n" 'face 'ghostherd-idle))
          (dolist (w (ghostherd-spaces))
            (ghostherd-sidebar--insert-space w)))
        (goto-char (point-min))
        (forward-line (1- line))))))

;;;; Point context

(defun ghostherd-sidebar--tab-at-point ()
  (get-text-property (point) 'ghostherd-tab-id))

(defun ghostherd-sidebar--space-at-point ()
  (get-text-property (point) 'ghostherd-workspace-id))

;;;; Refresh lifecycle

(defun ghostherd-sidebar--visible-p ()
  "Return non-nil when the sidebar is visible on any frame."
  (when-let* ((buf (get-buffer ghostherd-sidebar-buffer-name)))
    (get-buffer-window buf t)))

(defun ghostherd-sidebar--stop-refresh-timer ()
  "Cancel the periodic sidebar refresh timer."
  (when (timerp ghostherd-sidebar--refresh-timer)
    (cancel-timer ghostherd-sidebar--refresh-timer))
  (setq ghostherd-sidebar--refresh-timer nil
        ghostherd-sidebar--refreshing nil))

(defun ghostherd-sidebar--refresh-tick ()
  "Refresh sidebar state, or stop polling when it is no longer visible."
  (if (not (ghostherd-sidebar--visible-p))
      (ghostherd-sidebar--stop-refresh-timer)
    (when (and ghostherd--connected
               (not ghostherd-sidebar--refreshing))
      (let ((ghostherd-sidebar--refreshing t))
        (condition-case err
            (ghostherd-resync)
          (error
           (message "ghostherd sidebar refresh failed: %s"
                    (error-message-string err))))))))

(defun ghostherd-sidebar--start-refresh-timer ()
  "Start periodic refresh when configured, without duplicating timers."
  (when (and ghostherd-sidebar-refresh-interval
             (> ghostherd-sidebar-refresh-interval 0)
             (not (timerp ghostherd-sidebar--refresh-timer)))
    (setq ghostherd-sidebar--refresh-timer
          (run-at-time ghostherd-sidebar-refresh-interval
                       ghostherd-sidebar-refresh-interval
                       #'ghostherd-sidebar--refresh-tick))))

;;;; Layout

(defun ghostherd-sidebar--tab-candidates ()
  "Return completion candidates mapping display names to tab ids."
  (cl-loop for space in (ghostherd-spaces)
           for wid = (alist-get 'workspace_id space)
           append
           (cl-loop for tab in (ghostherd-tabs wid)
                    for tab-id = (alist-get 'tab_id tab)
                    for pane = (ghostherd-tab-pane tab-id)
                    for status = (or (and pane (alist-get 'agent_status pane))
                                     "unknown")
                    collect
                    (cons (format "%s / %s  [%s]  <%s>"
                                  (alist-get 'label space)
                                  (alist-get 'label tab)
                                  status tab-id)
                          tab-id))))

(defun ghostherd-sidebar--read-layout-tabs ()
  "Read one or more terminal tabs for a sidebar layout."
  (let* ((candidates (ghostherd-sidebar--tab-candidates))
         (at-point (and (derived-mode-p 'ghostherd-sidebar-mode)
                        (ghostherd-sidebar--tab-at-point)))
         (default (car (rassoc at-point candidates)))
         (chosen (completing-read-multiple
                  "Terminals (comma-separated): " candidates nil t
                  nil nil default)))
    (delete-dups (delq nil (mapcar (lambda (name) (cdr (assoc name candidates)))
                                   chosen)))))

(defun ghostherd-sidebar--prepare-buffer ()
  "Create, initialize, and render the sidebar buffer."
  (let ((buf (get-buffer-create ghostherd-sidebar-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ghostherd-sidebar-mode)
        (ghostherd-sidebar-mode)
        (add-hook 'ghostherd-cache-update-hook #'ghostherd-sidebar--render)))
    (ghostherd-sidebar--render)
    buf))

(defun ghostherd-sidebar--display-window ()
  "Display and return the sidebar side window without selecting it."
  (display-buffer-in-side-window
   (ghostherd-sidebar--prepare-buffer)
   `((side . ,ghostherd-sidebar-side)
     (window-width . ,ghostherd-sidebar-width)
     (dedicated . t))))

(defun ghostherd-sidebar--main-leaf-window (frame)
  "Return a live non-side window in FRAME's main window area."
  (or (cl-find-if (lambda (window)
                    (not (window-parameter window 'window-side)))
                  (window-list frame 'nomini))
      (user-error "Frame has no main window")))

(defun ghostherd-sidebar--install-terminal-windows (main buffers)
  "Split MAIN into a balanced vertical stack displaying BUFFERS."
  (let ((windows (list main)))
    (dotimes (_ (1- (length buffers)))
      (let ((new (split-window (car (last windows)) nil 'below)))
        (unless new
          (user-error "Frame is too small for %d terminal windows"
                      (length buffers)))
        (setq windows (append windows (list new)))))
    (cl-mapc #'set-window-buffer windows buffers)
    ;; Balance only the main subtree.  Balancing the frame root also
    ;; resizes side windows, which can make the sidebar consume half the frame.
    (balance-windows (window-main-window (window-frame main)))
    windows))

;;;###autoload
(defun ghostherd-sidebar-layout (tab-ids)
  "Show the sidebar on the left and selected TAB-IDS on the right."
  (interactive
   (progn
     (ghostherd--ensure)
     (list (ghostherd-sidebar--read-layout-tabs))))
  (unless tab-ids
    (user-error "No terminals selected"))
  (ghostherd--ensure)
  (let* ((frame (selected-frame))
         (old-config (current-window-configuration frame))
         (already-saved (gethash frame ghostherd-sidebar--saved-configurations))
         (buffers (mapcar (lambda (tab-id) (ghostherd--attach tab-id nil))
                          tab-ids)))
    (condition-case err
        (progn
          (unless already-saved
            (puthash frame old-config ghostherd-sidebar--saved-configurations))
          (delete-other-windows (ghostherd-sidebar--main-leaf-window frame))
          (ghostherd-sidebar--display-window)
          (let ((windows (ghostherd-sidebar--install-terminal-windows
                          (ghostherd-sidebar--main-leaf-window frame) buffers)))
            (ghostherd-sidebar--start-refresh-timer)
            (select-window (car windows))))
      (error
       (set-window-configuration old-config)
       (unless already-saved
         (remhash frame ghostherd-sidebar--saved-configurations))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun ghostherd-sidebar-restore-layout ()
  "Restore the selected frame's configuration from before its layout."
  (interactive)
  (let* ((frame (selected-frame))
         (configuration (gethash frame ghostherd-sidebar--saved-configurations)))
    (unless configuration
      (user-error "No saved ghostherd layout for this frame"))
    (remhash frame ghostherd-sidebar--saved-configurations)
    (set-window-configuration configuration)
    (unless (ghostherd-sidebar--visible-p)
      (ghostherd-sidebar--stop-refresh-timer))))

;;;; Commands

(defun ghostherd-sidebar-visit ()
  "Attach to the tab at point, or the space's active tab."
  (interactive)
  (let ((tab-id (ghostherd-sidebar--tab-at-point))
        (wid (ghostherd-sidebar--space-at-point)))
    (cond
     (tab-id (ghostherd--attach tab-id t))
     (wid (ghostherd-switch-space wid))
     (t (user-error "Nothing at point")))))

(defun ghostherd-sidebar-toggle-fold ()
  "Fold or unfold the space at point."
  (interactive)
  (let ((wid (or (ghostherd-sidebar--space-at-point)
                 (user-error "No space at point"))))
    (puthash wid (not (gethash wid ghostherd-sidebar--folded))
             ghostherd-sidebar--folded)
    (ghostherd-sidebar--render)))

(defun ghostherd-sidebar-new-tab ()
  "Create a tab in the space at point."
  (interactive)
  (let ((wid (or (ghostherd-sidebar--space-at-point)
                 (user-error "No space at point"))))
    (setq ghostherd--current-space wid)
    (ghostherd--attach (ghostherd-new-tab) t)))

(defun ghostherd-sidebar-new-space ()
  "Create a new space (prompts for directory)."
  (interactive)
  (call-interactively #'ghostherd-new-space))

(defun ghostherd-sidebar-close ()
  "Close the tab at point (kills the herdr pane; confirms)."
  (interactive)
  (let ((tab-id (or (ghostherd-sidebar--tab-at-point)
                    (user-error "No tab at point"))))
    (ghostherd-close-tab tab-id)))

(defun ghostherd-sidebar-rename ()
  "Rename the tab at point, or the space when on a space line."
  (interactive)
  (let ((tab-id (ghostherd-sidebar--tab-at-point))
        (wid (ghostherd-sidebar--space-at-point)))
    (cond
     (tab-id (ghostherd-rename-tab tab-id (read-string "New tab name: ")))
     (wid (ghostherd-rename-space wid (read-string "New space name: ")))
     (t (user-error "Nothing at point")))))

(defun ghostherd-sidebar-refresh ()
  "Resync from herdr; the cache update hook re-renders the sidebar."
  (interactive)
  (ghostherd-resync))

(defvar ghostherd-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ghostherd-sidebar-visit)
    (define-key map (kbd "TAB") #'ghostherd-sidebar-toggle-fold)
    (define-key map (kbd "c") #'ghostherd-sidebar-new-tab)
    (define-key map (kbd "C") #'ghostherd-sidebar-new-space)
    (define-key map (kbd "k") #'ghostherd-sidebar-close)
    (define-key map (kbd "r") #'ghostherd-sidebar-rename)
    (define-key map (kbd "b") #'ghostherd-next-blocked)
    (define-key map (kbd "g") #'ghostherd-sidebar-refresh)
    (define-key map (kbd "l") #'ghostherd-sidebar-layout)
    (define-key map (kbd "L") #'ghostherd-sidebar-restore-layout)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    map)
  "Keymap for `ghostherd-sidebar-mode'.")

(define-derived-mode ghostherd-sidebar-mode special-mode "ghostherd"
  "Sidebar listing herdr spaces, tabs, and agent state."
  (setq truncate-lines t
        cursor-in-non-selected-windows nil)
  (add-hook 'kill-buffer-hook #'ghostherd-sidebar--stop-refresh-timer nil t))

;;;; Entry points

;;;###autoload
(defun ghostherd-sidebar-open ()
  "Show the sidebar, connecting to herdr if needed."
  (interactive)
  (ghostherd--ensure)
  (let ((window (ghostherd-sidebar--display-window)))
    (ghostherd-sidebar--start-refresh-timer)
    (select-window window)))

;;;###autoload
(defun ghostherd-sidebar-toggle ()
  "Toggle the sidebar window."
  (interactive)
  (let* ((buf (get-buffer ghostherd-sidebar-buffer-name))
         (win (and buf (get-buffer-window buf t))))
    (if win
        (progn
          (delete-window win)
          (unless (ghostherd-sidebar--visible-p)
            (ghostherd-sidebar--stop-refresh-timer)))
      (ghostherd-sidebar-open))))

;; `w' in the command map, promised by DESIGN.md.
(define-key ghostherd-command-map (kbd "w") #'ghostherd-sidebar-toggle)

(provide 'ghostherd-sidebar)
;;; ghostherd-sidebar.el ends here
