;;; sidebar-unit-test.el --- unit tests for ghostherd sidebar -*- lexical-binding: t; -*-

;; Run: emacs --batch -Q -L lisp -l test/sidebar-unit-test.el

(require 'ert)
(require 'ghostherd-sidebar)

(defmacro gh-sidebar-test--with-clean-frame (&rest body)
  `(let ((old-config (current-window-configuration))
         (ghostherd-sidebar-refresh-interval 60))
     (unwind-protect
         (progn
           (ghostherd-sidebar--stop-refresh-timer)
           (clrhash ghostherd-sidebar--saved-configurations)
           (delete-other-windows)
           ,@body)
       (ghostherd-sidebar--stop-refresh-timer)
       (when-let* ((buf (get-buffer ghostherd-sidebar-buffer-name)))
         (kill-buffer buf))
       (set-window-configuration old-config))))

(ert-deftest ghostherd-sidebar-refresh-timer-is-singleton ()
  (gh-sidebar-test--with-clean-frame
   (let ((buf (get-buffer-create ghostherd-sidebar-buffer-name)))
     (with-current-buffer buf (ghostherd-sidebar-mode))
     (ghostherd-sidebar--display-window)
     (ghostherd-sidebar--start-refresh-timer)
     (let ((timer ghostherd-sidebar--refresh-timer))
       (ghostherd-sidebar--start-refresh-timer)
       (should (timerp timer))
       (should (eq timer ghostherd-sidebar--refresh-timer))))))

(ert-deftest ghostherd-sidebar-refresh-tick-stops-when-hidden ()
  (gh-sidebar-test--with-clean-frame
   (setq ghostherd-sidebar--refresh-timer
         (run-at-time 60 60 #'ignore))
   (ghostherd-sidebar--refresh-tick)
   (should-not ghostherd-sidebar--refresh-timer)))

(ert-deftest ghostherd-sidebar-refresh-tick-resyncs-and-recovers-from-errors ()
  (gh-sidebar-test--with-clean-frame
   (let ((buf (get-buffer-create ghostherd-sidebar-buffer-name))
         (ghostherd--connected t)
         (calls 0))
     (with-current-buffer buf (ghostherd-sidebar-mode))
     (ghostherd-sidebar--display-window)
     (cl-letf (((symbol-function 'ghostherd-resync)
                (lambda ()
                  (setq calls (1+ calls))
                  (when (= calls 1) (error "temporary failure")))))
       (ghostherd-sidebar--refresh-tick)
       (ghostherd-sidebar--refresh-tick))
     (should (= calls 2))
     (should-not ghostherd-sidebar--refreshing))))

(ert-deftest ghostherd-sidebar-layout-replaces-an-existing-split ()
  (gh-sidebar-test--with-clean-frame
   (let ((terminal (get-buffer-create " *ghostherd-existing-split*")))
     (unwind-protect
         (progn
           (split-window-right)
           (ghostherd-sidebar--display-window)
           (select-window (get-buffer-window ghostherd-sidebar-buffer-name))
           (cl-letf (((symbol-function 'ghostherd--ensure) #'ignore)
                     ((symbol-function 'ghostherd--attach)
                      (lambda (&rest _) terminal)))
             (ghostherd-sidebar-layout '("one"))
             (should (eq (window-buffer (selected-window)) terminal))))
       (kill-buffer terminal)))))

(ert-deftest ghostherd-sidebar-layout-uses-side-and-main-windows ()
  (gh-sidebar-test--with-clean-frame
   (let ((one (get-buffer-create " *ghostherd-test-one*"))
         (two (get-buffer-create " *ghostherd-test-two*")))
     (unwind-protect
         (cl-letf (((symbol-function 'ghostherd--ensure) #'ignore)
                   ((symbol-function 'ghostherd--attach)
                    (lambda (tab-id &optional _display)
                      (if (equal tab-id "one") one two))))
           (ghostherd-sidebar-layout '("one" "two"))
           (let* ((sidebar (get-buffer-window ghostherd-sidebar-buffer-name))
                  (main-windows
                   (cl-remove-if
                    (lambda (window) (window-parameter window 'window-side))
                    (window-list))))
             (should (eq (window-parameter sidebar 'window-side) 'left))
             (should (= (window-total-width sidebar)
                        ghostherd-sidebar-width))
             (should (= (length main-windows) 2))
             (should (equal (mapcar #'window-buffer main-windows)
                            (list one two)))
             (should-not (window-parameter (selected-window) 'window-side))))
       (kill-buffer one)
       (kill-buffer two)))))

(ert-deftest ghostherd-sidebar-layout-cleans-saved-state-on-error ()
  (gh-sidebar-test--with-clean-frame
   (cl-letf (((symbol-function 'ghostherd--ensure) #'ignore)
             ((symbol-function 'ghostherd--attach)
              (lambda (&rest _) (get-buffer-create " *ghostherd-error*")))
             ((symbol-function 'ghostherd-sidebar--install-terminal-windows)
              (lambda (&rest _) (error "too small"))))
     (should-error (ghostherd-sidebar-layout '("one")))
     (should-not (gethash (selected-frame)
                          ghostherd-sidebar--saved-configurations)))))

(ert-deftest ghostherd-sidebar-tab-candidates-are-unique ()
  (cl-letf (((symbol-function 'ghostherd-spaces)
             (lambda () '(((workspace_id . "w1") (label . "same"))
                          ((workspace_id . "w2") (label . "same")))))
            ((symbol-function 'ghostherd-tabs)
             (lambda (wid) `(((tab_id . ,(concat wid ":t1"))
                              (label . "same")))))
            ((symbol-function 'ghostherd-tab-pane) (lambda (_) nil)))
    (let ((candidates (ghostherd-sidebar--tab-candidates)))
      (should (= (length candidates) 2))
      (should-not (equal (caar candidates) (caadr candidates))))))

(ert-deftest ghostherd-sidebar-layout-restores-previous-configuration ()
  (gh-sidebar-test--with-clean-frame
   (let* ((original (window-buffer (selected-window)))
          (terminal (get-buffer-create " *ghostherd-test-terminal*")))
     (unwind-protect
         (cl-letf (((symbol-function 'ghostherd--ensure) #'ignore)
                   ((symbol-function 'ghostherd--attach)
                    (lambda (&rest _) terminal)))
           (ghostherd-sidebar-layout '("one"))
           (should (get-buffer-window ghostherd-sidebar-buffer-name))
           (ghostherd-sidebar-restore-layout)
           (should-not (get-buffer-window ghostherd-sidebar-buffer-name))
           (should (eq (window-buffer (selected-window)) original)))
       (kill-buffer terminal)))))

(ert-run-tests-batch-and-exit)
