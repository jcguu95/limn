;;;; OS-level end-to-end test of the demo init.lisp.
;;;;
;;;; Counterpart to batch11-demo-init.lisp. Same 11-check scenario, but
;;;; keystrokes via xdotool (real X11 input). Designed to run inside a
;;;; Linux container with Xvfb + xdotool.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((p (sb-ext:run-program "xdotool"
                                    (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p))
          (return t)))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

;; Use the demo init.lisp as the user's init file.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-os"))
(sb-posix:setenv "LIMN_INIT" (b/ "tests/e2e/demo-init.lisp") 1)

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (unless ok (push msg *failures*)))

(defun current-page ()
  (getf (limn/bridge:response-data
         (limn:call "view/get" :|win-id| "w1"))
        :|page|))

(let* ((sock (format nil "/tmp/limn-e2e-osdemo-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-demo.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)
  (limn:call "bridge/engine-load" :|engine| "mupdf"
              :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
  (sleep 0.3)

  (format t "~%── init.lisp loaded? ──~%")
  (check "next-page defined"   (limn/cmd:find-command 'next-page))
  (check "search-here defined" (limn/cmd:find-command 'search-here))

  (format t "~%── xdotool key j: page 0 → 1 ──~%")
  (xdotool "key" "--clearmodifiers" "j") (sleep 0.3)
  (check "page = 1 after j" (= 1 (current-page)))

  (format t "~%── xdotool key k: page 1 → 0 ──~%")
  (xdotool "key" "--clearmodifiers" "k") (sleep 0.3)
  (check "page = 0 after k" (= 0 (current-page)))

  (format t "~%── xdotool key shift+g: → last page (5) ──~%")
  (xdotool "key" "--clearmodifiers" "shift+g") (sleep 0.3)
  (check "page = 5 after G" (= 5 (current-page)))

  (format t "~%── xdotool key g g: → first page (0) ──~%")
  (xdotool "key" "--clearmodifiers" "g") (sleep 0.15)
  (xdotool "key" "--clearmodifiers" "g") (sleep 0.3)
  (check "page = 0 after g g" (= 0 (current-page)))

  (format t "~%── xdotool key slash: minibuffer opens ──~%")
  (xdotool "key" "--clearmodifiers" "slash") (sleep 0.4)
  (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (check "minibuffer open"     (eq (getf d :|open|) t))
    (check "prompt is /"         (equal (getf d :|prompt|) "/")))

  (format t "~%── xdotool key ctrl+g: cancel ──~%")
  (xdotool "key" "--clearmodifiers" "ctrl+g") (sleep 0.5)
  (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (check "minibuffer closed after C-g" (eq (getf d :|open|) :false)))

  (format t "~%── introspection ──~%")
  (let ((ks (limn/introspect:where-is-command 'next-page)))
    (check "where-is-command 'next-page contains \"j\""
           (find "j" ks :test #'string=)))
  (check "describe-command 'search-here returns spec"
         (equal "s/" (getf (limn/introspect:describe-command 'search-here)
                            :spec)))

  (let ((ok (null *failures*)))
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — OS-level demo init.lisp drives full v0.8 stack"
                   (format nil "✗ FAIL: ~{~%    ~a~}" *failures*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (sb-posix:setenv "LIMN_INIT" "" 1)
    (when (probe-file "/tmp/.limn/init.lisp.stash-os")
      (rename-file "/tmp/.limn/init.lisp.stash-os" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
