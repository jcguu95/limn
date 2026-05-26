;;;; End-to-end test of batch 11: demo init.lisp's vim-style navigation
;;;; and search defcommand exercising the full v0.8 stack.
;;;;
;;;; Scenario:
;;;;   1. Point $LIMN_INIT at backend/init.lisp.example
;;;;   2. Spawn limn + load fixture PDF (6 pages)
;;;;   3. Verify init.lisp loaded — next-page command exists in registry
;;;;   4. inject 'j' → expect page advance 0 → 1
;;;;   5. inject 'k' → expect page back 1 → 0
;;;;   6. inject 'G' → expect last page (5)
;;;;   7. inject 'g' 'g' → multi-key prefix → expect page 0
;;;;   8. inject '/' → minibuffer should open with prompt "/"
;;;;   9. inject C-g → minibuffer should close (cancel)
;;;;   10. introspection: where-is-command 'next-page should include "j"

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      "/Users/jin/data/local/projects/sioyek-core/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

;; Stash any /tmp/.limn/init.lisp and point $LIMN_INIT at the demo file
;; so the test is hermetic regardless of dev state.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash11"))
(sb-posix:setenv "LIMN_INIT" (b/ "tests/e2e/demo-init.lisp") 1)

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(sb-posix:setenv "QT_QPA_PLATFORM" "minimal" 1)

(defparameter *failures* nil)
(defun check (msg ok)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (unless ok (push msg *failures*)))

(defun current-page ()
  (let ((d (limn/bridge:response-data
            (limn:call "view/get" :|win-id| "w1"))))
    (getf d :|page|)))

(let* ((sock (format nil "/tmp/limn-e2e-demo-~a" (sb-posix:getpid)))
       (proc (sb-ext:run-program
              (b/ "../sioyek/limn.app/Contents/MacOS/limn")
              (list "--headless" "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-e2e-demo.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (limn:call "bridge/engine-load" :|engine| "mupdf"
              :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")

  (format t "~%── init.lisp loaded? ──~%")
  (check "next-page defined"  (limn/cmd:find-command 'next-page))
  (check "search-here defined" (limn/cmd:find-command 'search-here))

  (format t "~%── j: 0 → 1 ──~%")
  (limn:call "test/inject-qt-key" :|key| "j") (sleep 0.2)
  (check "page = 1 after j" (= 1 (current-page)))

  (format t "~%── k: 1 → 0 ──~%")
  (limn:call "test/inject-qt-key" :|key| "k") (sleep 0.2)
  (check "page = 0 after k" (= 0 (current-page)))

  (format t "~%── G: → last page (5) ──~%")
  ;; 'G' is Shift-g; Qt input filter encodes shift via uppercase letter
  ;; for printable chars. We inject "G" with no mods — the filter
  ;; treats it like a normal printable.
  (limn:call "test/inject-qt-key" :|key| "G") (sleep 0.2)
  (check "page = 5 after G" (= 5 (current-page)))

  (format t "~%── g g: → first page (0) ──~%")
  (limn:call "test/inject-qt-key" :|key| "g") (sleep 0.1)
  (limn:call "test/inject-qt-key" :|key| "g") (sleep 0.2)
  (check "page = 0 after g g" (= 0 (current-page)))

  (format t "~%── / opens minibuffer ──~%")
  (limn:call "test/inject-qt-key" :|key| "/") (sleep 0.3)
  (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (check "minibuffer open"        (eq (getf d :|open|) t))
    (check "prompt is /"            (equal (getf d :|prompt|) "/")))

  (format t "~%── C-g cancels minibuffer ──~%")
  (limn:call "test/inject-qt-key" :|key| "g" :|mods| (list "ctrl"))
  (sleep 0.5)
  (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
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
            (if ok "✓ PASS — demo init.lisp drives full v0.8 stack"
                   (format nil "✗ FAIL: ~{~%    ~a~}" *failures*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (sb-posix:setenv "LIMN_INIT" "" 1)
    (when (probe-file "/tmp/.limn/init.lisp.stash11")
      (rename-file "/tmp/.limn/init.lisp.stash11" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
