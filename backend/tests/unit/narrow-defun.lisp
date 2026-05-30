;;;; v0.40 §2.4 — narrow-to-defun tests.
;;;;
;;;; find-defun-bounds walks top-level Lisp forms via the host SBCL
;;;; reader, returning (values START END) of the form containing POINT
;;;; or (values nil nil) when POINT falls between forms.

(in-package #:limn/unit-test)

(defun %fdb (text point)
  (multiple-value-list (limn/excursion:find-defun-bounds text point)))

;;; ─────────────────────────────────────────────────────────────────────
;;; Single form
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-single-form-point-inside
  "(defun foo () 1)  point=8 inside → bounds = (0 . 17)。"
  (let* ((text "(defun foo () 1)")
         (r (%fdb text 8)))
    (assert-equal (list 0 (length text)) r
                  "single form covers whole text")))

(deftest narrow-defun-single-form-point-at-start
  "point=0 at form start 仍然算在 form 內。"
  (let* ((text "(defun foo () 1)")
         (r (%fdb text 0)))
    (assert-equal (list 0 (length text)) r "start: included")))

(deftest narrow-defun-single-form-point-at-end
  "point=end 算 form 內。"
  (let* ((text "(defun foo () 1)")
         (r (%fdb text (length text))))
    (assert-equal (list 0 (length text)) r "end: included")))

;;; ─────────────────────────────────────────────────────────────────────
;;; Multiple forms — walking
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-multiple-forms-second-form
  "兩個 form，point 在第二個 → 回第二個的 bounds。"
  ;; "(defun a () 1)\n(defun b () 2)"
  ;;  0             14 15             29
  (let* ((text (format nil "(defun a () 1)~%(defun b () 2)"))
         (r (%fdb text 20)))
    (assert-equal '(15 29) r "second form at [15, 29)")))

(deftest narrow-defun-multiple-forms-first-form
  "point 在第一個 form → 回第一個的 bounds。"
  (let* ((text (format nil "(defun a () 1)~%(defun b () 2)"))
         (r (%fdb text 5)))
    (assert-equal '(0 14) r "first form at [0, 14)")))

;;; ─────────────────────────────────────────────────────────────────────
;;; Between forms → nil/nil
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-point-between-forms-nil
  "point 在 whitespace between forms → no defun。"
  (let* ((text (format nil "(defun a () 1)~%~%~%(defun b () 2)"))
         (r (%fdb text 16)))   ; in the empty-line gap
    (assert-equal '(nil nil) r "between forms: nil/nil")))

(deftest narrow-defun-empty-text-nil
  "空字串 → nil/nil。"
  (assert-equal '(nil nil) (%fdb "" 0) "empty: nil/nil"))

(deftest narrow-defun-only-whitespace-nil
  "只有 whitespace → nil/nil。"
  (assert-equal '(nil nil) (%fdb "   " 1) "whitespace only: nil/nil"))

;;; ─────────────────────────────────────────────────────────────────────
;;; Comments don't confuse walking
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-line-comment-skipped
  "line comment 中間 → 走到下一個 form。"
  ;; ";; hi\n(defun b () 2)"
  (let* ((text (format nil ";; hi~%(defun b () 2)"))
         (r (%fdb text 10)))
    (assert-equal (list 6 (length text)) r
                  "skipped comment, found defun b")))

(deftest narrow-defun-block-comment-skipped
  "block comment #| ... |# 中間 → 也跳過。"
  (let* ((text "#| ignore |#(defun c () 3)")
         (r (%fdb text 15)))
    (assert-equal (list 12 (length text)) r
                  "skipped block comment, found defun c")))

(deftest narrow-defun-nested-block-comment
  "巢狀 #| ... #| ... |# ... |# 也正確平衡。"
  (let* ((text "#| a #| b |# c |#(defun d () 4)")
         (r (%fdb text 20)))
    (assert-equal (list 17 (length text)) r
                  "nested block comment closed correctly")))

;;; ─────────────────────────────────────────────────────────────────────
;;; Malformed input — graceful nil/nil
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-unbalanced-paren-nil
  "壞掉的 form (parser error) → nil/nil 不 unwind。"
  (assert-equal '(nil nil) (%fdb "(defun broken (" 5)
                "parser error: nil/nil"))

;;; ─────────────────────────────────────────────────────────────────────
;;; Defcommand registration + keymap binding
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-defun-cmd-registered
  "cl-user::narrow-to-defun 已註冊為 defcommand。"
  (%ensure-narrow-defaults-registered)
  (let* ((sym (find-symbol "NARROW-TO-DEFUN" :cl-user))
         (cmd (and sym (limn/cmd:find-command sym))))
    (check (not (null sym))
           "NARROW-TO-DEFUN symbol present in :cl-user" nil)
    (check (not (null cmd))
           "NARROW-TO-DEFUN registered as defcommand" nil)))

(deftest narrow-defun-keymap-c-x-n-d
  "install-defaults binds C-x n d on the global keymap."
  (let* ((dc-pkg (find-package '#:limn/default-config))
         (install (and dc-pkg (find-symbol "INSTALL-DEFAULTS" dc-pkg)))
         (km (limn/keys:make-keymap)))
    (when install
      (funcall (symbol-function install) km)
      (let ((nd (limn/keys:lookup-sequence km '("C-x" "n" "d"))))
        (check (functionp nd) "C-x n d bound on keymap" nil)))))
