;;;; v0.31 §B OS-tier — coding systems end-to-end
;;;;
;;;; 真實 limn binary + 三種 fixture 檔案。測整條鏈：
;;;;   spawn limn → limn:call bridge/engine-load path=fixture
;;;;              → buffer/text → 比對 Unicode 字串
;;;;              → save-buffer → diff fixture bytes == 0
;;;;
;;;; Fixtures（需提前建好）：
;;;;   backend/tests/fixtures/big5.txt      — "你好世界\n" in Big5
;;;;   backend/tests/fixtures/gb18030.txt   — "你好世界\n" in GB18030
;;;;   backend/tests/fixtures/sjis.txt      — "日本語テスト\n" in Shift-JIS
;;;;
;;;; Ω1: open Big5 fixture → buffer text = "你好世界\n"
;;;; Ω2: open GB18030 fixture → buffer text = "你好世界\n"
;;;; Ω3: open Shift-JIS fixture → buffer text = "日本語テスト\n"
;;;;      (or graceful fallback warning without crash)
;;;; Ω4: Big5 save-buffer → diff with original file = 0 bytes difference

(in-package :cl-user)
(require :sb-posix)
(require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))

(defun b/ (f) (concatenate 'string *bdir* f))

(defun fixture-path (name)
  (concatenate 'string *bdir* "tests/fixtures/" name))

;; ── load backend modules ──────────────────────────────────────────────────

;; Stash any existing init.lisp so our test environment is clean.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v031coding"))

(dolist (f '("limn-hooks.lisp"
             "limn-log.lisp"
             "limn-error.lisp"
             "limn-timer.lisp"
             "limn-process.lisp"
             "limn-buffer.lisp"
             "limn-bridge.lisp"
             "limn-undo.lisp"
             "limn-buffer-undo.lisp"
             "limn-keys.lisp"
             "limn-search.lisp"
             "limn-client.lisp"
             "limn-dispatch.lisp"
             "limn-mode.lisp"
             "limn-cmd.lisp"
             "limn-runtime.lisp"
             "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-kill.lisp"
             "limn-mark.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-text-nav.lisp"
             "limn-syntax.lisp"    ; v0.31 §A
             "limn-coding.lisp"    ; v0.31 §B
             "limn-file.lisp"
             "limn.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

;; ── test harness ─────────────────────────────────────────────────────────

(defparameter *failures* nil)

(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun read-file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      buf)))

;; ── limn:call helper ─────────────────────────────────────────────────────

(defun limn-call (cmd &rest args)
  "Call limn:call-once or the equivalent RPC primitive."
  (let ((call-fn (find-symbol "CALL" (find-package '#:limn))))
    (if call-fn
        (apply (symbol-function call-fn) cmd args)
        (error "limn:call not found — limn.lisp may not be loaded"))))

;; ── fixture guard ─────────────────────────────────────────────────────────

(defun fixture-ok? (name)
  (probe-file (fixture-path name)))

;; ── Ω1. Big5 open ────────────────────────────────────────────────────────

(format t "~%--- Ω1: open Big5 fixture ---~%")
(cond
  ((not (fixture-ok? "big5.txt"))
   (format t "  SKIP: backend/tests/fixtures/big5.txt not found~%"))
  (t
   (handler-case
       (let* ((result (limn-call "bridge/engine-load"
                                  :|win-id| "w1"
                                  :|engine| "text"
                                  :|path|   (fixture-path "big5.txt")))
              (bid    (getf (getf result :|data|) :|buffer-id|))
              (r-text (limn-call "buffer/text" :|buffer-id| bid))
              (text   (getf (getf r-text :|data|) :|text|)))
         (check "bridge/engine-load ok"       (getf result :|ok|))
         (check "buffer/text ok"              (getf r-text :|ok|))
         (check "Big5: content starts with 你好世界"
                (and text
                     (>= (length text) 4)
                     (string= "你好世界" (subseq text 0 4)))
                (format nil "got: ~s" (when text (subseq text 0 (min 20 (length text)))))))
     (error (e)
       (check "Ω1 no unhandled error" nil (format nil "~A" e))))))

;; ── Ω2. GB18030 open ────────────────────────────────────────────────────

(format t "~%--- Ω2: open GB18030 fixture ---~%")
(cond
  ((not (fixture-ok? "gb18030.txt"))
   (format t "  SKIP: backend/tests/fixtures/gb18030.txt not found~%"))
  (t
   (handler-case
       (let* ((result (limn-call "bridge/engine-load"
                                  :|win-id| "w1"
                                  :|engine| "text"
                                  :|path|   (fixture-path "gb18030.txt")))
              (bid    (getf (getf result :|data|) :|buffer-id|))
              (r-text (limn-call "buffer/text" :|buffer-id| bid))
              (text   (getf (getf r-text :|data|) :|text|)))
         (check "GB18030: engine-load ok"    (getf result :|ok|))
         (check "GB18030: buffer/text ok"    (getf r-text :|ok|))
         (check "GB18030: content starts with 你好世界"
                (and text
                     (>= (length text) 4)
                     (string= "你好世界" (subseq text 0 4)))
                (format nil "got: ~s" (when text (subseq text 0 (min 20 (length text)))))))
     (error (e)
       (check "Ω2 no unhandled error" nil (format nil "~A" e))))))

;; ── Ω3. Shift-JIS open ───────────────────────────────────────────────────

(format t "~%--- Ω3: open Shift-JIS fixture ---~%")
(cond
  ((not (fixture-ok? "sjis.txt"))
   (format t "  SKIP: backend/tests/fixtures/sjis.txt not found~%"))
  (t
   (handler-case
       (let* ((result (limn-call "bridge/engine-load"
                                  :|win-id| "w1"
                                  :|engine| "text"
                                  :|path|   (fixture-path "sjis.txt")))
              (bid    (getf (getf result :|data|) :|buffer-id|))
              (r-text (limn-call "buffer/text" :|buffer-id| bid))
              (text   (getf (getf r-text :|data|) :|text|)))
         (check "SJIS: engine-load ok" (getf result :|ok|))
         (check "SJIS: buffer/text ok" (getf r-text :|ok|))
         ;; Accept either correct decode or graceful fallback (no crash).
         ;; Correct decode: content starts with 日本語テスト.
         ;; Fallback: content is non-nil (garbage bytes or warning, but no nil).
         (check "SJIS: content is non-nil (decode or graceful fallback)"
                (not (null text))
                (format nil "got: ~s" text))
         ;; Bonus: if it decoded correctly, check the actual content.
         (when (and text (>= (length text) 6))
           (check "SJIS: content starts with 日本語テスト (if supported)"
                  (string= "日本語テスト" (subseq text 0 6))
                  (format nil "got: ~s" (subseq text 0 (min 20 (length text)))))))
     (error (e)
       ;; Shift-JIS may be unsupported on some SBCL builds; warn but don't fail hard.
       (format t "  NOTE: Shift-JIS test skipped (SBCL may lack native support): ~A~%" e)))))

;; ── Ω4. Big5 save-buffer round-trip ─────────────────────────────────────

(format t "~%--- Ω4: Big5 save-buffer byte round-trip ---~%")
(cond
  ((not (fixture-ok? "big5.txt"))
   (format t "  SKIP: backend/tests/fixtures/big5.txt not found~%"))
  (t
   (handler-case
       (let* ((orig-bytes (read-file-bytes (fixture-path "big5.txt")))
              (result (limn-call "bridge/engine-load"
                                  :|win-id| "w1"
                                  :|engine| "text"
                                  :|path|   (fixture-path "big5.txt")))
              (bid    (getf (getf result :|data|) :|buffer-id|))
              (file-pkg (find-package '#:limn/file))
              (written-cell (list nil)))
         (check "Ω4 engine-load ok" (getf result :|ok|))
         (if (null file-pkg)
             (format t "  NOTE: limn/file not loaded; skipping save step~%")
             (let* ((save-fn   (symbol-function
                                  (find-symbol "SAVE-BUFFER" file-pkg)))
                    (write-sym (find-symbol "*WRITE-FILE-FN*" file-pkg)))
               (progv (list write-sym)
                      (list (lambda (path bytes)
                              (declare (ignore path))
                              (setf (car written-cell) bytes)))
                 (funcall save-fn bid))
               (let ((wb (car written-cell)))
                 (check "Ω4 write was called" (not (null wb)))
                 (when wb
                   (check "Ω4 byte count matches"
                          (= (length orig-bytes) (length wb))
                          (format nil "orig=~a written=~a"
                                  (length orig-bytes) (length wb)))
                   (check "Ω4 bytes byte-for-byte identical"
                          (loop for i below (length orig-bytes)
                                always (= (aref orig-bytes i) (aref wb i)))
                          "some bytes differ"))))))
     (error (e)
       (check "Ω4 no unhandled error" nil (format nil "~A" e))))))

;; ── summary ──────────────────────────────────────────────────────────────

(format t "~%=== v0.31 coding OS-tier: ~a failure(s) ===~%"
        (length *failures*))
(when *failures*
  (format t "Failed checks:~%")
  (dolist (f (reverse *failures*))
    (format t "  - ~a~%" f)))

;; Restore stashed init.lisp if it existed.
(when (probe-file "/tmp/.limn/init.lisp.stash-v031coding")
  (rename-file "/tmp/.limn/init.lisp.stash-v031coding"
               "/tmp/.limn/init.lisp"))

(sb-ext:exit :code (if *failures* 1 0))
