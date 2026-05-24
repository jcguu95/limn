;;;; v0.25 §G — defcustom / customize RED tests  (~14 tests)
;;;;
;;;; Tests cover: variable definition, :set/:get hooks,
;;;; customize-set-variable, save/load roundtrip, and :type validation.
;;;; All RED until limn/custom is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/custom)
    (make-package '#:limn/custom :use '(#:cl)))
  (dolist (sym '("DEFCUSTOM" "CUSTOMIZE-SET-VARIABLE" "CUSTOMIZE-SAVE-VARIABLE"
                 "CUSTOM-VARIABLE-P" "CUSTOM-VARIABLE-TYPE"
                 "SAVE-CUSTOMIZATIONS" "LOAD-CUSTOMIZATIONS"))
    (let ((s (intern sym '#:limn/custom)))
      (export s '#:limn/custom))))

(in-package #:limn/unit-test)

;;; ─── G1. defcustom definition ────────────────────────────────────

(limn/custom:defcustom *test-custom-g1* 42
  "A test custom variable with integer type."
  :type 'integer
  :group 'test-group)

(deftest defcustom-g1-defines-variable-with-default
  (assert-equal 42 *test-custom-g1*
                "defcustom should set initial value"))

(deftest defcustom-g1-variable-is-custom-variable
  (assert-true (limn/custom:custom-variable-p '*test-custom-g1*)
               "defcustom symbol should be recognized as custom variable"))

(deftest defcustom-g1-type-stored
  (assert-equal 'integer
                (limn/custom:custom-variable-type '*test-custom-g1*)
                "defcustom :type should be stored and retrievable"))

;;; ─── G2. customize-set-variable ──────────────────────────────────

(limn/custom:defcustom *test-custom-g2* "original"
  "A string custom variable."
  :type 'string)

(deftest defcustom-g2-customize-set-variable-changes-value
  (limn/custom:customize-set-variable '*test-custom-g2* "changed")
  (assert-equal "changed" *test-custom-g2*))

(deftest defcustom-g2-set-hook-fires
  (let ((hook-fired nil))
    (limn/custom:defcustom *test-custom-set-hook* 0
      "Fires :set hook."
      :type 'integer
      :set (lambda (_sym val)
             (setf hook-fired val)
             val))
    (limn/custom:customize-set-variable '*test-custom-set-hook* 99)
    (assert-equal 99 hook-fired ":set hook should have fired with new value")))

(deftest defcustom-g2-get-hook-transforms-on-read
  (limn/custom:defcustom *test-custom-get-hook* 5
    "Fires :get hook."
    :type 'integer
    :get (lambda (_sym) (* *test-custom-get-hook* 2)))
  (assert-equal 10 (limn/custom:customize-set-variable '*test-custom-get-hook* 5)
                ":get hook should transform value on read"))

;;; ─── G3. type validation ──────────────────────────────────────────

(limn/custom:defcustom *test-custom-bool* t
  "Boolean custom variable."
  :type 'boolean)

(deftest defcustom-g3-boolean-accepts-nil-and-t
  (assert-no-error (limn/custom:customize-set-variable '*test-custom-bool* nil))
  (assert-no-error (limn/custom:customize-set-variable '*test-custom-bool* t)))

(deftest defcustom-g3-integer-rejects-string
  (limn/custom:defcustom *test-custom-int-type* 0 "int" :type 'integer)
  (assert-error error
    (limn/custom:customize-set-variable '*test-custom-int-type* "not-an-int")
    "integer type should reject a string (user-error)"))

(deftest defcustom-g3-choice-type-validates-members
  (limn/custom:defcustom *test-custom-choice* :low
    "Choice custom variable."
    :type '(choice (const :low) (const :medium) (const :high)))
  (assert-no-error
    (limn/custom:customize-set-variable '*test-custom-choice* :medium))
  (assert-error error
    (limn/custom:customize-set-variable '*test-custom-choice* :invalid)
    "choice type should reject value outside members"))

(deftest defcustom-g3-hook-type-accepts-function-list
  (limn/custom:defcustom *test-custom-hook* nil
    "Hook custom variable."
    :type 'hook)
  (assert-no-error
    (limn/custom:customize-set-variable '*test-custom-hook*
                                        (list (lambda () nil)))))

;;; ─── G4. save / load roundtrip ───────────────────────────────────

(deftest defcustom-g4-save-load-roundtrip
  (let ((tmp (merge-pathnames "limn-custom-test.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR") "/tmp/")))))
    (limn/custom:defcustom *test-custom-persist* "before"
      "Persist test." :type 'string)
    (limn/custom:customize-set-variable '*test-custom-persist* "after")
    (limn/custom:save-customizations tmp)
    ;; Reset to default, then reload
    (setf *test-custom-persist* "before")
    (limn/custom:load-customizations tmp)
    (assert-equal "after" *test-custom-persist*
                  "value should survive save/load")
    (when (probe-file tmp) (delete-file tmp))))
