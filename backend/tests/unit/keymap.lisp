;;;; Unit tests for limn-keys (Emacs-like keymap)
;;;;
;;;; This test file specifies the keymap API contract:
;;;;
;;;;   (limn-keys:make-keymap) → new empty keymap
;;;;   (limn-keys:define-key keymap key-spec action)
;;;;   (limn-keys:lookup keymap key-spec) → action or nil
;;;;   (limn-keys:lookup-sequence keymap [keys]) → action or :prefix or nil
;;;;
;;;; Key specs are Emacs-style: "j", "C-s", "M-x", "C-x C-s" (space-separated).
;;;;
;;;; Tests live in :limn/unit-test and assume the :limn/keys package exists.

(in-package #:limn/unit-test)

;;; If limn-keys isn't loaded yet, define a stub so tests can at least parse.
;;; They'll fail at runtime — that's the TDD signal.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/keys)
    (defpackage :limn/keys
      (:use :cl)
      (:export #:make-keymap #:define-key #:lookup #:lookup-sequence
               #:parse-key-spec #:keymap-p))))

;;; ── Creation ────────────────────────────────────────────────────────────

(deftest keys-make-keymap-returns-keymap
  (let ((m (limn/keys:make-keymap)))
    (assert-true m "make-keymap returns non-nil")
    (assert-true (limn/keys:keymap-p m) "result is a keymap")))

(deftest keys-empty-keymap-no-bindings
  (let ((m (limn/keys:make-keymap)))
    (assert-eq nil (limn/keys:lookup m "j") "empty keymap returns nil")))

;;; ── Simple key bindings ─────────────────────────────────────────────────

(deftest keys-single-char-binding
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'scroll-down)
    (assert-eq 'scroll-down (limn/keys:lookup m "j"))))

(deftest keys-multiple-bindings
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'scroll-down)
    (limn/keys:define-key m "k" 'scroll-up)
    (limn/keys:define-key m "h" 'scroll-left)
    (limn/keys:define-key m "l" 'scroll-right)
    (assert-eq 'scroll-down  (limn/keys:lookup m "j"))
    (assert-eq 'scroll-up    (limn/keys:lookup m "k"))
    (assert-eq 'scroll-left  (limn/keys:lookup m "h"))
    (assert-eq 'scroll-right (limn/keys:lookup m "l"))))

(deftest keys-rebind-overwrites
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'first)
    (limn/keys:define-key m "j" 'second)
    (assert-eq 'second (limn/keys:lookup m "j"))))

;;; ── Modifiers ───────────────────────────────────────────────────────────

(deftest keys-ctrl-modifier
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-s" 'save)
    (assert-eq 'save (limn/keys:lookup m "C-s"))
    (assert-eq nil   (limn/keys:lookup m "s"))))

(deftest keys-meta-modifier
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "M-x" 'execute-command)
    (assert-eq 'execute-command (limn/keys:lookup m "M-x"))))

(deftest keys-multiple-modifiers
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-M-s" 'isearch-forward-regexp)
    (assert-eq 'isearch-forward-regexp (limn/keys:lookup m "C-M-s"))))

(deftest keys-modifier-order-canonical
  "C-M-s and M-C-s should refer to the same binding."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-M-s" 'foo)
    (assert-eq 'foo (limn/keys:lookup m "M-C-s")
               "M-C-s same as C-M-s")))

;;; ── Sequences (prefix keys) ─────────────────────────────────────────────

(deftest keys-sequence-binding
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-x C-s" 'save-buffer)
    (assert-eq 'save-buffer
               (limn/keys:lookup-sequence m '("C-x" "C-s")))))

(deftest keys-sequence-partial-is-prefix
  "Halfway through a multi-key sequence, lookup returns :prefix."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-x C-s" 'save-buffer)
    (assert-eq :prefix (limn/keys:lookup-sequence m '("C-x"))
               "C-x alone is a prefix")))

(deftest keys-sequence-unknown-returns-nil
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-x C-s" 'save)
    (assert-eq nil (limn/keys:lookup-sequence m '("C-x" "C-q"))
               "C-x C-q is not bound")))

(deftest keys-sequence-three-deep
  "Sequences of arbitrary length are supported."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "C-x 4 b" 'switch-buffer-other-window)
    (assert-eq 'switch-buffer-other-window
               (limn/keys:lookup-sequence m '("C-x" "4" "b")))))

;;; ── Key spec parsing ────────────────────────────────────────────────────

(deftest keys-parse-bare-char
  (let ((parsed (limn/keys:parse-key-spec "j")))
    (assert-true parsed "parses 'j'")))

(deftest keys-parse-modifier-char
  (let ((parsed (limn/keys:parse-key-spec "C-s")))
    (assert-true parsed "parses 'C-s'")))

(deftest keys-parse-named-keys
  "Named keys like 'RET', 'ESC', 'TAB', 'SPC', 'DEL' are recognized."
  (dolist (key '("RET" "ESC" "TAB" "SPC" "DEL" "BS" "<f1>" "<up>" "<down>"))
    (let ((parsed (limn/keys:parse-key-spec key)))
      (assert-true parsed (format nil "parses ~s" key)))))

(deftest keys-parse-invalid-spec
  (assert-error error
                (limn/keys:parse-key-spec "")
                "empty spec signals error"))

;;; ── Action invocation ───────────────────────────────────────────────────
;;;
;;; A keymap binding should be callable. We expose limn-keys:invoke
;;; that looks up + calls the bound function with given args.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/keys)
    (unless (find-symbol "INVOKE" :limn/keys)
      (export (intern "INVOKE" :limn/keys) :limn/keys))
    (unless (find-symbol "DEFINE-PARENT" :limn/keys)
      (export (intern "DEFINE-PARENT" :limn/keys) :limn/keys))
    (unless (find-symbol "DESCRIBE-BINDINGS" :limn/keys)
      (export (intern "DESCRIBE-BINDINGS" :limn/keys) :limn/keys))))

(deftest keys-invoke-calls-action
  "limn/keys:invoke calls the action bound to a key."
  (let ((m (limn/keys:make-keymap))
        (called nil))
    (limn/keys:define-key m "j" (lambda () (setf called t)))
    (limn/keys:invoke m "j")
    (assert-true called "bound action was called")))

(deftest keys-invoke-passes-args
  "invoke passes any extra args to the bound action."
  (let ((m (limn/keys:make-keymap))
        (received nil))
    (limn/keys:define-key m "x" (lambda (&rest args) (setf received args)))
    (limn/keys:invoke m "x" :arg1 42)
    (assert-equal '(:arg1 42) received "args passed through")))

(deftest keys-invoke-unbound-noop-or-error
  "Invoking an unbound key either no-ops or signals — but never silently
   succeeds with a wrong action."
  (let ((m (limn/keys:make-keymap)))
    (handler-case (limn/keys:invoke m "unbound-key")
      (error () (assert-true t "invoke on unbound errored")))))

;;; ── Parent / fallback keymaps ───────────────────────────────────────────
;;;
;;; A keymap can have a parent; lookup falls through to parent if not bound here.

(deftest keys-parent-fallthrough
  (let ((parent (limn/keys:make-keymap))
        (child  (limn/keys:make-keymap)))
    (limn/keys:define-key parent "j" 'parent-scroll)
    (limn/keys:define-parent child parent)
    ;; child doesn't bind 'j' — should fall through to parent
    (assert-eq 'parent-scroll (limn/keys:lookup child "j")
               "child falls through to parent")))

(deftest keys-child-shadows-parent
  "If child binds the same key, child's binding wins."
  (let ((parent (limn/keys:make-keymap))
        (child  (limn/keys:make-keymap)))
    (limn/keys:define-key parent "j" 'parent-action)
    (limn/keys:define-key child  "j" 'child-action)
    (limn/keys:define-parent child parent)
    (assert-eq 'child-action (limn/keys:lookup child "j")
               "child shadows parent")))

;;; ── describe-bindings ───────────────────────────────────────────────────

(deftest keys-describe-bindings-lists-all
  "describe-bindings returns an alist of (key-spec . action) for all bindings."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'scroll-down)
    (limn/keys:define-key m "k" 'scroll-up)
    (let ((bindings (limn/keys:describe-bindings m)))
      (assert-equal 2 (length bindings)
                    "2 bindings listed")
      (assert-true (find "j" bindings :key #'car :test #'string=))
      (assert-true (find "k" bindings :key #'car :test #'string=)))))

;;; ── Key spec edge cases ─────────────────────────────────────────────────

(deftest keys-binding-space-key
  "Space character can be bound (using SPC notation)."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "SPC" 'page-down)
    (assert-eq 'page-down (limn/keys:lookup m "SPC"))))

(deftest keys-binding-uppercase-vs-lowercase
  "Uppercase letter is a different binding than its lowercase form
   (j vs J in Emacs = different keys, J is shift-j)."
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'lower)
    (limn/keys:define-key m "J" 'upper)
    (assert-eq 'lower (limn/keys:lookup m "j"))
    (assert-eq 'upper (limn/keys:lookup m "J"))))

;;; ── Unbinding ────────────────────────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/keys)
    (unless (find-symbol "UNDEFINE-KEY" :limn/keys)
      (export (intern "UNDEFINE-KEY" :limn/keys) :limn/keys))))

(deftest keys-undefine-removes-binding
  (let ((m (limn/keys:make-keymap)))
    (limn/keys:define-key m "j" 'scroll)
    (limn/keys:undefine-key m "j")
    (assert-eq nil (limn/keys:lookup m "j") "binding removed")))

(deftest keys-undefine-unknown-noop
  (let ((m (limn/keys:make-keymap)))
    (assert-no-error (limn/keys:undefine-key m "never-bound")
                     "undefine of unbound key no-error")))

;;; ── Numeric prefix arguments (Emacs C-u style) ──────────────────────────
;;;
;;; This is a more advanced feature. limn-keys may or may not support it
;;; at first; the test documents the API if it does.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/keys)
    (unless (find-symbol "LOOKUP-WITH-PREFIX" :limn/keys)
      (export (intern "LOOKUP-WITH-PREFIX" :limn/keys) :limn/keys))))

(deftest keys-numeric-prefix-arg
  "Some implementations let you pass a numeric prefix argument with a key."
  (let ((m (limn/keys:make-keymap))
        (got nil))
    (limn/keys:define-key m "n" (lambda (&optional arg) (setf got arg)))
    (handler-case
        (limn/keys:lookup-with-prefix m "n" 3)
      (error () nil))
    ;; Not all implementations have this; informational test
    (format t "    info: prefix-arg ~s~%" got)))

;;; ── Lookup performance: 1000 bindings stays fast ───────────────────────

(deftest keys-lookup-many-bindings-fast
  "With 1000 bindings, lookup is still O(1)-ish."
  (let ((m (limn/keys:make-keymap)))
    (loop for i below 1000 do
      (limn/keys:define-key m (format nil "key-~a" i) (intern (format nil "ACTION-~a" i))))
    (let ((start (get-internal-real-time)))
      (loop repeat 1000 do
        (limn/keys:lookup m "key-500"))
      (let ((elapsed (/ (- (get-internal-real-time) start)
                         internal-time-units-per-second)))
        ;; 1000 lookups in a 1000-binding map should be < 100ms easily
        (check-assertion (< elapsed 1.0)
                         "1000 lookups in 1000-binding map < 1s"
                         "took ~,3fs" elapsed)))))

;;; ── Repeated key (auto-repeat scenarios) ──────────────────────────────

(deftest keys-same-key-pressed-twice
  "Pressing the same key twice invokes the action twice."
  (let ((m (limn/keys:make-keymap))
        (count 0))
    (limn/keys:define-key m "j" (lambda () (incf count)))
    (limn/keys:invoke m "j")
    (limn/keys:invoke m "j")
    (assert-equal 2 count "invoked twice")))

;;; ── Multiple keymaps coexist ──────────────────────────────────────────

(deftest keys-multiple-keymaps-independent
  "Two keymaps have completely separate state."
  (let ((m1 (limn/keys:make-keymap))
        (m2 (limn/keys:make-keymap)))
    (limn/keys:define-key m1 "j" 'action-1)
    (limn/keys:define-key m2 "j" 'action-2)
    (assert-eq 'action-1 (limn/keys:lookup m1 "j"))
    (assert-eq 'action-2 (limn/keys:lookup m2 "j"))))
