;;;; Batch 22: integration of new v0.12 features into demo-like flow.
;;;;
;;;; 串連 v0.12 batch 20 (BS / arrows) + 21 (numeric prefix arg) +
;;;; v0.8/9 既有 (defcommand minibuffer) 真實使用者場景：
;;;;
;;;;   /seach: type query → realize typo → BS to fix → Left/Right to
;;;;   navigate → submit
;;;;
;;;;   '5g' goto-page → use prefix arg、確認 page 真的跳
;;;;
;;;; 是「end-to-end 整合 driver」、看新 feature 跟舊機制相容。

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

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-int"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(let* ((sock (format nil "/tmp/limn-e2e-int-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-int.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── Scenario A: typo correction via BS + arrow ─────────────────

    (format t "~%── Scenario A: typo correction in search ──~%")
    (defparameter cl-user::*int-query* nil)
    (limn/cmd:defcommand int-search (:interactive "sFind: ")
      (lambda (q) (setf cl-user::*int-query* q)))
    (limn:bind "s" 'int-search)
    (sleep 0.2)

    (xdotool "key" "--clearmodifiers" "s")
    (sleep 0.3)
    ;; type "helo" (typo)
    (xdotool "type" "--delay" "20" "helo")
    (sleep 0.3)
    ;; Move left to between e and l
    (xdotool "key" "--clearmodifiers" "Left")
    (xdotool "key" "--clearmodifiers" "Left")
    (sleep 0.2)
    ;; insert "l"
    (xdotool "type" "--delay" "20" "l")
    (sleep 0.3)
    ;; should now be "hello"
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check (format nil "Scenario A — typo fixed to 'hello' (got ~s)"
                     (getf d :|text|))
             (equal (getf d :|text|) "hello")))

    ;; submit
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.3)
    (check (format nil "Scenario A — submit delivers 'hello' (got ~s)"
                   cl-user::*int-query*)
           (equal cl-user::*int-query* "hello"))

;;; ── Scenario B: BS-only correction ──────────────────────────────

    (format t "~%── Scenario B: pure backspace correction ──~%")
    (setf cl-user::*int-query* nil)
    (xdotool "key" "--clearmodifiers" "s")
    (sleep 0.3)
    (xdotool "type" "--delay" "20" "wronged")
    (sleep 0.3)
    ;; BS×3 to delete "ged", leaving "wron"
    (dotimes (i 3)
      (xdotool "key" "--clearmodifiers" "BackSpace"))
    (sleep 0.3)
    (xdotool "type" "--delay" "20" "g")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check (format nil "Scenario B — text is 'wrong' (got ~s)"
                     (getf d :|text|))
             (equal (getf d :|text|) "wrong")))
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.3)
    (check (format nil "Scenario B — submitted 'wrong' (got ~s)"
                   cl-user::*int-query*)
           (equal cl-user::*int-query* "wrong"))

;;; ── Scenario C: '5g' goto-page round-trip ─────────────────────

    (format t "~%── Scenario C: '5g' goto-page using prefix arg ──~%")
    ;; Define goto-page-by binding
    (limn/cmd:defcommand goto-page-by (:interactive "p")
      (lambda (n)
        (limn:call "view/set" :|win-id| "w1" :|page| n)))
    (limn:bind "g" 'goto-page-by)
    (sleep 0.2)

    ;; Start at page 0
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.2)

    ;; '5' 'g' → page 5
    (xdotool "key" "--clearmodifiers" "5")
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.4)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1"))))
      (check (format nil "Scenario C — '5g' jumped to page 5 (got page=~a)"
                     (getf d :|page|))
             (= (getf d :|page|) 5)))

    ;; '0' 'g' → page 0
    (xdotool "key" "--clearmodifiers" "0")
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.4)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1"))))
      (check (format nil "Scenario C — '0g' returned to page 0 (got page=~a)"
                     (getf d :|page|))
             (= (getf d :|page|) 0)))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 22 integration green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-int")
        (rename-file "/tmp/.limn/init.lisp.stash-int" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
