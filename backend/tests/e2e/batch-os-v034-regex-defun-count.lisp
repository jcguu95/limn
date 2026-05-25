;;;; v0.34 — regex defun count OS-level e2e (T1)
;;;;
;;;; 真實 limn binary。把一份 source code fixture 插進 text buffer，用
;;;; (limn/regex:re-search-forward "(defun \\([a-z-]+\\)") 抓所有 defun
;;;; 名稱，回的符號數要跟 fixture 寫死的 expected count 對得起來。
;;;;
;;;; 這個 test 驗：
;;;;   1. cl-ppcre vendor 在 production binary 的 SBCL 真的 load 起來
;;;;   2. limn-regex.lisp wire vtable 正確接到 wire layer 的 buffer/text +
;;;;      buffer/cursor-get/set
;;;;   3. Emacs syntax shim (\\(...\\)) 在 OS-tier 上下文裡 round-trip 對
;;;;
;;;; v0.34 §A+B+C+D 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v034defun"))

;; 先試載 vendor cl-ppcre（不存在則 RED catch on §A）
(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

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

(defun buf-set-text (buf text)
  "No wire-level set-text. Emulate via cursor-set 0 + insert (on freshly
   opened empty buffer this is equivalent)."
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

(defun buf-cursor-set (buf off)
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| off))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                            '("search" "--name" "Limn")
                                            :search t :wait t
                                            :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found))
                           0))
          do (return found)
        do (sleep 0.1)))

(defun rpkg () (find-package '#:limn/regex))
(defun rsym (n) (and (rpkg) (find-symbol n (rpkg))))
(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

;;; ── source fixture: 5 defun 名稱 ─────────────────────────────────────────
;;;
;;; expected: foo / bar-baz / qux / hello-world / x
;;; pattern : (defun \\([a-z-]+\\))  → capture group 1 = 名字

(defparameter *src*
  "(defun foo (x) x)
(defun bar-baz () nil)
(let ((y 1)) y)  ; not a defun, not matched
(defun qux (a b) (+ a b))
(defun hello-world () \"hi\")
(defun x () 0)
")

(defparameter *expected-names* '("foo" "bar-baz" "qux" "hello-world" "x"))

;;; ── session ─────────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v034defun-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v034defun.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (check "cl-ppcre vendor package loaded"
         (find-package '#:cl-ppcre))
  (check "limn/regex package loaded"
         (rpkg))

  (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER")))
    (when install-bo (funcall install-bo)))

  ;; ── wire-up limn/regex vtable to real wire layer ───────────────────────
  (when (rpkg)
    (let ((bt    (rsym "*BUFFER-TEXT-FN*"))
          (pt    (rsym "*POINT-FN*"))
          (spt   (rsym "*SET-POINT-FN*"))
          (btlen (rsym "*BUFFER-TEXT-LEN-FN*")))
      (when bt
        (setf (symbol-value bt)
              (lambda (bid)
                (let ((r (limn:call "buffer/text" :|buffer-id| bid)))
                  (and (ok? r) (getf (data r) :|text|))))))
      (when pt
        (setf (symbol-value pt)
              (lambda (bid)
                (let ((r (limn:call "buffer/cursor-get" :|buffer-id| bid)))
                  (and (ok? r) (getf (data r) :|offset|))))))
      (when spt
        (setf (symbol-value spt)
              (lambda (bid off)
                (limn:call "buffer/cursor-set"
                           :|buffer-id| bid :|offset| off))))
      (when btlen
        (setf (symbol-value btlen)
              (lambda (bid)
                (let* ((r (limn:call "buffer/text" :|buffer-id| bid))
                       (t* (and (ok? r) (getf (data r) :|text|))))
                  (if (stringp t*) (length t*) 0)))))))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))
    (unless buf
      (limn:stop) (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc) (sb-ext:exit :code 2))

    (when (xpkg)
      (let ((reg (xsym "REGISTER-BUFFER"))
            (set-buf (xsym "SET-BUFFER")))
        (when reg (funcall reg (list :|buffer-id| buf) buf :name buf))
        (when set-buf (funcall set-buf buf))))

    (buf-set-text buf *src*)
    (sleep 0.1)
    (buf-cursor-set buf 0)
    (sleep 0.1)

    ;; ── 主驗證：迭代 re-search-forward + match-string 1 收集所有 defun ──

    (format t "~%── 迭代 re-search-forward \"(defun \\\\([a-z-]+\\\\))\" ──~%")
    (let ((rsf (rsym "RE-SEARCH-FORWARD"))
          (ms  (rsym "MATCH-STRING"))
          (names '()))
      (cond
        ((not (and rsf ms))
         (check "limn/regex API present" nil "RED — re-search-forward / match-string missing"))
        (t
         (loop with safety = 0
               while (< safety 50)
               for hit = (funcall rsf "(defun \\([a-z-]+\\)" nil t)
               while hit
               do (push (funcall ms 1) names)
                  (incf safety))
         (setf names (reverse names))
         (format t "    collected: ~a~%" names)
         (check (format nil "expected ~a names, got ~a"
                        (length *expected-names*) (length names))
                (= (length *expected-names*) (length names)))
         (check "names match expected (set equal)"
                (and (every (lambda (n) (member n names :test #'string=))
                            *expected-names*)
                     (every (lambda (n) (member n *expected-names* :test #'string=))
                            names))))))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (format t "~%── v034 defun count e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
