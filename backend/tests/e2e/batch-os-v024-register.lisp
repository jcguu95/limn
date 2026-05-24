;;;; v0.24 §C — register OS-tier
;;;;
;;;; Spawn real binary, build two text buffers, wire register vtable to
;;;; buffer/* wire calls. Cover all three register types — position,
;;;; string, window-config — plus list/overwrite/error cases.
;;;;
;;;; The strongest OS-tier angle here is *cross-buffer text copy*:
;;;; copy-to-register reads buf-A's text via buffer/text wire, then
;;;; insert-register writes into buf-B via buffer/insert. v0.24's
;;;; window-config is a stub (payload nil, jump no-op) — we test the
;;;; stub behaviour, not real window state.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   set-register / get-register round-trip
;;;; Ω2   point-to-register + jump-to-register — cursor moves via wire
;;;; Ω3   copy-to-register reads text from buf-A via wire
;;;; Ω4   insert-register writes into buf-B (cross-buffer)
;;;; Ω5   list-registers returns alist with all keys
;;;; Ω6   set-register overwrites existing entry
;;;; Ω7   window-configuration-to-register stores stub; jump is no-op
;;;; Ω8   jump-to-register on unset key signals an error
;;;; Ω9   insert-register on non-string register signals an error

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024rg"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-register.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (bid)
  (let ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (bid)
  (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| bid))
            :|offset|)
      0))

(format t "~%=== batch-os-v024-register ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024rg-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024rg.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── wire register vtable ─────────────────────────────────────────────
  (setf limn/register:*buffer-cursor-fn*
        (lambda (b) (buf-cursor b)))
  (setf limn/register:*buffer-set-cursor-fn*
        (lambda (b off)
          (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
  (setf limn/register:*buffer-text-fn*
        (lambda (b from to)
          (subseq (or (buf-text b) "") from to)))
  (setf limn/register:*buffer-insert-fn*
        (lambda (b off str)
          (limn:call "buffer/insert" :|buffer-id| b :|at| off :|text| str)))

  (let* ((r-a (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (a   (and (ok? r-a) (getf (data r-a) :|buffer-id|)))
         (r-b (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (b   (and (ok? r-b) (getf (data r-b) :|buffer-id|))))
    (check "engine-load two text buffers" (and a b))

    (when (and a b)
      (limn:call "buffer/insert" :|buffer-id| a :|at| 0
                  :|text| "Hello world from buf-A")
      (limn:call "buffer/insert" :|buffer-id| b :|at| 0
                  :|text| "buf-B start: ")

      ;; Reset register state for isolation.
      (setf limn/register:*register-alist* '())

      ;;; ── Ω1: set/get round-trip ───────────────────────────────────────
      (format t "~%── Ω1: set/get ──~%")
      (limn/register:set-register #\x (list 'string "arbitrary"))
      (let ((v (limn/register:get-register #\x)))
        (check (format nil "Ω1 get-register returns stored value (got ~s)" v)
               (equal v '(string "arbitrary"))))

      ;;; ── Ω2: point-to-register + jump-to-register ─────────────────────
      (format t "~%── Ω2: point-to-register / jump-to-register ──~%")
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 7)
      (limn/register:point-to-register #\p a)
      ;; Move cursor away.
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 0)
      (limn/register:jump-to-register #\p)
      (let ((c (buf-cursor a)))
        (check (format nil "Ω2 cursor restored to 7 via jump (got ~a)" c)
               (= c 7)))

      ;;; ── Ω3: copy-to-register ─────────────────────────────────────────
      (format t "~%── Ω3: copy-to-register ──~%")
      ;; "Hello world from buf-A" — substring [6, 11) = "world"
      (limn/register:copy-to-register #\c 6 11 a)
      (let ((v (limn/register:get-register #\c)))
        (check (format nil "Ω3 register has (string \"world\") (got ~s)" v)
               (equal v '(string "world"))))

      ;;; ── Ω4: insert-register cross-buffer ─────────────────────────────
      (format t "~%── Ω4: insert-register into buf-B ──~%")
      ;; buf-B = "buf-B start: " (length 13). Move cursor to end and insert.
      (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| 13)
      (limn/register:insert-register #\c b)
      (let ((txt (buf-text b)))
        (check (format nil "Ω4 buf-B has appended \"world\" (got ~s)" txt)
               (equal txt "buf-B start: world")))

      ;;; ── Ω5: list-registers ───────────────────────────────────────────
      (format t "~%── Ω5: list-registers ──~%")
      (let* ((alist (limn/register:list-registers))
             (keys  (mapcar #'car alist)))
        (check (format nil "Ω5 list-registers covers x, p, c (got ~a)" keys)
               (and (member #\x keys :test #'equal)
                    (member #\p keys :test #'equal)
                    (member #\c keys :test #'equal))))

      ;;; ── Ω6: overwrite existing ───────────────────────────────────────
      (format t "~%── Ω6: overwrite ──~%")
      (limn/register:set-register #\x (list 'string "replaced"))
      (let ((v (limn/register:get-register #\x)))
        (check (format nil "Ω6 register x replaced (got ~s)" v)
               (equal v '(string "replaced"))))

      ;;; ── Ω7: window-configuration-to-register stub ───────────────────
      (format t "~%── Ω7: window-config stub ──~%")
      (limn/register:window-configuration-to-register #\w)
      (let ((v (limn/register:get-register #\w)))
        (check (format nil "Ω7a window-config entry has type tag (got ~s)" v)
               (and (consp v) (eq (car v) 'window-config))))
      ;; jump to window-config is a documented no-op in v0.24.
      (limn:call "buffer/cursor-set" :|buffer-id| a :|offset| 9)
      (limn/register:jump-to-register #\w)
      (let ((c (buf-cursor a)))
        (check (format nil "Ω7b jump on window-config is no-op (cursor still 9; got ~a)" c)
               (= c 9)))

      ;;; ── Ω8: jump on unset key signals error ─────────────────────────
      (format t "~%── Ω8: unset key errors ──~%")
      (let ((errored
              (handler-case
                  (progn (limn/register:jump-to-register #\Z) nil)
                (error () t))))
        (check (format nil "Ω8 jump-to-register on unset key signals (errored? ~a)" errored)
               errored))

      ;;; ── Ω9: insert on non-string register errors ────────────────────
      (format t "~%── Ω9: insert-register type-check ──~%")
      ;; Register #\p stores a 'position value (from Ω2). insert-register
      ;; should reject anything that's not a 'string register.
      (let ((errored
              (handler-case
                  (progn (limn/register:insert-register #\p b) nil)
                (error () t))))
        (check (format nil "Ω9 insert-register on 'position errors (errored? ~a)" errored)
               errored))))

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
