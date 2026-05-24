;;;; v0.32 — with-current-buffer "*messages*" isolation (OS-tier)
;;;;
;;;; 真實 limn binary。驗證：
;;;;
;;;; Ω1 原 buffer point 在某位置（5）、with-current-buffer "*messages*"
;;;;    body 內 insert 到 *messages* → *messages* 真的有新內容。
;;;; Ω2 結束後 current-buffer-id 回到原 buffer。
;;;; Ω3 原 buffer 的 point 完全沒被動到（仍 5）。
;;;; Ω4 with-current-buffer 巢狀：A → *messages* → A，最外層 restore 對。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v032wcb"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-mark.lisp"
             "limn-excursion.lisp"
             "limn.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun text-engine-load ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun buf-text (buf)
  (let ((r (limn:call "buffer/text" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (buf)
  (let ((r (limn:call "buffer/cursor-get" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|offset|))))

(defun buf-cursor-set (buf off)
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| off))

(defun buf-insert (buf text)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v032wcb-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v032wcb.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (unless (xpkg)
    (format t "✗ FATAL: limn/excursion not loaded — RED expected~%")
    (push "limn/excursion not loaded" *failures*))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))

    (unless buf
      (limn:stop)
      (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc)
      (sb-ext:exit :code 2))

    (let ((set-buf (xsym "SET-BUFFER")))
      (when set-buf (funcall set-buf buf)))

;;; ── Seed: 'hello world' + point=5 ─────────────────────────────────────

    (format t "~%── Seed: 'hello world', point=5 ──~%")
    (buf-insert buf "hello world")
    (sleep 0.1)
    (buf-cursor-set buf 5)
    (sleep 0.1)
    (check (format nil "point = 5 (got ~a)" (buf-cursor buf))
           (eql 5 (buf-cursor buf)))

;;; ── Ω1: with-current-buffer "*messages*" writes to *messages* ─────

    (format t "~%── Ω1: with-current-buffer \"*messages*\" body insert ──~%")
    (let ((wcb (xsym "WITH-CURRENT-BUFFER")))
      (cond
        ((not wcb)
         (check "with-current-buffer present" nil "RED"))
        (t
         (eval `(,wcb "*messages*"
                 (limn:call "buffer/insert"
                            :|buffer-id| "*messages*"
                            :|text| "v032-wcb-line\n")))
         (sleep 0.2)
         (let ((mtext (buf-text "*messages*")))
           (check (format nil "*messages* contains 'v032-wcb-line' (got ~a chars)"
                          (and (stringp mtext) (length mtext)))
                  (and (stringp mtext) (search "v032-wcb-line" mtext)))))))

;;; ── Ω2: after with-current-buffer, current-buffer-id restored ───────

    (format t "~%── Ω2: current-buffer-id restored to original ──~%")
    (let ((cur (xsym "CURRENT-BUFFER-ID")))
      (cond
        ((not cur) (check "current-buffer-id present" nil "RED"))
        (t (let ((cid (funcall cur)))
             (check (format nil "current id = ~s, expected ~s" cid buf)
                    (equal cid buf))))))

;;; ── Ω3: original buffer's point untouched ────────────────────────────

    (format t "~%── Ω3: original buffer's point unchanged ──~%")
    (let ((point-after (buf-cursor buf)))
      (check (format nil "original point still 5 (got ~a)" point-after)
             (eql 5 point-after)))

;;; ── Ω4: nested with-current-buffer ───────────────────────────────────

    (format t "~%── Ω4: nested with-current-buffer A → *messages* → A ──~%")
    (let ((wcb (xsym "WITH-CURRENT-BUFFER"))
          (cur (xsym "CURRENT-BUFFER-ID")))
      (cond
        ((not (and wcb cur)) (check "nested API present" nil "RED"))
        (t
         (let ((depths '()))
           (eval `(,wcb ,buf
                   (push (,cur) ',depths)
                   (,wcb "*messages*"
                    (push (,cur) ',depths))
                   (push (,cur) ',depths)))
           (check (format nil "depth log: ~s" depths)
                  (and (eql 3 (length depths))
                       (equal (first depths) buf)
                       (equal (second depths) "*messages*")
                       (equal (third depths) buf)))))))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (format t "~%── v032 with-current-buffer isolation e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
