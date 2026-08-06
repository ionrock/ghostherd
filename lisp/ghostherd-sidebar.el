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

(defvar ghostherd-sidebar--folded (make-hash-table :test #'equal)
  "workspace_id -> t when the space's tabs are hidden.")

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
  "Resync from herdr and re-render."
  (interactive)
  (ghostherd-resync)
  (ghostherd-sidebar--render))

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
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    map)
  "Keymap for `ghostherd-sidebar-mode'.")

(define-derived-mode ghostherd-sidebar-mode special-mode "ghostherd"
  "Sidebar listing herdr spaces, tabs, and agent state."
  (setq truncate-lines t
        cursor-in-non-selected-windows nil))

;;;; Entry points

;;;###autoload
(defun ghostherd-sidebar-open ()
  "Show the sidebar, connecting to herdr if needed."
  (interactive)
  (ghostherd--ensure)
  (let ((buf (get-buffer-create ghostherd-sidebar-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ghostherd-sidebar-mode)
        (ghostherd-sidebar-mode)
        (add-hook 'ghostherd-cache-update-hook
                  #'ghostherd-sidebar--render)))
    (ghostherd-sidebar--render)
    (select-window
     (display-buffer-in-side-window
      buf `((side . ,ghostherd-sidebar-side)
            (window-width . ,ghostherd-sidebar-width)
            (dedicated . t))))))

;;;###autoload
(defun ghostherd-sidebar-toggle ()
  "Toggle the sidebar window."
  (interactive)
  (let* ((buf (get-buffer ghostherd-sidebar-buffer-name))
         (win (and buf (get-buffer-window buf t))))
    (if win
        (delete-window win)
      (ghostherd-sidebar-open))))

;; `w' in the command map, promised by DESIGN.md.
(define-key ghostherd-command-map (kbd "w") #'ghostherd-sidebar-toggle)

(provide 'ghostherd-sidebar)
;;; ghostherd-sidebar.el ends here
