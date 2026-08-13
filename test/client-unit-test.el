;;; client-unit-test.el --- unit tests for ghostherd client -*- lexical-binding: t; -*-

;; Run: emacs --batch -Q -L lisp -l test/client-unit-test.el

(require 'ert)
(require 'ghostherd-client)

(ert-deftest ghostherd-client-open-starts-and-retries-when-socket-is-missing ()
  (let ((ghostherd-herdr-auto-start t)
        started
        connected)
    (cl-letf (((symbol-function 'ghostherd-client-socket-path)
               (lambda () "/tmp/missing-ghostherd-test.sock"))
              ((symbol-function 'file-exists-p) (lambda (_path) nil))
              ((symbol-function 'ghostherd-client--start-herdr)
               (lambda (path) (setq started path)))
              ((symbol-function 'ghostherd-client--connect)
               (lambda (&rest args) (setq connected args) 'process)))
      (should (eq (ghostherd-client--open "test" #'ignore) 'process))
      (should (equal started "/tmp/missing-ghostherd-test.sock"))
      (should (equal (nth 3 connected) "/tmp/missing-ghostherd-test.sock")))))

(ert-deftest ghostherd-client-open-does-not-start-when-disabled ()
  (let ((ghostherd-herdr-auto-start nil)
        started)
    (cl-letf (((symbol-function 'ghostherd-client-socket-path)
               (lambda () "/tmp/missing-ghostherd-test.sock"))
              ((symbol-function 'file-exists-p) (lambda (_path) nil))
              ((symbol-function 'ghostherd-client--start-herdr)
               (lambda (_path) (setq started t))))
      (should-error (ghostherd-client--open "test" #'ignore)
                    :type 'file-missing)
      (should-not started))))

(ert-run-tests-batch-and-exit)
