;;;; C5: PDF 檔名含中文字 — Unicode 全鏈路通透測試。
;;;;
;;;; 載入路徑：
;;;;   SBCL 字串 "/tmp/你好世界.pdf"
;;;;     → JSON encode (UTF-8 escape)
;;;;     → Bridge socket
;;;;     → C++ QJsonValue.toString() → QString
;;;;     → QString.toStdWString() → std::wstring
;;;;     → mupdf fz_open_document(C-style char*)
;;;;
;;;; 任一步 mojibake / 截斷 / encoding 錯誤都會讓 load 失敗。
;;;;
;;;; 這個 driver 不需要 xdotool（不涉及 OS-level keystroke）但放在 e2e
;;;; tier 因為要走真實 Lisp client → 真實 Limn binary 端到端。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defparameter *cjk-pdf* "/tmp/你好世界.pdf")

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cjk"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

;; Copy fixture PDF to a Unicode path (overwrites if exists).
(let ((p (sb-ext:run-program "cp"
                              (list (b/ "tests/fixtures/test.pdf") *cjk-pdf*)
                              :search t :wait t :output t :error t)))
  (unless (zerop (sb-ext:process-exit-code p))
    (format t "✗ cp to CJK path failed~%")
    (sb-ext:exit :code 1)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(let* ((sock (format nil "/tmp/limn-e2e-cjk-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-cjk.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)

  (format t "~%── C5: PDF filename with CJK characters ──~%")
  (format t "  path = ~s~%" *cjk-pdf*)

  (let* ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf"
                       :|path|   *cjk-pdf*
                       :|win-id| "w1"))
         (ok-flag (getf r :|ok|)))
    (check "engine-load returned ok=true"
           (eq ok-flag t)
           (format nil "got response: ~s" r)))

  ;; Verify document is actually loaded (not just ok response).
  (sleep 0.2)
  (let* ((g (limn:call "view/get" :|win-id| "w1"))
         (d (limn/bridge:response-data g))
         (page-count (and d (getf d :|page-count|))))
    (check "view/get reports a valid page-count"
           (and (integerp page-count) (> page-count 0))
           (format nil "got page-count=~s" page-count)))

  ;; Read words from page 0 to make sure mupdf actually decoded content.
  ;; mupdf engine returns {words: [...]} per SPEC §5.3; text-engine paths
  ;; return {text: "..."}. For our PDF-via-CJK-path test we're on mupdf.
  (let* ((r (limn:call "buffer/text"
                       :|buffer-id| "b1"
                       :|page| 0))
         (d (limn/bridge:response-data r))
         (words (and d (getf d :|words|))))
    (check "buffer/text returns non-empty word list from page 0"
           (and (listp words) (> (length words) 0))
           (format nil "got words=~s"
                   (if (listp words) (length words) "non-list"))))

  (let ((ok (null *failures*)))
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — CJK filename full pipeline works"
                   (format nil "✗ FAIL: ~{~%    ~a~}" *failures*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (ignore-errors (delete-file *cjk-pdf*))
    (when (probe-file "/tmp/.limn/init.lisp.stash-cjk")
      (rename-file "/tmp/.limn/init.lisp.stash-cjk" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
