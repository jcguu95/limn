;;;; v0.34 — Emacs syntax shim cross-check against system grep (T3)
;;;;
;;;; 真實 limn binary + docker container 內 GNU grep。
;;;;
;;;; 流程：
;;;;   1. 寫一份 fixture text 到 /tmp/v034-grep-fixture.txt
;;;;   2. 在 limn 內把同份內容 set-text 到 text buffer
;;;;   3. 用 re-search-forward 重複呼叫直到 nil、收集所有 match positions
;;;;   4. 在 container 內 grep -cP "\bdefun\b" 同一個 fixture 檔
;;;;   5. 兩個 count 應該完全一致（PCRE 跟 Emacs syntax shim 對 \\<X\\> /
;;;;      \\bXb\\b 的 word boundary 語意應一致）
;;;;
;;;; 這個 test 真正 stress-test 的是 emacs-regex-to-pcre 翻譯正確性：
;;;; 若 \\< / \\> / \\b 翻譯壞了，count 跟 grep 對不起來，馬上 RED。
;;;;
;;;; v0.34 §C 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v034grep"))

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"
             "limn-excursion.lisp"
             "limn-regex.lisp"
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

(defun buf-set-text (buf text)
  "No wire-level set-text. Emulate via cursor-set 0 + insert."
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

;;; ── fixture: 三類測試素材 ───────────────────────────────────────────────
;;;
;;; 1. 'defun' 出現 4 次當 whole word；2 次當 substring（predefun、defunny）
;;; 2. word-bounded 'foo' 出現 3 次
;;; 3. 'bar' 跟 'barbar' / 'rebar' 混搭

(defparameter *fixture-text*
  "(defun foo (x) x)
predefun ignored
defunny not a match
(defun bar (a) a)
   defun standalone
(defun foo (y) y)
foo at start
something foo middle
barbar rebar bar
(defun trailing-defun () nil)
")

(defparameter *fixture-path* "/tmp/v034-grep-fixture.txt")

(defun write-fixture ()
  (with-open-file (out *fixture-path*
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create
                       :external-format :utf-8)
    (write-string *fixture-text* out)))

(defun grep-count (pattern)
  "Use system grep -cP to count matching lines (NOT total matches!).
   We rely on patterns where each match is on its own line context, OR
   we use grep -oP | wc -l to count total matches."
  (let ((out (with-output-to-string (s)
               (sb-ext:run-program
                "/bin/sh"
                (list "-c"
                      (format nil "grep -oP ~s ~a | wc -l"
                              pattern *fixture-path*))
                :search nil :wait t
                :output s :error nil))))
    (parse-integer (string-trim '(#\Newline #\Space #\Tab) out)
                   :junk-allowed t)))

(defun re-search-count (emacs-pattern buf)
  "Loop re-search-forward from point 0; return count of matches."
  (let ((rsf (rsym "RE-SEARCH-FORWARD")))
    (cond
      ((not rsf) nil)
      (t
       (buf-cursor-set buf 0)
       (sleep 0.05)
       (loop with safety = 0
             with n = 0
             while (< safety 200)
             for hit = (funcall rsf emacs-pattern nil t)
             while hit
             do (incf n)
                (incf safety)
             finally (return n))))))

;;; ── session ─────────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v034grep-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v034grep.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (write-fixture)
  (check (format nil "fixture written to ~a (~a bytes)"
                 *fixture-path*
                 (with-open-file (s *fixture-path*) (file-length s)))
         (probe-file *fixture-path*))

  (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER")))
    (when install-bo (funcall install-bo)))

  ;; wire regex vtable to wire layer
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

    (buf-set-text buf *fixture-text*)
    (sleep 0.1)

    ;; ── Round 1: \\<defun\\>  vs  grep -oP "\bdefun\b" ─────────────────────
    (format t "~%── Round 1: \\<defun\\> ──~%")
    (let ((emacs-count (re-search-count "\\<defun\\>" buf))
          (grep-count  (grep-count "\\bdefun\\b")))
      (format t "    limn re-search count = ~a~%" emacs-count)
      (format t "    grep -oP count      = ~a~%" grep-count)
      (check "\\<defun\\> count matches grep \\bdefun\\b"
             (and emacs-count grep-count (= emacs-count grep-count))
             (format nil "limn=~a grep=~a" emacs-count grep-count)))

    ;; ── Round 2: \\bfoo\\b  vs  grep -oP "\bfoo\b" ─────────────────────────
    (format t "~%── Round 2: \\bfoo\\b ──~%")
    (let ((emacs-count (re-search-count "\\bfoo\\b" buf))
          (grep-count  (grep-count "\\bfoo\\b")))
      (format t "    limn re-search count = ~a~%" emacs-count)
      (format t "    grep -oP count      = ~a~%" grep-count)
      (check "\\bfoo\\b count matches grep \\bfoo\\b"
             (and emacs-count grep-count (= emacs-count grep-count))
             (format nil "limn=~a grep=~a" emacs-count grep-count)))

    ;; ── Round 3: \\bbar\\b — must NOT match 'barbar' or 'rebar' ───────────
    (format t "~%── Round 3: \\bbar\\b (boundary stress) ──~%")
    (let ((emacs-count (re-search-count "\\bbar\\b" buf))
          (grep-count  (grep-count "\\bbar\\b")))
      (format t "    limn re-search count = ~a~%" emacs-count)
      (format t "    grep -oP count      = ~a~%" grep-count)
      (check "\\bbar\\b count matches grep \\bbar\\b"
             (and emacs-count grep-count (= emacs-count grep-count))
             (format nil "limn=~a grep=~a" emacs-count grep-count)))

    ;; ── Round 4: \\(defun\\) — group capture syntax cross-check ────────────
    ;; grep -P 不直接支援 \\(...\\) 對應 (...)，所以用 (defun) （PCRE 原生）
    ;; 比對 Emacs \\(defun\\) 翻譯後產出的 group 是否抓得到
    (format t "~%── Round 4: \\(defun\\) groups ──~%")
    (let ((emacs-count (re-search-count "\\(defun\\)" buf))
          (grep-count  (grep-count "(defun)")))
      (format t "    limn re-search count = ~a~%" emacs-count)
      (format t "    grep -oP count      = ~a~%" grep-count)
      (check "Emacs \\(defun\\) count matches PCRE (defun) count"
             (and emacs-count grep-count (= emacs-count grep-count))
             (format nil "limn=~a grep=~a" emacs-count grep-count)))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (ignore-errors (delete-file *fixture-path*))

  (format t "~%── v034 grep cross-check e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
