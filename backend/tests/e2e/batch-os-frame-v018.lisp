;;;; Batch 28: v0.18.0 frame system — OS-level e2e.
;;;;
;;;; v0.18.0 doesn't actually instantiate a 2nd Qt MainWindow yet
;;;; (that's v0.18.1) — but the wire commands, registry, events, and
;;;; win-split :frame-id routing are all real. This OS-tier driver
;;;; verifies the same against the real binary in container.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-fr"))

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

(defun ok? (r) (eq (getf r :|ok|) t))

(defun frame-list-items ()
  (getf (getf (limn:call "frame/list") :|data|) :|items|))

(defun frame-create-id ()
  (let ((r (limn:call "frame/create")))
    (and (ok? r) (getf (getf r :|data|) :|frame-id|))))

(let* ((sock (format nil "/tmp/limn-e2e-fr-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-fr.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

;;; ── Ω1: baseline frame/list ─────────────────────────────────────

  (format t "~%── Ω1: startup state has f1 ──~%")
  (let* ((items (frame-list-items))
         (f1    (find "f1" items
                      :key (lambda (f) (getf f :|frame-id|))
                      :test #'string=)))
    (check (format nil "Ω1a — frame/list has ≥ 1 entry (got ~a)" (length items))
           (and items (>= (length items) 1)))
    (check (format nil "Ω1b — f1 present (got ~a)" f1) (consp f1))
    (when f1
      (check "Ω1c — f1 is focused"      (eq (getf f1 :|focused|) t))
      (check "Ω1d — f1 contains w1"
             (member "w1" (getf f1 :|win-ids|) :test #'string=))))

;;; ── Ω2: bridge/win-list entries have :frame-id ──────────────────

  (format t "~%── Ω2: win-list entries carry :frame-id ──~%")
  (let* ((entries (getf (limn:call "bridge/win-list") :|data|))
         (w1      (find "w1" entries
                        :key (lambda (w) (getf w :|win-id|))
                        :test #'string=)))
    (check (format nil "Ω2 — w1 has :frame-id == 'f1' (got ~a)"
                   (and w1 (getf w1 :|frame-id|)))
           (and w1 (string= (getf w1 :|frame-id|) "f1"))))

;;; ── Ω3: create / list / close round-trip ────────────────────────

  (format t "~%── Ω3: create → list → close round-trip ──~%")
  (let* ((base (length (frame-list-items)))
         (fid  (frame-create-id)))
    (check (format nil "Ω3a — frame/create returned id (got ~a)" fid)
           (stringp fid))
    (when fid
      (check (format nil "Ω3b — list grew by 1 (~a → ~a)"
                     base (length (frame-list-items)))
             (= (1+ base) (length (frame-list-items))))
      (let ((r (limn:call "frame/close" :|frame-id| fid)))
        (check "Ω3c — close ok" (ok? r)))
      (check (format nil "Ω3d — list back to ~a" base)
             (= base (length (frame-list-items))))))

;;; ── Ω4: frame/close on default f1 refused ───────────────────────

  (format t "~%── Ω4: closing default f1 must fail ──~%")
  (let ((r (limn:call "frame/close" :|frame-id| "f1")))
    (check "Ω4 — close f1 rejected" (not (ok? r))))

;;; ── Ω5: frame/focus switches focused flag ───────────────────────

  (format t "~%── Ω5: frame/focus flips :focused ──~%")
  (let ((fid (frame-create-id)))
    (when fid
      (limn:call "frame/focus" :|frame-id| fid)
      (let* ((items (frame-list-items))
             (foc   (remove-if-not (lambda (f) (getf f :|focused|)) items)))
        (check (format nil "Ω5a — exactly one focused (got ~a)" (length foc))
               (= 1 (length foc)))
        (check (format nil "Ω5b — focused == ~a" fid)
               (and (first foc) (string= (getf (first foc) :|frame-id|) fid))))
      (limn:call "frame/focus" :|frame-id| "f1")
      (limn:call "frame/close" :|frame-id| fid)))

;;; ── Ω6: win-split with :frame-id routes new window ──────────────

  (format t "~%── Ω6: win-split :frame-id puts new win in target frame ──~%")
  (let ((fid (frame-create-id)))
    (when fid
      (let* ((sr (limn:call "bridge/win-split" :|win-id| "w1"
                             :|dir| "h" :|frame-id| fid))
             (new-w (getf (getf sr :|data|) :|win-b|)))
        (check (format nil "Ω6a — split returned new win-id (got ~a)" new-w)
               (stringp new-w))
        (when new-w
          (let* ((items (frame-list-items))
                 (entry (find fid items
                              :key (lambda (f) (getf f :|frame-id|))
                              :test #'string=)))
            (check (format nil "Ω6b — new win in target frame (~a in ~a)"
                           new-w (and entry (getf entry :|win-ids|)))
                   (and entry
                        (member new-w (getf entry :|win-ids|) :test #'string=)))))
        ;; frame/close cascades win-close
        (limn:call "frame/close" :|frame-id| fid))))

;;; ── Ω7: frame-create / frame-close / frame-focus events fire ────

  (format t "~%── Ω7: events fire on wire ──~%")
  (let ((captured nil))
    (limn/hooks:add-hook "event/frame-create"
                         (lambda (ev) (push (cons :create ev) captured)))
    (limn/hooks:add-hook "event/frame-focus"
                         (lambda (ev) (push (cons :focus  ev) captured)))
    (limn/hooks:add-hook "event/frame-close"
                         (lambda (ev) (push (cons :close  ev) captured)))
    (let ((fid (frame-create-id)))
      (sleep 0.2)
      (when fid
        (limn:call "frame/focus" :|frame-id| fid)
        (sleep 0.2)
        (limn:call "frame/focus" :|frame-id| "f1")
        (sleep 0.2)
        (limn:call "frame/close" :|frame-id| fid)
        (sleep 0.3))
      (let ((kinds (mapcar #'car captured)))
        (check (format nil "Ω7a — frame-create event fired (kinds=~a)" kinds)
               (member :create kinds))
        (check "Ω7b — frame-focus event fired" (member :focus kinds))
        (check "Ω7c — frame-close event fired" (member :close kinds)))))

  ;; ── summary ─────────────────────────────────────────────────
  (format t "~%~%── frame-v018 e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
