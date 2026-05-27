;;; Probe: what does test/grab-window actually return?
(in-package :cl-user)
(require :sb-posix)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest a)
  (sb-ext:run-program "xdotool" a :search t :wait t :output nil :error nil))

(let* ((sock (format nil "/tmp/limn-probe-~a" (sb-posix:getpid)))
       (proc (sb-ext:run-program "/limn/sioyek/limn"
                                  (list "--test-mode" "--socket" sock)
                                  :wait nil :search nil :output "/tmp/limn-probe.log"
                                  :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.8)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)

  (limn:call "bridge/engine-load" :|engine| "mupdf"
              :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
  (sleep 1.0)

  (flet ((stats (label)
           (let* ((r (limn:call "test/grab-window" :|win-id| "w1"))
                  (d (limn/bridge:response-data r)))
             (format t "  [~a] capture=~a w=~a h=~a avg-lum=~,2f~%"
                     label (getf d :|capture-source|)
                     (getf d :|width|) (getf d :|height|)
                     (getf d :|avg-luminance|)))))
    (stats "step-00")
    ;; Toggle dark
    (xdotool "key" "--clearmodifiers" "d") (sleep 0.6)
    (stats "step-01 (dark)")
    (xdotool "key" "--clearmodifiers" "d") (sleep 0.6)
    (stats "step-02 (light)"))

  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn")
                                      :search t :wait t)))
(sb-ext:exit :code 0)
