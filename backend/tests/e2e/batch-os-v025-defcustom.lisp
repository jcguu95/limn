;;;; v0.25 §G — defcustom + type system + sidecar OS-tier
;;;;
;;;; Pure Lisp + real filesystem. OS-tier value: many type specs,
;;;; :set / :get hooks, customize-save-variable's full
;;;; write-to-sidecar-then-load-back round trip.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   defcustom registers + custom-variable-p + custom-variable-type
;;;; Ω2   defcustom binds the default value into symbol-value
;;;; Ω3   customize-set-variable accepts valid value
;;;; Ω4   customize-set-variable rejects bad type (user-error)
;;;; Ω5a  type 'boolean: t and nil OK
;;;; Ω5b  type 'boolean: integer rejected
;;;; Ω6   type '(choice integer string): both OK; symbol rejected
;;;; Ω7   type '(const :foo): only :foo accepted
;;;; Ω8   type '(repeat integer): list of ints OK; mixed type rejected
;;;; Ω9   :set hook fires; its return value becomes the stored value
;;;; Ω10  :get hook transforms the read
;;;; Ω11  save-customizations writes to disk; load-customizations
;;;;        round-trips through eval

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025dc"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-custom.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(format t "~%=== batch-os-v025-defcustom ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025dc-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025dc.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1 + Ω2: defcustom basics ───────────────────────────────────────
  (format t "~%── Ω1+Ω2: defcustom register + default ──~%")
  (limn/custom:defcustom *v025-int-var* 7 "An integer customisation."
    :type 'integer :group 'v025-test)
  (check "Ω1a custom-variable-p t"
         (limn/custom:custom-variable-p '*v025-int-var*))
  (check (format nil "Ω1b custom-variable-type = integer (got ~s)"
                 (limn/custom:custom-variable-type '*v025-int-var*))
         (eq (limn/custom:custom-variable-type '*v025-int-var*) 'integer))
  (check (format nil "Ω2 default 7 in symbol-value (got ~s)" *v025-int-var*)
         (= *v025-int-var* 7))

  ;;; ── Ω3: customize-set-variable accepts valid ────────────────────────
  (format t "~%── Ω3: set valid value ──~%")
  (limn/custom:customize-set-variable '*v025-int-var* 99)
  (check (format nil "Ω3 value updated to 99 (got ~s)" *v025-int-var*)
         (= *v025-int-var* 99))

  ;;; ── Ω4: customize-set-variable rejects bad type ────────────────────
  (format t "~%── Ω4: bad type rejected ──~%")
  (let ((errored
          (handler-case
              (progn (limn/custom:customize-set-variable '*v025-int-var* "not an int")
                     nil)
            (error () t))))
    (check (format nil "Ω4 string into integer slot signals (got ~s)" errored)
           errored))
  (check (format nil "Ω4b value unchanged after rejected set (got ~s)" *v025-int-var*)
         (= *v025-int-var* 99))

  ;;; ── Ω5: 'boolean ─────────────────────────────────────────────────────
  (format t "~%── Ω5: type boolean ──~%")
  (limn/custom:defcustom *v025-bool-var* t "A bool." :type 'boolean)
  (limn/custom:customize-set-variable '*v025-bool-var* nil)
  (check (format nil "Ω5a nil accepted (got ~s)" *v025-bool-var*) (null *v025-bool-var*))
  (limn/custom:customize-set-variable '*v025-bool-var* t)
  (check (format nil "Ω5b t accepted (got ~s)" *v025-bool-var*) (eq *v025-bool-var* t))
  (let ((errored
          (handler-case
              (progn (limn/custom:customize-set-variable '*v025-bool-var* 42) nil)
            (error () t))))
    (check (format nil "Ω5c integer rejected (errored=~s)" errored) errored))

  ;;; ── Ω6: (choice integer string) ─────────────────────────────────────
  (format t "~%── Ω6: type choice ──~%")
  (limn/custom:defcustom *v025-choice-var* 0 "Choice."
    :type '(choice integer string))
  (limn/custom:customize-set-variable '*v025-choice-var* 5)
  (check (format nil "Ω6a integer 5 OK (got ~s)" *v025-choice-var*)
         (= *v025-choice-var* 5))
  (limn/custom:customize-set-variable '*v025-choice-var* "hello")
  (check (format nil "Ω6b string OK (got ~s)" *v025-choice-var*)
         (equal *v025-choice-var* "hello"))
  (let ((errored
          (handler-case
              (progn (limn/custom:customize-set-variable
                      '*v025-choice-var* :a-symbol)
                     nil)
            (error () t))))
    (check (format nil "Ω6c symbol rejected (errored=~s)" errored) errored))

  ;;; ── Ω7: (const :foo) ────────────────────────────────────────────────
  (format t "~%── Ω7: type const ──~%")
  (limn/custom:defcustom *v025-const-var* :foo "Const :foo."
    :type '(const :foo))
  (limn/custom:customize-set-variable '*v025-const-var* :foo)
  (check (format nil "Ω7a :foo accepted (got ~s)" *v025-const-var*)
         (eq *v025-const-var* :foo))
  (let ((errored
          (handler-case
              (progn (limn/custom:customize-set-variable '*v025-const-var* :bar) nil)
            (error () t))))
    (check (format nil "Ω7b :bar rejected (errored=~s)" errored) errored))

  ;;; ── Ω8: (repeat integer) ────────────────────────────────────────────
  (format t "~%── Ω8: type repeat ──~%")
  (limn/custom:defcustom *v025-rep-var* '(1 2 3) "Repeat int."
    :type '(repeat integer))
  (limn/custom:customize-set-variable '*v025-rep-var* '(4 5 6 7))
  (check (format nil "Ω8a int list OK (got ~s)" *v025-rep-var*)
         (equal *v025-rep-var* '(4 5 6 7)))
  (let ((errored
          (handler-case
              (progn (limn/custom:customize-set-variable
                      '*v025-rep-var* '(1 "mixed" 2))
                     nil)
            (error () t))))
    (check (format nil "Ω8b mixed list rejected (errored=~s)" errored) errored))

  ;;; ── Ω9: :set hook ───────────────────────────────────────────────────
  (format t "~%── Ω9: :set hook ──~%")
  ;; Hook return value becomes the stored value (see limn-custom line 87).
  (let ((hook-called nil))
    (limn/custom:defcustom *v025-set-hook-var* 0 "Set hook test."
      :type 'integer
      :set (lambda (sym value)
             (declare (ignore sym))
             (push :set-fired hook-called)
             (* value 10)))
    (limn/custom:customize-set-variable '*v025-set-hook-var* 3)
    (check (format nil "Ω9a hook fired (log=~s)" hook-called)
           (member :set-fired hook-called))
    (check (format nil "Ω9b stored value = hook return (3 × 10 = 30; got ~s)"
                   *v025-set-hook-var*)
           (= *v025-set-hook-var* 30)))

  ;;; ── Ω10: :get hook ─────────────────────────────────────────────────
  (format t "~%── Ω10: :get hook ──~%")
  ;; customize-set-variable returns (funcall get-fn sym) when :get is set.
  (limn/custom:defcustom *v025-get-hook-var* 0 "Get hook test."
    :type 'integer
    :get (lambda (sym) (1+ (symbol-value sym))))
  (let ((result (limn/custom:customize-set-variable '*v025-get-hook-var* 100)))
    (check (format nil "Ω10 result of set = (get); stored 100, get adds 1 → 101 (got ~s)"
                   result)
           (= result 101)))

  ;;; ── Ω11: save / load round trip ─────────────────────────────────────
  (format t "~%── Ω11: save-customizations + load-customizations ──~%")
  (let ((path "/tmp/limn-v025-dc-custom.lisp"))
    (ignore-errors (delete-file path))
    ;; Save current state.
    (limn/custom:save-customizations path)
    (check (format nil "Ω11a sidecar exists at ~a" path)
           (probe-file path))

    ;; Mutate a var, then load → should restore the saved value.
    (setf *v025-int-var* 12345)
    (limn/custom:load-customizations path)
    (check (format nil "Ω11b *v025-int-var* restored to 99 after load (got ~s)"
                   *v025-int-var*)
           (= *v025-int-var* 99))
    (ignore-errors (delete-file path)))

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
