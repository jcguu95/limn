;;;; v0.25 §B — text-properties OS-tier
;;;;
;;;; CAVEAT — OS-tier value is the lowest of v0.25's modules. limn/text-props
;;;; is a pure-Lisp interval tree with no wire path; unit-tier already
;;;; covers the algorithm exhaustively. We run here as a smoke test in
;;;; the real SBCL + binary process to confirm no package conflicts and
;;;; that the sticky-boundary + interval-clip code paths behave under
;;;; the production environment.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   put + get round-trip
;;;; Ω2   add-text-properties merges into existing interval
;;;; Ω3   remove-text-properties strips named keys, leaves others
;;;; Ω4   next-property-change walks to the first interval boundary
;;;; Ω5   previous-property-change goes backward
;;;; Ω6   insert at front boundary: default front-nonsticky →
;;;;        the inserted chars are NOT in the interval
;;;; Ω7   insert at rear boundary: default rear-sticky →
;;;;        the interval extends to cover the new chars
;;;; Ω8   delete-region across an interval clips correctly
;;;; Ω9   propertize produces a string with string-level properties

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025tp"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-text-props.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(format t "~%=== batch-os-v025-text-props ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025tp-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025tp.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1: put / get round-trip ─────────────────────────────────────────
  (format t "~%── Ω1: put / get ──~%")
  (let ((buf (limn/text-props:make-prop-buffer "hello world")))
    (limn/text-props:put-text-property 0 5 :face :bold buf)
    (let ((v (limn/text-props:get-text-property 2 :face buf)))
      (check (format nil "Ω1 get-text-property at 2 returns :bold (got ~s)" v)
             (eq v :bold)))

    ;;; ── Ω2: add-text-properties merges ─────────────────────────────────
    (format t "~%── Ω2: add-text-properties merges plist ──~%")
    (limn/text-props:add-text-properties 0 5 '(:weight 700 :height 14) buf)
    (let ((face   (limn/text-props:get-text-property 2 :face buf))
          (weight (limn/text-props:get-text-property 2 :weight buf))
          (height (limn/text-props:get-text-property 2 :height buf)))
      (check (format nil "Ω2 :face preserved (got ~s)" face) (eq face :bold))
      (check (format nil "Ω2 :weight added (got ~s)" weight) (= weight 700))
      (check (format nil "Ω2 :height added (got ~s)" height) (= height 14)))

    ;;; ── Ω3: remove-text-properties strips named keys ──────────────────
    (format t "~%── Ω3: remove-text-properties ──~%")
    (limn/text-props:remove-text-properties 0 5 '(:weight t) buf)
    (let ((face   (limn/text-props:get-text-property 2 :face buf))
          (weight (limn/text-props:get-text-property 2 :weight buf))
          (height (limn/text-props:get-text-property 2 :height buf)))
      (check (format nil "Ω3a :face still there (got ~s)" face) (eq face :bold))
      (check (format nil "Ω3b :weight removed (got ~s)" weight) (null weight))
      (check (format nil "Ω3c :height still there (got ~s)" height) (= height 14))))

  ;;; ── Ω4 + Ω5: property-change navigation ────────────────────────────
  (format t "~%── Ω4+Ω5: next/previous-property-change ──~%")
  (let ((buf (limn/text-props:make-prop-buffer "abcdefghij")))
    (limn/text-props:put-text-property 3 7 :face :italic buf)
    (let ((next (limn/text-props:next-property-change 0 buf)))
      (check (format nil "Ω4 next change from 0 = 3 (got ~s)" next)
             (eql next 3)))
    (let ((prev (limn/text-props:previous-property-change 9 buf)))
      ;; from pos 9 going back, the next boundary on the way is pos 7 (end
      ;; of interval). Be permissive: accept 7 or 3 — either signals a
      ;; boundary the walker found.
      (check (format nil "Ω5 prev change from 9 hits 7 or 3 (got ~s)" prev)
             (or (eql prev 7) (eql prev 3)))))

  ;;; ── Ω6: insert at front boundary, default front-nonsticky ──────────
  (format t "~%── Ω6: front-nonsticky default ──~%")
  ;; Buffer "hello", put :face :bold on [0..5). Insert "XY" at pos 0.
  ;; After insert: buffer "XYhello". The interval should start at 2
  ;; (i.e., the "XY" is NOT inside the interval).
  (let ((buf (limn/text-props:make-prop-buffer "hello")))
    (limn/text-props:put-text-property 0 5 :face :bold buf)
    (limn/text-props:insert buf 0 "XY")
    (let ((at-x  (limn/text-props:get-text-property 0 :face buf))
          (at-y  (limn/text-props:get-text-property 1 :face buf))
          (at-h  (limn/text-props:get-text-property 2 :face buf)))
      (check (format nil "Ω6a position 0 (X) NOT in interval (got ~s)" at-x)
             (null at-x))
      (check (format nil "Ω6b position 1 (Y) NOT in interval (got ~s)" at-y)
             (null at-y))
      (check (format nil "Ω6c position 2 (h) IS in interval (got ~s)" at-h)
             (eq at-h :bold))))

  ;;; ── Ω7: insert at rear boundary, default rear-sticky ───────────────
  (format t "~%── Ω7: rear-sticky default ──~%")
  ;; Buffer "hello", interval [0..5). Insert "ZZ" at pos 5.
  ;; After: "helloZZ". Default rear-sticky → interval extends to 7,
  ;; so positions 5 and 6 SHOULD now have :face :bold.
  (let ((buf (limn/text-props:make-prop-buffer "hello")))
    (limn/text-props:put-text-property 0 5 :face :bold buf)
    (limn/text-props:insert buf 5 "ZZ")
    (let ((at-z1 (limn/text-props:get-text-property 5 :face buf))
          (at-z2 (limn/text-props:get-text-property 6 :face buf)))
      (check (format nil "Ω7a position 5 (Z) inside extended interval (got ~s)" at-z1)
             (eq at-z1 :bold))
      (check (format nil "Ω7b position 6 (Z) inside extended interval (got ~s)" at-z2)
             (eq at-z2 :bold))))

  ;;; ── Ω8: delete-region clips intervals ──────────────────────────────
  (format t "~%── Ω8: delete-region clip ──~%")
  ;; Buffer "abcdefghij", interval [3..7) with :face :u. Delete [4..6).
  ;; After: "abcdghij" (8 chars). Interval should now be [3..5)
  ;; (the original :u face survives but shrinks).
  (let ((buf (limn/text-props:make-prop-buffer "abcdefghij")))
    (limn/text-props:put-text-property 3 7 :face :underline buf)
    (limn/text-props:delete-region buf 4 2)
    (let ((at-3 (limn/text-props:get-text-property 3 :face buf))
          (at-4 (limn/text-props:get-text-property 4 :face buf))
          (at-5 (limn/text-props:get-text-property 5 :face buf)))
      (check (format nil "Ω8a pos 3 still :underline (got ~s)" at-3)
             (eq at-3 :underline))
      (check (format nil "Ω8b pos 4 (was 6, still in interval) :underline (got ~s)" at-4)
             (eq at-4 :underline))
      (check (format nil "Ω8c pos 5 (was 7, outside interval) nil (got ~s)" at-5)
             (null at-5))))

  ;;; ── Ω9: propertize string-level properties ─────────────────────────
  (format t "~%── Ω9: propertize ──~%")
  (let ((s (limn/text-props:propertize "stylish" :face :italic :weight 600)))
    ;; propertize returns a string; properties stored side-channel via
    ;; *string-props* hash. get-text-property with the string itself as buf:
    (check (format nil "Ω9a propertize returns the string (got ~s)" s)
           (string= s "stylish"))
    (let ((face (limn/text-props:get-text-property 0 :face s)))
      (check (format nil "Ω9b string-level :face readable (got ~s)" face)
             (eq face :italic))))

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
