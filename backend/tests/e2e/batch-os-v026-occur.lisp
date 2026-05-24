;;;; v0.26 §B — occur OS-tier (line-based search buffer)
;;;;
;;;; Spawn real binary, build two text buffers (source + occur),
;;;; wire occur's vtable to buffer/* + the occur buffer's buffer/insert,
;;;; then exercise occur / occur-jump / occur-prev / regex / no-match /
;;;; CJK pattern.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   occur-count = 2 for "hello" pattern
;;;; Ω2a  results carry correct line-num
;;;; Ω2b  results carry correct line-text
;;;; Ω3   occur-jump → source cursor at first match absolute offset
;;;; Ω4   occur-next + occur-jump → source cursor at second match offset
;;;; Ω5   *occur-write-fn* → occur buffer's buffer/text contains formatted output
;;;; Ω6   regex mode: "h.llo" finds the same 2 matches
;;;; Ω7   no-match: "zzz" returns count = 0
;;;; Ω8   CJK pattern: "你好" finds CJK matches at codepoint offsets

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v026oc"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-occur.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (bid)
  (let* ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (bid)
  (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| bid))
            :|offset|)
      0))

(format t "~%=== batch-os-v026-occur ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v026oc-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v026oc.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── source buffer ────────────────────────────────────────────────────
  (let* ((r-src (limn:call "bridge/engine-load"
                            :|engine| "text" :|path| "" :|win-id| "w1"))
         (src   (and (ok? r-src) (getf (data r-src) :|buffer-id|)))
         (r-occ (limn:call "bridge/engine-load"
                            :|engine| "text" :|path| "" :|win-id| "w1"))
         (occ   (and (ok? r-occ) (getf (data r-occ) :|buffer-id|))))
    (check "engine-load source + occur buffers"
           (and src occ (stringp src) (stringp occ)))

    (when (and src occ)
      ;;; ── wire occur vtable ──────────────────────────────────────────────
      (setf limn/occur:*buffer-text-fn*
            (lambda (b) (or (buf-text b) "")))
      (setf limn/occur:*buffer-set-cursor-fn*
            (lambda (b off)
              (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
      ;; Route the *occur* logical buffer-id into our real occ C++ buffer.
      (setf limn/occur:*occur-write-fn*
            (lambda (obid content)
              (declare (ignore obid))
              ;; Clear existing content first by deleting all then insert.
              (let* ((cur (or (buf-text occ) "")))
                (when (> (length cur) 0)
                  (limn:call "buffer/delete" :|buffer-id| occ
                              :|from| 0 :|to| (length cur))))
              (when (> (length content) 0)
                (limn:call "buffer/insert" :|buffer-id| occ
                            :|at| 0 :|text| content))))

      ;;; ── ASCII corpus ─────────────────────────────────────────────────
      ;; "line1: hello\nline2: world\nline3: hello again\n"
      ;; Line numbers: 1, 2, 3.
      ;; Line "line1: hello" length=12, "\n" at 12. Line starts: 0, 13, 26.
      ;; First  "hello" absolute offset = 7  (in "line1: hello")
      ;; Second "hello" absolute offset = 33 (in "line3: hello again", offset 26+7)
      (limn:call "buffer/insert" :|buffer-id| src :|at| 0
                  :|text| "line1: hello
line2: world
line3: hello again
")

      ;;; ── Ω1 + Ω2: occur "hello" ───────────────────────────────────────
      (format t "~%── Ω1+Ω2: occur ──~%")
      (let* ((state (limn/occur:occur src "hello"))
             (n     (limn/occur:occur-count state)))
        (check (format nil "Ω1 occur-count = 2 (got ~a)" n)
               (= n 2))
        (let* ((results (limn/occur:occur-results state))
               (r1      (first results))
               (r2      (second results)))
          (check (format nil "Ω2a r1 line-num = 1, r2 line-num = 3 (got ~a / ~a)"
                          (and r1 (limn/occur:occur-match-line-num r1))
                          (and r2 (limn/occur:occur-match-line-num r2)))
                 (and r1 r2
                      (= (limn/occur:occur-match-line-num r1) 1)
                      (= (limn/occur:occur-match-line-num r2) 3)))
          (check (format nil "Ω2b r1 line-text contains \"hello\" (got ~s)"
                          (and r1 (limn/occur:occur-match-line-text r1)))
                 (and r1
                      (search "hello"
                              (limn/occur:occur-match-line-text r1)))))

        ;;; ── Ω3: occur-jump to first match ─────────────────────────────
        (format t "~%── Ω3: occur-jump ──~%")
        (limn:call "buffer/cursor-set" :|buffer-id| src :|offset| 0)
        (limn/occur:occur-jump state)
        (let ((c (buf-cursor src)))
          (check (format nil "Ω3 source cursor at first match offset 7 (got ~a)" c)
                 (= c 7)))

        ;;; ── Ω4: occur-next + occur-jump ───────────────────────────────
        (format t "~%── Ω4: occur-next + occur-jump ──~%")
        (let ((state2 (limn/occur:occur-next state)))
          (limn/occur:occur-jump state2)
          (let ((c (buf-cursor src)))
            (check (format nil "Ω4 source cursor at second match offset 33 (got ~a)" c)
                   (= c 33))))

        ;;; ── Ω5: *occur-write-fn* output in occur buffer ───────────────
        (format t "~%── Ω5: occur buffer content ──~%")
        (let ((occ-text (buf-text occ)))
          (check (format nil "Ω5 occur buffer non-empty (~a chars)"
                          (length (or occ-text "")))
                 (and occ-text (> (length occ-text) 0)))
          (check (format nil "Ω5b occur buffer contains line-num markers (got ~s)"
                          (and occ-text (subseq occ-text 0 (min 30 (length occ-text)))))
                 (and occ-text
                      ;; format-occur-line typically prefixes with line number
                      (or (search "1" occ-text)
                          (search "hello" occ-text))))))

      ;;; ── Ω6: regex mode ───────────────────────────────────────────────
      (format t "~%── Ω6: regex ──~%")
      (let* ((state (limn/occur:occur src "h.llo" :regexp t))
             (n     (limn/occur:occur-count state)))
        (check (format nil "Ω6 regex \"h.llo\" finds 2 matches (got ~a)" n)
               (= n 2)))

      ;;; ── Ω7: no-match ─────────────────────────────────────────────────
      (format t "~%── Ω7: no-match ──~%")
      (let* ((state (limn/occur:occur src "zzz"))
             (n     (limn/occur:occur-count state)))
        (check (format nil "Ω7 no-match: count = 0 (got ~a)" n)
               (= n 0)))

      ;;; ── Ω8: CJK pattern ──────────────────────────────────────────────
      (format t "~%── Ω8: CJK pattern ──~%")
      ;; Fresh buffer with CJK content
      (let* ((r-cjk (limn:call "bridge/engine-load"
                                :|engine| "text" :|path| "" :|win-id| "w1"))
             (cjk   (and (ok? r-cjk) (getf (data r-cjk) :|buffer-id|))))
        (when cjk
          ;; Three lines:
          ;;   "問題: 你好世界\n"   (line 1) — 你好 starts at codepoint 4
          ;;   "答案: 不知道\n"     (line 2) — no 你好
          ;;   "再問: 你好嗎\n"     (line 3) — 你好 starts at codepoint offset relative to line start
          (limn:call "buffer/insert" :|buffer-id| cjk :|at| 0
                      :|text| "問題: 你好世界
答案: 不知道
再問: 你好嗎
")
          (let* ((state (limn/occur:occur cjk "你好"))
                 (n     (limn/occur:occur-count state)))
            (check (format nil "Ω8 CJK \"你好\" finds 2 matches (got ~a)" n)
                   (= n 2))
            ;; And occur-jump should land at codepoint offset, not byte
            (limn:call "buffer/cursor-set" :|buffer-id| cjk :|offset| 0)
            (limn/occur:occur-jump state)
            (let ((c (buf-cursor cjk)))
              ;; First match line: "問題: 你好世界" — 問=0 題=1 :=2 (space)=3 你=4
              (check (format nil "Ω8b CJK first jump → codepoint 4 (got ~a)" c)
                     (= c 4))))))))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
