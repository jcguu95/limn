;;;; v0.26 §A — isearch OS-tier (incremental search)
;;;;
;;;; Spawn a real limn binary, create a text buffer via wire, wire the
;;;; isearch I/O vtable to buffer/* wire calls + limn/history. Exercise
;;;; the full state machine: start / update / next / prev / abort / exit,
;;;; plus case-fold and CJK to catch codepoint-vs-byte regressions.
;;;;
;;;; No Xvfb needed — pure wire-level (isearch dispatches no key events).
;;;;
;;;; Ω1   isearch-start → saved-cursor matches initial cursor
;;;; Ω2a  isearch-update "hello" → matches found (count = 2)
;;;; Ω2b  isearch-update "hello" → cursor moved to first match offset
;;;; Ω3   isearch-next → cursor at second match
;;;; Ω4   isearch-prev → cursor back at first match
;;;; Ω5   isearch-abort → cursor restored to saved-cursor
;;;; Ω6a  isearch-exit → state inactive
;;;; Ω6b  isearch-exit → query pushed into limn/history search ring
;;;; Ω7   case-fold off → "HELLO" finds no match (zero count)
;;;; Ω8   CJK search → codepoint-correct match offsets

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v026is"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-history.lisp" "limn-isearch.lisp"))
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

(format t "~%=== batch-os-v026-isearch ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v026is-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v026is.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  (let* ((r   (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (bid (and (ok? r) (getf (data r) :|buffer-id|))))
    (check "engine-load text → buffer-id" (and bid (stringp bid)))

    (when bid
      ;;; ── wire isearch vtable ───────────────────────────────────────────
      (setf limn/isearch:*buffer-text-fn*
            (lambda (b) (or (buf-text b) "")))
      (setf limn/isearch:*buffer-cursor-fn*
            (lambda (b) (buf-cursor b)))
      (setf limn/isearch:*buffer-set-cursor-fn*
            (lambda (b off)
              (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
      (setf limn/isearch:*highlight-fn*
            (lambda (b spans face) (declare (ignore b spans face))))
      (setf limn/isearch:*clear-highlights-fn*
            (lambda (b) (declare (ignore b))))
      (setf limn/isearch:*history-push-fn*
            (lambda (q) (limn/history:add-to-history "search-isearch-os" q)))

      ;;; ── ASCII corpus: "hello world\nhello again\ngoodbye\n" ───────────
      ;; codepoint offsets:
      ;;   "hello world\n"   = 0..11  (h=0, second 'l'=2, ..., 'd'=10, \n=11)
      ;;   "hello again\n"   = 12..23 (h=12, ..., 'n'=22, \n=23)
      ;;   "goodbye\n"       = 24..31
      ;;
      ;; First  "hello" match starts at codepoint 0.
      ;; Second "hello" match starts at codepoint 12.
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0
                  :|text| "hello world
hello again
goodbye
")
      ;; place cursor at start
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)

      ;;; ── Ω1: isearch-start ─────────────────────────────────────────────
      (format t "~%── Ω1: isearch-start ──~%")
      (let ((st (limn/isearch:isearch-start bid)))
        (check (format nil "Ω1 saved-cursor = 0 (got ~a)"
                       (limn/isearch:isearch-saved-cursor st))
               (= (limn/isearch:isearch-saved-cursor st) 0))

        ;;; ── Ω2: isearch-update "hello" ────────────────────────────────
        (format t "~%── Ω2: isearch-update ──~%")
        (let* ((st2 (limn/isearch:isearch-update st "hello"))
               (matches (limn/isearch:isearch-matches st2)))
          (check (format nil "Ω2a matches count = 2 (got ~a)" (length matches))
                 (= (length matches) 2))
          (let ((c (buf-cursor bid)))
            (check (format nil "Ω2b cursor at first match offset 0 (got ~a)" c)
                   (= c 0)))

          ;;; ── Ω3: isearch-next ────────────────────────────────────────
          (format t "~%── Ω3: isearch-next ──~%")
          (let* ((st3 (limn/isearch:isearch-next st2))
                 (c   (buf-cursor bid)))
            (declare (ignorable st3))
            (check (format nil "Ω3 cursor at second match offset 12 (got ~a)" c)
                   (= c 12))

            ;;; ── Ω4: isearch-prev ──────────────────────────────────────
            (format t "~%── Ω4: isearch-prev ──~%")
            (let* ((st4 (limn/isearch:isearch-prev st3))
                   (c   (buf-cursor bid)))
              (declare (ignorable st4))
              (check (format nil "Ω4 cursor back at first match offset 0 (got ~a)" c)
                     (= c 0))

              ;;; ── Ω5: isearch-abort ───────────────────────────────────
              ;; Move cursor away from saved (0) by using "next" first so
              ;; abort has somewhere to restore from.
              (format t "~%── Ω5: isearch-abort ──~%")
              ;; Advance to second match, then abort — abort should restore
              ;; cursor to saved-cursor (which is 0, where we started).
              (let* ((st4b (limn/isearch:isearch-next st4)))
                (limn/isearch:isearch-abort st4b)
                (let ((c (buf-cursor bid)))
                  (check (format nil "Ω5 cursor restored to saved 0 (got ~a)" c)
                         (= c 0)))))))

        ;;; ── Ω6: isearch-exit + history push ────────────────────────────
        (format t "~%── Ω6: isearch-exit + history ──~%")
        (let* ((st-exit-start (limn/isearch:isearch-start bid))
               (st-exit-upd   (limn/isearch:isearch-update st-exit-start "hello")))
          (limn/isearch:isearch-exit st-exit-upd)
          (check "Ω6a state inactive after exit"
                 (not (limn/isearch:isearch-active-p st-exit-upd)))
          (let ((hist (limn/history:history-items "search-isearch-os")))
            (check (format nil "Ω6b query pushed to history (items=~a)" hist)
                   (member "hello" hist :test #'equal)))))

      ;;; ── Ω7: case-fold off ────────────────────────────────────────────
      (format t "~%── Ω7: case-fold off ──~%")
      (let ((limn/isearch:*isearch-case-fold* nil))
        (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
        (let* ((st (limn/isearch:isearch-start bid))
               (st2 (limn/isearch:isearch-update st "HELLO"))
               (n   (length (limn/isearch:isearch-matches st2))))
          (check (format nil "Ω7 case-fold off: \"HELLO\" finds 0 matches (got ~a)" n)
                 (= n 0))))

      ;;; ── Ω8: CJK search (codepoint correctness) ───────────────────────
      ;; Build CJK corpus "你好世界你好" in a fresh buffer.
      ;; codepoint offsets: 你=0 好=1 世=2 界=3 你=4 好=5
      ;; "你好" matches at positions 0 and 4 (NOT 0 and 12 — codepoint, not byte).
      (format t "~%── Ω8: CJK search ──~%")
      (let* ((r2 (limn:call "bridge/engine-load"
                             :|engine| "text" :|path| "" :|win-id| "w1"))
             (bid2 (and (ok? r2) (getf (data r2) :|buffer-id|))))
        (when bid2
          (limn:call "buffer/insert" :|buffer-id| bid2 :|at| 0 :|text| "你好世界你好")
          (limn:call "buffer/cursor-set" :|buffer-id| bid2 :|offset| 0)
          (let* ((st  (limn/isearch:isearch-start bid2))
                 (st2 (limn/isearch:isearch-update st "你好"))
                 (matches (limn/isearch:isearch-matches st2)))
            (check (format nil "Ω8a CJK matches count = 2 (got ~a)" (length matches))
                   (= (length matches) 2))
            (let ((c (buf-cursor bid2)))
              (check (format nil "Ω8b cursor at codepoint 0 (got ~a)" c)
                     (= c 0)))
            (let* ((st3 (limn/isearch:isearch-next st2))
                   (c   (buf-cursor bid2)))
              (declare (ignorable st3))
              (check (format nil "Ω8c next → codepoint 4, not byte offset (got ~a)" c)
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
