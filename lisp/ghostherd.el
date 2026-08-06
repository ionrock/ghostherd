;;; ghostherd.el --- herdr spaces and tabs over ghostel terminals -*- lexical-binding: t; -*-

;; Author: ghostherd contributors
;; Keywords: terminals, processes, tools
;; Package-Requires: ((emacs "28.1") (ghostel "0.40"))

;;; Commentary:

;; Manage herdr workspaces ("spaces") and tabs from Emacs, rendering
;; each tab's terminal in a ghostel buffer attached to the herdr pane
;; via `herdr terminal attach <terminal_id>'.
;;
;; herdr is the source of truth: it owns the PTYs, does agent
;; detection, and survives Emacs restarts.  ghostherd keeps a local
;; cache bootstrapped from `session.snapshot' and updated from the
;; event stream.
;;
;; Design decisions (see DESIGN.md):
;; - herdr is required; no standalone mode.
;; - 1 herdr tab = 1 pane.  Emacs windows do the splitting.
;; - Killing an attach buffer detaches; it never closes the pane.
;;   Only `ghostherd-close-tab' closes panes.

;;; Code:

(require 'ghostherd-client)
(require 'cl-lib)
(require 'subr-x)
(require 'project)

(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-send-string "ghostel" (string &optional paste-p))
(defvar ghostel--process)

(defcustom ghostherd-attach-buffer-name-format "*herd:%s/%s*"
  "Format for attach buffer names: space label, tab label."
  :type 'string
  :group 'ghostherd)

;;;; Cache

;; Each entry is the raw record alist from herdr, keyed by id.
(defvar ghostherd--workspaces (make-hash-table :test #'equal))
(defvar ghostherd--tabs (make-hash-table :test #'equal))
(defvar ghostherd--panes (make-hash-table :test #'equal))
(defvar ghostherd--connected nil)

(defvar ghostherd--dead-panes (make-hash-table :test #'equal)
  "Pane ids herdr has rejected subscriptions for.
Populated when `events.subscribe' fails with pane_not_found.
Never subscribe these again.")

(defvar ghostherd--verified-panes (make-hash-table :test #'equal)
  "Pane ids confirmed live by a snapshot or a command response.
herdr's backlog replay can resurrect panes that died before this
session started (we hold no tombstone for them), and subscribing
to a dead pane makes herdr reject the whole events.subscribe —
forcing a reconnect that can drop live events.  So the
subscription list only ever names verified panes; replayed
creates merely schedule a verifying resync.")

(defvar ghostherd--resync-timer nil)

(defun ghostherd--schedule-resync ()
  "Schedule a debounced snapshot resync."
  (unless ghostherd--resync-timer
    (setq ghostherd--resync-timer
          (run-at-time
           0.5 nil
           (lambda ()
             (setq ghostherd--resync-timer nil)
             (when ghostherd--connected
               (ghostherd--cache-reset (ghostherd-client-snapshot))))))))

(defvar ghostherd--closed-workspaces (make-hash-table :test #'equal)
  "Tombstones for closed workspace ids.
herdr replays an event backlog to every new subscriber; a replayed
`workspace_created' for an already-closed workspace would resurrect
it in the cache (its close event may fall outside the backlog
window).  A fresh snapshot clears tombstones for anything it lists,
which also copes with id reuse.")

(defvar ghostherd--closed-tabs (make-hash-table :test #'equal)
  "Tombstones for closed tab ids; same rationale as workspaces.")

(defvar ghostherd--closed-panes (make-hash-table :test #'equal)
  "Tombstones for closed pane ids; same rationale as workspaces.
Resurrected dead panes are worse than stale tabs: their agent
status subscriptions are rejected by herdr, forcing reconnect
churn that can drop live events.")

(defvar ghostherd-cache-update-hook nil
  "Normal hook run after any cache change.")

(defun ghostherd--cache-reset (snapshot)
  "Replace the cache from SNAPSHOT.
The snapshot is authoritative in both directions: everything it
lists is alive (clear tombstones), and everything we knew about
that it does NOT list is dead (add tombstones).  The second half
matters because a close event can be missed while the event
connection is mid-reconnect, and the next backlog replay would
otherwise resurrect the closed resource via its replayed create."
  (let ((live-w (make-hash-table :test #'equal))
        (live-t (make-hash-table :test #'equal))
        (live-p (make-hash-table :test #'equal)))
    (dolist (w (alist-get 'workspaces snapshot))
      (puthash (alist-get 'workspace_id w) w live-w))
    (dolist (tab (alist-get 'tabs snapshot))
      (puthash (alist-get 'tab_id tab) tab live-t))
    (dolist (p (alist-get 'panes snapshot))
      (puthash (alist-get 'pane_id p) p live-p))
    ;; Tombstone cached entries the snapshot no longer lists.
    (maphash (lambda (id _) (unless (gethash id live-w)
                              (puthash id t ghostherd--closed-workspaces)))
             ghostherd--workspaces)
    (maphash (lambda (id _) (unless (gethash id live-t)
                              (puthash id t ghostherd--closed-tabs)))
             ghostherd--tabs)
    (maphash (lambda (id _) (unless (gethash id live-p)
                              (puthash id t ghostherd--closed-panes)))
             ghostherd--panes)
    ;; Un-tombstone everything the snapshot lists; snapshot panes are
    ;; verified live.
    (maphash (lambda (id _) (remhash id ghostherd--closed-workspaces)) live-w)
    (maphash (lambda (id _) (remhash id ghostherd--closed-tabs)) live-t)
    (clrhash ghostherd--verified-panes)
    (maphash (lambda (id _)
               (remhash id ghostherd--closed-panes)
               (remhash id ghostherd--dead-panes)
               (puthash id t ghostherd--verified-panes))
             live-p)
    (setq ghostherd--workspaces live-w
          ghostherd--tabs live-t
          ghostherd--panes live-p))
  (ghostherd--sync-pane-subscriptions)
  (run-hooks 'ghostherd-cache-update-hook))

(defun ghostherd--apply-event (name data)
  "Update the cache from event NAME with DATA."
  ;; The stream is at-least-once and replayed creates can arrive AFTER
  ;; newer events (observed live: tab_created delivered after
  ;; tab_renamed for the same tab).  So *_created never overwrites an
  ;; existing cached record; updates always do.
  (pcase name
    ("workspace_created"
     (when-let* ((w (alist-get 'workspace data))
                 (id (alist-get 'workspace_id w)))
       (unless (or (gethash id ghostherd--workspaces)
                   (gethash id ghostherd--closed-workspaces))
         (puthash id w ghostherd--workspaces))))
    ((or "workspace_updated" "workspace_focused")
     (when-let* ((w (alist-get 'workspace data))
                 (id (alist-get 'workspace_id w)))
       ;; Replayed updates must not resurrect closed workspaces.
       (unless (gethash id ghostherd--closed-workspaces)
         (puthash id w ghostherd--workspaces))))
    ;; Renamed events are flat: {"workspace_id":..,"label":..} /
    ;; {"tab_id":..,"label":..} — patch the cached record.
    ("workspace_renamed"
     (when-let* ((id (alist-get 'workspace_id data))
                 (w (gethash id ghostherd--workspaces)))
       (setf (alist-get 'label w) (alist-get 'label data))
       (puthash id w ghostherd--workspaces)))
    ("tab_renamed"
     (when-let* ((id (alist-get 'tab_id data))
                 (tab (and (not (gethash id ghostherd--closed-tabs))
                           (gethash id ghostherd--tabs))))
       (setf (alist-get 'label tab) (alist-get 'label data))
       (puthash id tab ghostherd--tabs)))
    ("workspace_closed"
     (when-let* ((id (alist-get 'workspace_id data)))
       (puthash id t ghostherd--closed-workspaces)
       (remhash id ghostherd--workspaces)
       ;; Drop the workspace's tabs and panes too.
       (maphash (lambda (tid tab)
                  (when (equal (alist-get 'workspace_id tab) id)
                    (remhash tid ghostherd--tabs)))
                ghostherd--tabs)
       (maphash (lambda (pid pane)
                  (when (equal (alist-get 'workspace_id pane) id)
                    (remhash pid ghostherd--panes)))
                ghostherd--panes)))
    ("tab_created"
     (when-let* ((tab (alist-get 'tab data))
                 (id (alist-get 'tab_id tab)))
       ;; Ignore replayed creates for closed tabs and for workspaces
       ;; we do not know (backlog of already-closed workspaces).
       (when (and (not (gethash id ghostherd--tabs))
                  (not (gethash id ghostherd--closed-tabs))
                  (gethash (alist-get 'workspace_id tab)
                           ghostherd--workspaces))
         (puthash id tab ghostherd--tabs))))
    ((or "tab_focused" "tab_moved")
     (when-let* ((tab (alist-get 'tab data)))
       (unless (gethash (alist-get 'workspace_id tab)
                        ghostherd--closed-workspaces)
         (puthash (alist-get 'tab_id tab) tab ghostherd--tabs))))
    ("tab_closed"
     (when-let* ((id (alist-get 'tab_id data)))
       (puthash id t ghostherd--closed-tabs)
       (remhash id ghostherd--tabs)
       (maphash (lambda (pid pane)
                  (when (equal (alist-get 'tab_id pane) id)
                    (puthash pid t ghostherd--closed-panes)
                    (remhash pid ghostherd--panes)))
                ghostherd--panes)))
    ("pane_created"
     (when-let* ((pane (alist-get 'pane data))
                 (id (alist-get 'pane_id pane)))
       ;; Same stale-replay guard as tab_created.  An event-sourced
       ;; pane is NOT verified; schedule a resync so a snapshot can
       ;; confirm it before we subscribe to its agent status.
       (when (and (not (gethash id ghostherd--panes))
                  (not (gethash id ghostherd--closed-panes))
                  (gethash (alist-get 'workspace_id pane)
                           ghostherd--workspaces))
         (puthash id pane ghostherd--panes)
         (unless (gethash id ghostherd--verified-panes)
           (ghostherd--schedule-resync)))))
    ((or "pane_updated" "pane_focused" "pane_moved" "pane_agent_detected")
     (when-let* ((pane (alist-get 'pane data)))
       ;; Pane records carry `revision'; ignore stale replays and
       ;; panes of closed workspaces.
       (let* ((id (alist-get 'pane_id pane))
              (old (gethash id ghostherd--panes))
              (old-rev (and old (alist-get 'revision old)))
              (new-rev (alist-get 'revision pane)))
         (unless (or (and old-rev new-rev (< new-rev old-rev))
                     (gethash (alist-get 'workspace_id pane)
                              ghostherd--closed-workspaces))
           (puthash id pane ghostherd--panes)))))
    ((or "pane_closed" "pane_exited")
     (when-let* ((id (alist-get 'pane_id data)))
       (puthash id t ghostherd--closed-panes)
       (remhash id ghostherd--panes)))
    ;; Note the dotted name: agent status events keep their
    ;; subscription-style name, unlike lifecycle events.  Payload is
    ;; flat: {"pane_id":..,"agent":..,"agent_status":..}.
    ("pane.agent_status_changed"
     (when-let* ((id (alist-get 'pane_id data))
                 (pane (gethash id ghostherd--panes)))
       (setf (alist-get 'agent_status pane) (alist-get 'agent_status data))
       (when (alist-get 'agent data)
         (setf (alist-get 'agent pane) (alist-get 'agent data)))
       (puthash id pane ghostherd--panes))))
  (ghostherd--sync-pane-subscriptions)
  (run-hooks 'ghostherd-cache-update-hook))

;;;; Per-pane agent status subscriptions
;;
;; herdr only emits agent status transitions on per-pane
;; `pane.agent_status_changed' subscriptions, and one connection gets
;; exactly one events.subscribe request — so when the pane set
;; changes, reconnect with the updated subscription list.

(defvar ghostherd--subscribed-panes nil
  "Pane ids covered by the current event connection.")

(defun ghostherd--sync-pane-subscriptions ()
  "Reconnect the event stream when panes NEED subscriptions.
Reconnect only when a live pane is missing from the current
subscription set.  Removals never force a reconnect: herdr only
validates pane ids at subscribe time, and a subscription for a
since-closed pane is inert.  Each reconnect opens an event gap and
triggers a backlog replay, so reconnect as rarely as possible."
  (let ((pane-ids (sort (cl-remove-if-not
                         (lambda (id)
                           (and (gethash id ghostherd--verified-panes)
                                (not (gethash id ghostherd--dead-panes))))
                         (hash-table-keys ghostherd--panes))
                        #'string<)))
    (when (cl-set-difference pane-ids ghostherd--subscribed-panes
                             :test #'equal)
      (setq ghostherd--subscribed-panes pane-ids)
      (setq ghostherd-client-extra-subscriptions
            (mapcar (lambda (id)
                      `((type . "pane.agent_status_changed")
                        (pane_id . ,id)))
                    pane-ids))
      (when ghostherd--connected
        (ghostherd-client-events-reconnect)))))

;;;; Connection lifecycle

(defun ghostherd-connect ()
  "Connect to herdr: subscribe to events, then bootstrap the cache.
Order matters: subscribing first means no gap between snapshot and
stream; the replayed backlog is idempotent against the snapshot."
  (interactive)
  (unless ghostherd--connected
    (add-hook 'ghostherd-client-event-functions #'ghostherd--apply-event)
    (add-hook 'ghostherd-client-subscribe-error-functions
              #'ghostherd--on-subscribe-error)
    (ghostherd-client-events-connect))
  (ghostherd--cache-reset (ghostherd-client-snapshot))
  (setq ghostherd--connected t)
  (message "ghostherd: connected (%d spaces)"
           (hash-table-count ghostherd--workspaces)))

(defun ghostherd-disconnect ()
  "Disconnect from herdr and clear the cache."
  (interactive)
  (ghostherd-client-events-disconnect)
  (remove-hook 'ghostherd-client-event-functions #'ghostherd--apply-event)
  (remove-hook 'ghostherd-client-subscribe-error-functions
               #'ghostherd--on-subscribe-error)
  (setq ghostherd--connected nil))

(defun ghostherd--on-subscribe-error (err)
  "Recover from a rejected subscribe: refresh state and reconnect.
A per-pane subscription can name a pane herdr no longer knows
about (close raced the subscribe, or a stale backlog replay
resurrected it).  Tombstone the named pane so it is never
subscribed again, then resync from a fresh snapshot and reconnect
on a timer (not from the process filter)."
  (let ((msg (or (alist-get 'message err) "")))
    (when (string-match "pane \\([^ ]+\\) not found" msg)
      (let ((pane-id (match-string 1 msg)))
        (puthash pane-id t ghostherd--dead-panes)
        (remhash pane-id ghostherd--panes))))
  (run-at-time
   0.1 nil
   (lambda ()
     (when ghostherd--connected
       (setq ghostherd--subscribed-panes nil)
       (ghostherd--cache-reset (ghostherd-client-snapshot))
       (ghostherd-client-events-connect)))))

(defun ghostherd-resync ()
  "Force a fresh snapshot into the cache."
  (interactive)
  (ghostherd--ensure)
  (ghostherd--cache-reset (ghostherd-client-snapshot)))

(defun ghostherd--ensure ()
  "Ensure we are connected, connecting on first use."
  (unless (and ghostherd--connected
               ghostherd-client--events-proc
               (process-live-p ghostherd-client--events-proc))
    (ghostherd-connect)))

;;;; Cache accessors

(defun ghostherd-spaces ()
  "Return workspace records, ordered by herdr's number."
  (let (out)
    (maphash (lambda (_ w) (push w out)) ghostherd--workspaces)
    (sort out (lambda (a b) (< (or (alist-get 'number a) 0)
                               (or (alist-get 'number b) 0))))))

(defun ghostherd-tabs (workspace-id)
  "Return tab records for WORKSPACE-ID, ordered by number."
  (let (out)
    (maphash (lambda (_ tab)
               (when (equal (alist-get 'workspace_id tab) workspace-id)
                 (push tab out)))
             ghostherd--tabs)
    (sort out (lambda (a b) (< (or (alist-get 'number a) 0)
                               (or (alist-get 'number b) 0))))))

(defun ghostherd-tab-pane (tab-id)
  "Return the pane record for TAB-ID (1 tab = 1 pane by design)."
  (let (found)
    (maphash (lambda (_ pane)
               (when (equal (alist-get 'tab_id pane) tab-id)
                 (setq found pane)))
             ghostherd--panes)
    found))

;;;; Space and tab selection

(defvar-local ghostherd-workspace-id nil
  "herdr workspace id this attach buffer belongs to.")
(defvar-local ghostherd-tab-id nil
  "herdr tab id this attach buffer belongs to.")
(defvar-local ghostherd-pane-id nil
  "herdr pane id this attach buffer is attached to.")

(defvar ghostherd--current-space nil
  "Workspace id of the most recently selected space.")

(defun ghostherd-current-space ()
  "Return the current workspace id: buffer-local, last selected, or focused."
  (or ghostherd-workspace-id
      (and ghostherd--current-space
           (gethash ghostherd--current-space ghostherd--workspaces)
           ghostherd--current-space)
      (cl-loop for w in (ghostherd-spaces)
               when (alist-get 'focused w)
               return (alist-get 'workspace_id w))
      (alist-get 'workspace_id (car (ghostherd-spaces)))))

(defun ghostherd--space-annotation (w)
  "Annotation string for workspace record W in completion."
  (format " [%s] %s tabs, %s"
          (or (alist-get 'agent_status w) "unknown")
          (alist-get 'tab_count w)
          (alist-get 'workspace_id w)))

(defun ghostherd--read-space (prompt)
  "Read a workspace with PROMPT; return the workspace id."
  (ghostherd--ensure)
  (let* ((spaces (ghostherd-spaces))
         (names (mapcar (lambda (w)
                          (cons (format "%s" (alist-get 'label w))
                                (alist-get 'workspace_id w)))
                        spaces))
         (table (lambda (str pred action)
                  (if (eq action 'metadata)
                      `(metadata
                        (annotation-function
                         . ,(lambda (name)
                              (let* ((wid (cdr (assoc name names)))
                                     (w (gethash wid ghostherd--workspaces)))
                                (and w (ghostherd--space-annotation w))))))
                    (complete-with-action action names str pred))))
         (choice (completing-read prompt table nil t)))
    (cdr (assoc choice names))))

(defun ghostherd--read-tab (prompt workspace-id)
  "Read a tab of WORKSPACE-ID with PROMPT; return the tab id."
  (let* ((tabs (ghostherd-tabs workspace-id))
         (names (mapcar (lambda (tab)
                          (cons (format "%s:%s"
                                        (alist-get 'number tab)
                                        (alist-get 'label tab))
                                (alist-get 'tab_id tab)))
                        tabs)))
    (unless names (user-error "ghostherd: space has no tabs"))
    (cdr (assoc (completing-read prompt names nil t) names))))

;;;; Attach buffers

(defun ghostherd--attach-buffer-name (workspace-id tab-id)
  "Return the attach buffer name for WORKSPACE-ID and TAB-ID."
  (let ((w (gethash workspace-id ghostherd--workspaces))
        (tab (gethash tab-id ghostherd--tabs)))
    (format ghostherd-attach-buffer-name-format
            (or (alist-get 'label w) workspace-id)
            (or (alist-get 'label tab) tab-id))))

(defun ghostherd--find-attach-buffer (tab-id)
  "Return a live attach buffer for TAB-ID, or nil."
  (cl-loop for buf in (buffer-list)
           when (and (buffer-live-p buf)
                     (equal (buffer-local-value 'ghostherd-tab-id buf) tab-id)
                     (with-current-buffer buf
                       (and (bound-and-true-p ghostel--process)
                            (process-live-p ghostel--process))))
           return buf))

(defun ghostherd--attach (tab-id &optional display)
  "Attach to TAB-ID's pane in a ghostel buffer; return the buffer.
Reuses a live attach buffer when one exists.  DISPLAY non-nil pops
to the buffer."
  (ghostherd--ensure)
  (let* ((pane (or (ghostherd-tab-pane tab-id)
                   (user-error "ghostherd: no pane for tab %s" tab-id)))
         (existing (ghostherd--find-attach-buffer tab-id))
         (buf (or existing
                  (let* ((wid (alist-get 'workspace_id pane))
                         (name (generate-new-buffer-name
                                (ghostherd--attach-buffer-name wid tab-id)))
                         (buf (generate-new-buffer name))
                         (terminal-id (alist-get 'terminal_id pane)))
                    (unless terminal-id
                      (user-error "ghostherd: pane %s has no terminal_id"
                                  (alist-get 'pane_id pane)))
                    (require 'ghostel)
                    (ghostel-exec buf ghostherd-herdr-program
                                  (list "terminal" "attach" terminal-id))
                    (with-current-buffer buf
                      (setq ghostherd-workspace-id (alist-get 'workspace_id pane)
                            ghostherd-tab-id tab-id
                            ghostherd-pane-id (alist-get 'pane_id pane)))
                    buf))))
    (with-current-buffer buf
      (setq ghostherd--current-space ghostherd-workspace-id))
    (when display (pop-to-buffer buf))
    buf))

(defun ghostherd-detach ()
  "Detach the current attach buffer from its herdr pane (ctrl+b q)."
  (interactive)
  (unless ghostherd-tab-id
    (user-error "Not a ghostherd attach buffer"))
  (ghostel-send-string "\x02q"))

;;;; Commands

;;;###autoload
(defun ghostherd-switch-space (workspace-id)
  "Switch to a space: show its active tab's terminal."
  (interactive (list (ghostherd--read-space "Space: ")))
  (setq ghostherd--current-space workspace-id)
  (let* ((w (gethash workspace-id ghostherd--workspaces))
         (tab-id (or (alist-get 'active_tab_id w)
                     (alist-get 'tab_id (car (ghostherd-tabs workspace-id))))))
    (if tab-id
        (ghostherd--attach tab-id t)
      (user-error "ghostherd: space %s has no tabs" workspace-id))))

;;;###autoload
(defun ghostherd-new-space (dir &optional label)
  "Create a space rooted at DIR (default: current project root).
LABEL defaults to DIR's base name."
  (interactive
   (let* ((proj (project-current))
          (root (if proj (project-root proj)
                  (read-directory-name "Space directory: "))))
     (list (expand-file-name root))))
  (ghostherd--ensure)
  (let* ((label (or label (file-name-nondirectory
                           (directory-file-name dir))))
         (result (ghostherd-client-request
                  "workspace.create"
                  `((cwd . ,dir) (label . ,label))))
         (wid (alist-get 'workspace_id (alist-get 'workspace result)))
         (tab-id (alist-get 'tab_id (alist-get 'tab result))))
    ;; Cache the records now; events will confirm.
    (puthash wid (alist-get 'workspace result) ghostherd--workspaces)
    (puthash tab-id (alist-get 'tab result) ghostherd--tabs)
    (when-let* ((pane (alist-get 'root_pane result)))
      (let ((pid (alist-get 'pane_id pane)))
        (puthash pid pane ghostherd--panes)
        (puthash pid t ghostherd--verified-panes))
      (ghostherd--sync-pane-subscriptions))
    (setq ghostherd--current-space wid)
    (when (called-interactively-p 'any)
      (ghostherd--attach tab-id t))
    wid))

;;;###autoload
(defun ghostherd-switch-tab (tab-id)
  "Switch to a tab in the current space."
  (interactive
   (progn (ghostherd--ensure)
          (list (ghostherd--read-tab "Tab: " (ghostherd-current-space)))))
  (ghostherd--attach tab-id t))

;;;###autoload
(defun ghostherd-new-tab (&optional label)
  "Create a tab in the current space and attach to it."
  (interactive)
  (ghostherd--ensure)
  (let* ((wid (or (ghostherd-current-space)
                  (user-error "ghostherd: no current space")))
         (params `((workspace_id . ,wid)
                   ,@(when label `((label . ,label)))))
         (result (ghostherd-client-request "tab.create" params))
         (tab (alist-get 'tab result))
         (tab-id (alist-get 'tab_id tab)))
    (puthash tab-id tab ghostherd--tabs)
    (when-let* ((pane (or (alist-get 'pane result)
                          (alist-get 'root_pane result))))
      (let ((pid (alist-get 'pane_id pane)))
        (puthash pid pane ghostherd--panes)
        (puthash pid t ghostherd--verified-panes))
      (ghostherd--sync-pane-subscriptions))
    (when (called-interactively-p 'any)
      (ghostherd--attach tab-id t))
    tab-id))

(defun ghostherd--tabs-around (tab-id)
  "Return (PREV CURRENT NEXT) tab ids around TAB-ID in its space."
  (let* ((tab (gethash tab-id ghostherd--tabs))
         (tabs (mapcar (lambda (tl) (alist-get 'tab_id tl))
                       (ghostherd-tabs (alist-get 'workspace_id tab))))
         (pos (cl-position tab-id tabs :test #'equal)))
    (when pos
      (list (nth (mod (1- pos) (length tabs)) tabs)
            tab-id
            (nth (mod (1+ pos) (length tabs)) tabs)))))

;;;###autoload
(defun ghostherd-next-tab ()
  "Attach to the next tab in the current buffer's space."
  (interactive)
  (unless ghostherd-tab-id (user-error "Not a ghostherd attach buffer"))
  (ghostherd--attach (nth 2 (ghostherd--tabs-around ghostherd-tab-id)) t))

;;;###autoload
(defun ghostherd-previous-tab ()
  "Attach to the previous tab in the current buffer's space."
  (interactive)
  (unless ghostherd-tab-id (user-error "Not a ghostherd attach buffer"))
  (ghostherd--attach (nth 0 (ghostherd--tabs-around ghostherd-tab-id)) t))

;;;###autoload
(defun ghostherd-close-tab (tab-id)
  "Close TAB-ID's herdr tab (and its pane process) after confirming.
This is the only ghostherd command that destroys herdr state."
  (interactive
   (progn (ghostherd--ensure)
          (list (or ghostherd-tab-id
                    (ghostherd--read-tab "Close tab: "
                                         (ghostherd-current-space))))))
  (let ((tab (gethash tab-id ghostherd--tabs)))
    (when (yes-or-no-p (format "Close herdr tab %s (kills its process)? "
                               (or (alist-get 'label tab) tab-id)))
      (when-let* ((buf (ghostherd--find-attach-buffer tab-id)))
        (with-current-buffer buf (ghostherd-detach))
        (kill-buffer buf))
      (ghostherd-client-request "tab.close" `((tab_id . ,tab-id)))
      (remhash tab-id ghostherd--tabs))))

;;;###autoload
(defun ghostherd-rename-tab (tab-id name)
  "Rename TAB-ID to NAME."
  (interactive
   (progn (ghostherd--ensure)
          (let ((tid (or ghostherd-tab-id
                         (ghostherd--read-tab "Rename tab: "
                                              (ghostherd-current-space)))))
            (list tid (read-string "New tab name: ")))))
  (ghostherd-client-request "tab.rename" `((tab_id . ,tab-id) (label . ,name))))

;;;###autoload
(defun ghostherd-rename-space (workspace-id name)
  "Rename WORKSPACE-ID to NAME."
  (interactive
   (progn (ghostherd--ensure)
          (list (ghostherd--read-space "Rename space: ")
                (read-string "New space name: "))))
  (ghostherd-client-request "workspace.rename"
                            `((workspace_id . ,workspace-id) (label . ,name))))

;;;; Blocked-agent navigation

(defvar ghostherd--blocked-ring-pos 0)

(defun ghostherd-blocked-panes ()
  "Return pane records whose agent status is blocked, all spaces."
  (let (out)
    (maphash (lambda (_ pane)
               (when (equal (alist-get 'agent_status pane) "blocked")
                 (push pane out)))
             ghostherd--panes)
    (nreverse out)))

;;;###autoload
(defun ghostherd-next-blocked ()
  "Jump to the next blocked agent's terminal, cycling across spaces."
  (interactive)
  (ghostherd--ensure)
  (let ((blocked (ghostherd-blocked-panes)))
    (unless blocked (user-error "ghostherd: no blocked agents"))
    (setq ghostherd--blocked-ring-pos
          (mod (1+ ghostherd--blocked-ring-pos) (length blocked)))
    (let ((pane (nth ghostherd--blocked-ring-pos blocked)))
      (ghostherd--attach (alist-get 'tab_id pane) t))))

;;;; Keymap

(defvar ghostherd-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'ghostherd-switch-space)
    (define-key map (kbd "S") #'ghostherd-new-space)
    (define-key map (kbd "t") #'ghostherd-switch-tab)
    (define-key map (kbd "c") #'ghostherd-new-tab)
    (define-key map (kbd "n") #'ghostherd-next-tab)
    (define-key map (kbd "p") #'ghostherd-previous-tab)
    (define-key map (kbd "b") #'ghostherd-next-blocked)
    (define-key map (kbd "k") #'ghostherd-close-tab)
    (define-key map (kbd "r") #'ghostherd-rename-tab)
    (define-key map (kbd "R") #'ghostherd-rename-space)
    (define-key map (kbd "g") #'ghostherd-resync)
    map)
  "Prefix keymap for ghostherd commands.  Bind to `C-c t'.")

;;;###autoload (autoload 'ghostherd-command-map "ghostherd" nil nil 'keymap)

(dolist (cmd '(ghostherd-next-tab ghostherd-previous-tab
               ghostherd-next-blocked))
  (put cmd 'repeat-map 'ghostherd-command-map))

(provide 'ghostherd)
;;; ghostherd.el ends here
