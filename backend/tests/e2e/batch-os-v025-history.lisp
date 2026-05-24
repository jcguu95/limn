;;;; v0.25 §D — history rings + sidecar persistence OS-tier
;;;;
;;;; Pure-Lisp ring data structure + real filesystem sidecar at
;;;; ~/.limn/history/<slug>.lisp. Tests touch /tmp paths to avoid
;;;; polluting the actual user's history.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   define-history + add-to-history + history-items round-trip
;;;; Ω2   add-to-history skips consecutive duplicates (Emacs convention)
;;;; Ω3   ring overflow at max-size: 5 pushes into size-3 ring → 3 retained
;;;; Ω4   history-sidecar-path strips *…* and lowercases the slug
;;;; Ω5   save-history writes real file to disk; slurp matches ring contents
;;;; Ω6   load-history reads sidecar back into ring
;;;; Ω7   load-history truncates if sidecar longer than max-size
;;;; Ω8   built-in rings *minibuffer-history* / *command-history* /
;;;;       *search-history* exist after module load

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025hi"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-history.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun slurp (path)
  (with-open-file (s path :direction :input :if-does-not-exist :error)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(format t "~%=== batch-os-v025-history ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025hi-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025hi.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1: define + add + items round-trip ─────────────────────────────
  (format t "~%── Ω1: define + add + items ──~%")
  (limn/history:define-history "v025-test" :size 10)
  (limn/history:add-to-history "v025-test" "first")
  (limn/history:add-to-history "v025-test" "second")
  (limn/history:add-to-history "v025-test" "third")
  (let ((items (limn/history:history-items "v025-test")))
    (check (format nil "Ω1 items newest-first (got ~s)" items)
           (equal items '("third" "second" "first"))))

  ;;; ── Ω2: skip consecutive duplicates ─────────────────────────────────
  (format t "~%── Ω2: no consecutive dup ──~%")
  (limn/history:define-history "v025-dup" :size 10)
  (limn/history:add-to-history "v025-dup" "x")
  (limn/history:add-to-history "v025-dup" "x")    ; dup, should NOT add
  (limn/history:add-to-history "v025-dup" "x")    ; dup, should NOT add
  (limn/history:add-to-history "v025-dup" "y")
  (limn/history:add-to-history "v025-dup" "x")    ; non-consecutive, DOES add
  (let ((items (limn/history:history-items "v025-dup")))
    (check (format nil "Ω2 dup collapsed: 3 entries (got ~s)" items)
           (equal items '("x" "y" "x"))))

  ;;; ── Ω3: ring overflow ───────────────────────────────────────────────
  (format t "~%── Ω3: ring overflow ──~%")
  (limn/history:define-history "v025-cap" :size 3)
  (dolist (s '("a" "b" "c" "d" "e"))
    (limn/history:add-to-history "v025-cap" s))
  (let ((items (limn/history:history-items "v025-cap")))
    (check (format nil "Ω3 only 3 newest retained (got ~s)" items)
           (equal items '("e" "d" "c"))))
  (check (format nil "Ω3b history-max-size = 3 (got ~a)"
                 (limn/history:history-max-size "v025-cap"))
         (= (limn/history:history-max-size "v025-cap") 3))

  ;;; ── Ω4: sidecar path ────────────────────────────────────────────────
  (format t "~%── Ω4: history-sidecar-path ──~%")
  (let ((p (limn/history:history-sidecar-path '*minibuffer-history*)))
    (check (format nil "Ω4 path ends with /.limn/history/minibuffer-history.lisp (got ~s)" p)
           (and (stringp p)
                (search ".limn/history/minibuffer-history.lisp" p))))

  ;;; ── Ω5: save-history writes to disk ─────────────────────────────────
  (format t "~%── Ω5: save-history ──~%")
  (let ((side "/tmp/limn-v025-hi-save.lisp"))
    (ignore-errors (delete-file side))
    (limn/history:save-history "v025-test" side)
    (check (format nil "Ω5a sidecar exists at ~a" side)
           (probe-file side))
    (when (probe-file side)
      (let ((content (slurp side)))
        (check (format nil "Ω5b sidecar carries ring items (got ~s)" content)
               ;; readably-written list of strings; loose check
               (and (search "first"  content)
                    (search "second" content)
                    (search "third"  content)))))

    ;;; ── Ω6: load-history round-trip ───────────────────────────────────
    (format t "~%── Ω6: load-history ──~%")
    (limn/history:define-history "v025-load-target" :size 10)
    (limn/history:load-history "v025-load-target" side)
    (let ((items (limn/history:history-items "v025-load-target")))
      (check (format nil "Ω6 reload matches saved (got ~s)" items)
             (equal items '("third" "second" "first"))))
    (ignore-errors (delete-file side)))

  ;;; ── Ω7: load-history truncates ──────────────────────────────────────
  (format t "~%── Ω7: load truncation ──~%")
  ;; Pre-write a sidecar with 5 items, load into a size-2 ring → first 2.
  (let ((side "/tmp/limn-v025-hi-trunc.lisp"))
    (with-open-file (s side :direction :output
                            :if-exists :supersede :if-does-not-exist :create)
      (write '("e" "d" "c" "b" "a") :stream s :readably t))
    (limn/history:define-history "v025-trunc" :size 2)
    (limn/history:load-history "v025-trunc" side)
    (let ((items (limn/history:history-items "v025-trunc")))
      (check (format nil "Ω7 truncated to size 2 (got ~s)" items)
             (equal items '("e" "d"))))
    (ignore-errors (delete-file side)))

  ;;; ── Ω8: built-in rings exist ────────────────────────────────────────
  (format t "~%── Ω8: built-in rings ──~%")
  (check "Ω8a *minibuffer-history* defined"
         (not (null limn/history:*minibuffer-history*)))
  (check "Ω8b *command-history* defined"
         (not (null limn/history:*command-history*)))
  (check "Ω8c *search-history* defined"
         (not (null limn/history:*search-history*)))
  (check (format nil "Ω8d *minibuffer-history* max-size 100 (got ~a)"
                 (limn/history:history-max-size '*minibuffer-history*))
         (= (limn/history:history-max-size '*minibuffer-history*) 100))

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
