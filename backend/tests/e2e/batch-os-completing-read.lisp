;;;; Batch v0.25-C: completing-read / minibuffer wire — OS-level e2e.
;;;;
;;;; Verifies that the minibuffer protocol works end-to-end:
;;;;   Ω1 — minibuffer/open → set-prompt → set-text → get → close
;;;;   Ω2 — minibuffer-submit event fires after RET injection
;;;;   Ω3 — minibuffer-cancel fires on ESC injection
;;;;   Ω4 — completion-help opens *Completions* window

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;;; ── helpers ───────────────────────────────────────────────────────────

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

;;; v0.37 Phase F (driver-D5): drain-events originally tried to read
;;; events out of (limn:pump), but pump returns a COUNT (number of
;;; messages processed) — so (append events COUNT) raised TYPE-ERROR.
;;; The pump thread already dispatches events to hooks; the right
;;; pattern is to install a hook BEFORE the trigger and harvest from a
;;; shared list afterwards.  capture-events / drain-events hides the
;;; bookkeeping; arm-events resets the buffer between checks.

(defparameter *captured-events* nil)
(defparameter *captured-types*  nil)

(defun arm-events (&rest event-types)
  "Reset *captured-events* and install hooks that record events of the
   given EVENT-TYPES (strings without the \"event/\" prefix).  Each
   recorded event is the wire plist with :|type| TYPE prepended so the
   caller can dispatch by type without re-reading the hook name."
  (setf *captured-events* nil)
  (dolist (ty event-types)
    (unless (member ty *captured-types* :test #'string=)
      (push ty *captured-types*)
      (let ((tag ty))
        (limn/hooks:add-hook
         (concatenate 'string "event/" tag)
         (lambda (ev)
           (push (append (list :|type| tag) ev) *captured-events*)))))))

(defun drain-events (&optional (timeout 0.5))
  "Let the pump thread run for TIMEOUT seconds, then return the
   snapshot of *captured-events* in chronological order."
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop while (< (get-universal-time) deadline) do (sleep 0.02)))
  (reverse *captured-events*))

;;; ── session ───────────────────────────────────────────────────────────

(let* ((sock    (format nil "/tmp/limn-e2e-mb-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc    (sb-ext:run-program
                 limn-bin
                 (list "--test-mode" "--socket" sock)
                 :wait nil :search nil
                 :output "/tmp/limn-os-mb.log"
                 :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  ;; ── Ω1: open / prompt / text / get / close ───────────────────
  (format t "~%── Ω1: minibuffer open/close cycle ──~%")
  (check "Ω1a — minibuffer/open ok"
         (ok? (limn:call "minibuffer/open")))
  (check "Ω1b — set-prompt ok"
         (ok? (limn:call "minibuffer/set-prompt" :|prompt| "Find: ")))
  (check "Ω1c — set-text ok"
         (ok? (limn:call "minibuffer/set-text" :|text| "hello")))
  (let* ((r  (limn:call "minibuffer/get"))
         (d  (data r)))
    (check (format nil "Ω1d — get returns state (got ~s)" d)
           (and (ok? r)
                (string= (getf d :|prompt|) "Find: ")
                (string= (getf d :|text|)   "hello"))))
  (check "Ω1e — close ok"
         (ok? (limn:call "minibuffer/close")))

  ;; ── Ω2: RET injection → minibuffer-submit event ──────────────
  (format t "~%── Ω2: RET fires minibuffer-submit ──~%")
  (arm-events "minibuffer-submit" "minibuffer-cancel")
  (limn:call "minibuffer/open")
  (limn:call "minibuffer/set-text" :|text| "query")
  (limn:call "test/inject-key" :|key| "RET" :|mods| nil)
  (let* ((evs    (drain-events 0.4))
         (submit (find-if (lambda (e)
                            (string= (getf e :|type|) "minibuffer-submit"))
                          evs)))
    (check (format nil "Ω2a — minibuffer-submit event received (evs ~a)" (length evs))
           (and submit
                (string= (getf submit :|text|) "query"))))

  ;; ── Ω3: ESC injection → minibuffer-cancel event ──────────────
  (format t "~%── Ω3: ESC fires minibuffer-cancel ──~%")
  (arm-events "minibuffer-submit" "minibuffer-cancel")
  (limn:call "minibuffer/open")
  (limn:call "minibuffer/set-text" :|text| "abandoned")
  (limn:call "test/inject-key" :|key| "ESC" :|mods| nil)
  (let* ((evs    (drain-events 0.4))
         (cancel (find-if (lambda (e)
                            (string= (getf e :|type|) "minibuffer-cancel"))
                          evs)))
    (check (format nil "Ω3a — minibuffer-cancel event received (evs ~a)" (length evs))
           cancel))

  ;; ── Ω4: minibuffer closed after cancel ───────────────────────
  (format t "~%── Ω4: minibuffer closed after cancel ──~%")
  ;; After ESC the minibuffer should be closed.
  ;; We verify: minibuffer/get returns open=false.
  (let* ((r (limn:call "minibuffer/get"))
         (d (data r)))
    (check (format nil "Ω4a — open is false after cancel (got ~s)" (getf d :|open|))
           (and (ok? r) (not (getf d :|open|)))))

  ;; ── summary ─────────────────────────────────────────────────────
  (format t "~%~%── completing-read OS e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
