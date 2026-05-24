;;;; v0.24 §B — mark / mark-ring OS-tier
;;;;
;;;; Spawn a real binary, build two text buffers, wire mark vtable to
;;;; buffer/cursor wire calls, and additionally install a buffer-modified
;;;; event handler so limn/marker can auto-shift marks across edits.
;;;; Then exercise set-mark / push-mark / pop-mark / exchange-point-and-mark
;;;; / global ring / reset-marks / mark-ring-max trimming.
;;;;
;;;; No Xvfb needed — pure wire-level.
;;;;
;;;; Ω1   set-mark + (mark bid) round-trip
;;;; Ω2   push-mark stores cursor as new current; old current → ring
;;;; Ω3   exchange-point-and-mark — cursor moves to mark via wire
;;;; Ω4   pop-mark — ring head becomes current
;;;; Ω5   marker auto-shifts on buffer/insert (v0.30 integration)
;;;; Ω6   marker auto-shifts on buffer/delete
;;;; Ω7   *mark-ring-max* trimming — overflow drops oldest
;;;; Ω8   global ring across two buffers — pop-global-mark moves cursor
;;;;       on the right buffer
;;;; Ω9   reset-marks clears per-buffer state

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024mk"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-marker.lisp" "limn-mark.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-cursor (bid)
  (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| bid))
            :|offset|)
      0))

(format t "~%=== batch-os-v024-mark ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024mk-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024mk.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── wire mark vtable ─────────────────────────────────────────────────
  (setf limn/mark:*buffer-cursor-fn*
        (lambda (b) (buf-cursor b)))
  (setf limn/mark:*buffer-set-cursor-fn*
        (lambda (b off)
          (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))

  ;;; ── wire buffer-modified handler to limn/marker fixup engines ────────
  ;; C++ emits buffer-modified after each insert/delete (v0.23.1 §D8).
  ;; The runtime layer normally installs this; tests do it explicitly.
  (limn/hooks:add-hook "event/buffer-modified"
    (lambda (ev)
      (let* ((bid (or (getf ev :|buffer-id|) (getf ev :buffer-id)))
             (op  (or (getf ev :|op|)        (getf ev :op)))
             (pos (or (getf ev :|pos|)       (getf ev :pos)))
             (len (or (getf ev :|len|)       (getf ev :len))))
        (cond
          ((or (equal op "insert") (eq op :insert))
           (limn/marker:process-insert bid pos len))
          ((or (equal op "delete") (eq op :delete))
           (limn/marker:process-delete bid pos (+ pos len)))))))

  (let* ((r-a (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (a   (and (ok? r-a) (getf (data r-a) :|buffer-id|)))
         (r-b (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (b   (and (ok? r-b) (getf (data r-b) :|buffer-id|))))
    (check "engine-load two text buffers"
           (and a b (stringp a) (stringp b) (not (equal a b))))

    (when (and a b)
      (limn:call "buffer/insert" :|buffer-id| a :|at| 0
                  :|text| "abcdefghij")  ; 10 chars
      (limn:call "buffer/insert" :|buffer-id| b :|at| 0
                  :|text| "0123456789")

      ;;; ── Ω1: set-mark + mark ──────────────────────────────────────────
      (format t "~%── Ω1: set-mark / mark ──~%")
      (limn/mark:reset-marks a)
      (limn/mark:set-mark 5 a)
      (let ((m (limn/mark:mark a)))
        (check (format nil "Ω1 mark returns 5 (got ~a)" m)
               (= m 5)))

      ;;; ── Ω2: push-mark stores cursor; old current → ring ─────────────
      (format t "~%── Ω2: push-mark ──~%")
      ;; current mark is 5 from Ω1; push at cursor=3 → ring = (5), current = 3
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 3)
      (limn/mark:push-mark a)
      (let ((cur (limn/mark:mark a))
            (ring (limn/mark:mark-ring-for a)))
        (check (format nil "Ω2a current mark = cursor (3) (got ~a)" cur)
               (= cur 3))
        (check (format nil "Ω2b ring head = old mark (5) (got ~a)" ring)
               (equal ring '(5))))

      ;;; ── Ω3: exchange-point-and-mark ─────────────────────────────────
      (format t "~%── Ω3: exchange-point-and-mark ──~%")
      ;; cursor=3, mark=3 (from Ω2). Move cursor to 0 first so swap is visible.
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 0)
      ;; Need a non-zero mark to make the swap visible.
      (limn/mark:set-mark 7 a)
      (limn/mark:exchange-point-and-mark a)
      (let ((cur (buf-cursor a))
            (mk  (limn/mark:mark a)))
        (check (format nil "Ω3a cursor moved to old mark (7) (got ~a)" cur)
               (= cur 7))
        (check (format nil "Ω3b mark now at old cursor (0) (got ~a)" mk)
               (= mk 0)))

      ;;; ── Ω4: pop-mark ─────────────────────────────────────────────────
      (format t "~%── Ω4: pop-mark ──~%")
      (limn/mark:reset-marks a)
      (limn/mark:set-mark 2 a)        ; current = 2
      (limn/mark:push-mark a :pos 4)  ; old 2 → ring, current = 4
      (limn/mark:push-mark a :pos 6)  ; old 4 → ring, current = 6
      (limn/mark:pop-mark a)
      (check (format nil "Ω4 pop-mark restores ring head (current=~a, expect 4)"
                     (limn/mark:mark a))
             (= (limn/mark:mark a) 4))

      ;;; ── Ω5: marker auto-shifts on insert ────────────────────────────
      (format t "~%── Ω5: limn-marker insert shift ──~%")
      ;; Buffer "abcdefghij", set-mark 5 (between 'e' and 'f').
      ;; Insert "XY" at position 0 via wire → C++ emits buffer-modified →
      ;; our hook calls (process-insert bid 0 2) → mark shifts 5 → 7.
      (limn/mark:reset-marks a)
      (limn/marker:reset-markers a)
      (limn/mark:set-mark 5 a)
      (limn:call "buffer/insert" :|buffer-id| a :|at| 0 :|text| "XY")
      (sleep 0.1)  ; let pump thread process buffer-modified
      (let ((m (limn/mark:mark a)))
        (check (format nil "Ω5 mark auto-shifts after insert (5 + 2 = 7, got ~a)" m)
               (= m 7)))

      ;;; ── Ω6: marker auto-shifts on delete ────────────────────────────
      (format t "~%── Ω6: limn-marker delete shift ──~%")
      ;; Buffer now "XYabcdefghij" (12 chars), mark = 7.
      ;; Delete [0,2) ("XY") via wire → mark shifts 7 → 5.
      (limn:call "buffer/delete" :|buffer-id| a :|from| 0 :|to| 2)
      (sleep 0.1)
      (let ((m (limn/mark:mark a)))
        (check (format nil "Ω6 mark auto-shifts after delete (7 - 2 = 5, got ~a)" m)
               (= m 5)))

      ;;; ── Ω7: *mark-ring-max* trimming ────────────────────────────────
      (format t "~%── Ω7: ring trimming ──~%")
      (let ((limn/mark:*mark-ring-max* 3))
        (limn/mark:reset-marks a)
        ;; Push 5 marks; ring should keep only newest 3.
        (limn/mark:set-mark 1 a)
        (limn/mark:push-mark a :pos 2)  ; ring=(1)
        (limn/mark:push-mark a :pos 3)  ; ring=(2 1)
        (limn/mark:push-mark a :pos 4)  ; ring=(3 2 1) full
        (limn/mark:push-mark a :pos 5)  ; ring=(4 3 2) — 1 dropped
        (limn/mark:push-mark a :pos 6)  ; ring=(5 4 3) — 2 dropped
        (let ((ring (limn/mark:mark-ring-for a)))
          (check (format nil "Ω7 ring max 3 retained (got ~a, expect (5 4 3))" ring)
                 (equal ring '(5 4 3)))))

      ;;; ── Ω8: global ring across buffers ──────────────────────────────
      (format t "~%── Ω8: pop-global-mark cross-buffer ──~%")
      (setf limn/mark:*global-mark-ring* '())
      (limn/mark:reset-marks a)
      (limn/mark:reset-marks b)
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 3)
      (limn/mark:push-mark a)         ; global: ((a . 3))
      (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| 8)
      (limn/mark:push-mark b)         ; global: ((b . 8) (a . 3))
      ;; Move cursors away to make the restore visible.
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 0)
      (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| 0)
      (let* ((entry (limn/mark:pop-global-mark))
             (which (car entry)))
        (check (format nil "Ω8a pop-global → top is buf-B (~a == ~a)" which b)
               (equal which b))
        (check (format nil "Ω8b buf-B cursor restored to 8 (got ~a)" (buf-cursor b))
               (= (buf-cursor b) 8)))
      (let* ((entry (limn/mark:pop-global-mark))
             (which (car entry)))
        (check (format nil "Ω8c pop-global → next is buf-A (~a == ~a)" which a)
               (equal which a))
        (check (format nil "Ω8d buf-A cursor restored to 3 (got ~a)" (buf-cursor a))
               (= (buf-cursor a) 3)))

      ;;; ── Ω9: reset-marks ─────────────────────────────────────────────
      (format t "~%── Ω9: reset-marks ──~%")
      (limn/mark:set-mark 4 a)
      (limn/mark:push-mark a :pos 9)
      (limn/mark:reset-marks a)
      (check (format nil "Ω9a current mark cleared (got ~s)" (limn/mark:mark a))
             (null (limn/mark:mark a)))
      (check (format nil "Ω9b ring cleared (got ~s)" (limn/mark:mark-ring-for a))
             (null (limn/mark:mark-ring-for a)))))

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
