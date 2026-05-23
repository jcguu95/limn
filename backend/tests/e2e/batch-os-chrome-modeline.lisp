;;;; Batch 17: chrome buffer state + modeline — 之前沒測過的 dimension.
;;;;
;;;; *messages* buffer 累積行為、modeline/set 真實反映、echo area。
;;;; SPEC §5.5 / §5.6 / §1.2 的 chrome primitives 雖然 batch 1.6 ζ1
;;;; 對基本 event 欄位有 sweep、但 chrome buffer 內容隨時間累積、
;;;; modeline 三段 (left/middle/right) 更新、message/log vs message/echo
;;;; 的區別、這層完全沒問。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cm"))

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

(let* ((sock (format nil "/tmp/limn-e2e-cm-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-cm.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── *messages* accumulation ───────────────────────────────────────

    (format t "~%── *messages* buffer accumulates message/echo + log ──~%")
    (limn:call "message/echo" :|text| "first echo")
    (sleep 0.1)
    (limn:call "message/log"  :|text| "background log")
    (sleep 0.1)
    (limn:call "message/echo" :|text| "second echo")
    (sleep 0.2)

    (let* ((r (limn:call "buffer/text" :|buffer-id| "*messages*"))
           (d (limn/bridge:response-data r))
           (text (getf d :|text|)))
      (check "*messages* — non-empty"
             (and (stringp text) (> (length text) 0))
             (format nil "got ~s" text))
      (check "*messages* — contains 'first echo'"
             (search "first echo" text))
      (check "*messages* — contains 'background log'"
             (search "background log" text))
      (check "*messages* — contains 'second echo'"
             (search "second echo" text))
      (check "*messages* — entries appear in order"
             (< (search "first echo" text)
                (search "background log" text)
                (search "second echo" text))))

;;; ── echo area: message/echo writes, message/clear empties ────────

    (format t "~%── echo area (chrome primitive) ──~%")
    (limn:call "message/echo" :|text| "echo here")
    (sleep 0.2)
    (let* ((r (limn:call "buffer/text" :|buffer-id| "*echo-area*"))
           (d (limn/bridge:response-data r))
           (text (getf d :|text|)))
      (check "*echo-area* — contains 'echo here'"
             (and (stringp text) (search "echo here" text))
             (format nil "got ~s" text)))

    (limn:call "message/clear")
    (sleep 0.2)
    (let* ((r (limn:call "buffer/text" :|buffer-id| "*echo-area*"))
           (d (limn/bridge:response-data r))
           (text (getf d :|text|)))
      (check "*echo-area* — empty after message/clear"
             (and (stringp text) (zerop (length text)))
             (format nil "got ~s" text)))

    ;; message/clear should NOT touch *messages*
    (let* ((r (limn:call "buffer/text" :|buffer-id| "*messages*"))
           (d (limn/bridge:response-data r))
           (text (getf d :|text|)))
      (check "*messages* — still has history after message/clear"
             (and (stringp text) (search "echo here" text))
             (format nil "got len=~a" (and (stringp text) (length text)))))

;;; ── modeline/set + modeline/get ───────────────────────────────────

    (format t "~%── modeline 三段 (left/middle/right) ──~%")
    (limn:call "modeline/set" :|win-id| "w1"
                :|left|   "PDF: test.pdf"
                :|middle| "fund-mode"
                :|right|  "5/42 (12%)")
    (sleep 0.2)
    (let* ((r (limn:call "modeline/get" :|win-id| "w1"))
           (d (limn/bridge:response-data r)))
      (check "modeline left preserved"
             (equal (getf d :|left|) "PDF: test.pdf")
             (format nil "got ~s" d))
      (check "modeline middle preserved"
             (equal (getf d :|middle|) "fund-mode"))
      (check "modeline right preserved"
             (equal (getf d :|right|) "5/42 (12%)")))

    ;; Update one segment only
    (limn:call "modeline/set" :|win-id| "w1" :|right| "6/42 (14%)")
    (sleep 0.2)
    (let* ((r (limn:call "modeline/get" :|win-id| "w1"))
           (d (limn/bridge:response-data r)))
      (check "modeline right updated"
             (equal (getf d :|right|) "6/42 (14%)"))
      ;; Other segments — SPEC unclear if partial set preserves others
      ;; or wipes. Pin current behaviour.
      (format t "  (after partial set: left=~s middle=~s)~%"
              (getf d :|left|) (getf d :|middle|)))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 17 chrome / modeline green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-cm")
        (rename-file "/tmp/.limn/init.lisp.stash-cm" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
