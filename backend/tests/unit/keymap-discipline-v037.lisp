;;;; v0.37 Phase E — Keymap discipline regression coverage
;;;;
;;;; Asserts that every major-mode module routes key dispatch through
;;;; the limn/keys API and never short-circuits with ad-hoc `(case key
;;;; ...)` or `(cond ((string= key ...))` chains.  Catches anyone who
;;;; later adds a hardcoded bypass.

(in-package #:limn/unit-test)

(defparameter *kdv37-unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil)
  "Directory of this test file.")

(defun %kdv37-path (rel)
  (namestring
   (merge-pathnames rel
                    (merge-pathnames #p"../../" *kdv37-unit-dir*))))

(defun %kdv37-read-file (path)
  "Read PATH as one big string.  NIL if file missing."
  (with-open-file (s path :direction :input :if-does-not-exist nil)
    (when s
      (with-output-to-string (out)
        (loop for line = (read-line s nil nil)
              while line do (write-line line out))))))

;;; ── coverage assertions ─────────────────────────────────────────────────

(deftest keymap-discipline-pdf-mode-uses-keymap-api
  "limn-pdf-mode.lisp builds its keymap via limn/keys:make-keymap and
   populates via define-key (or its %def wrapper)."
  (let ((src (%kdv37-read-file (%kdv37-path "limn-pdf-mode.lisp"))))
    (assert-true src "limn-pdf-mode.lisp readable")
    (when src
      (check (search "limn/keys:make-keymap" src)
             "uses limn/keys:make-keymap" nil)
      (check (or (search "limn/keys:define-key" src)
                 (search "(%def " src))
             "uses define-key or its %def wrapper" nil))))

(deftest keymap-discipline-text-mode-uses-keymap-api
  "limn-text-mode.lisp uses limn/keys API."
  (let ((src (%kdv37-read-file (%kdv37-path "limn-text-mode.lisp"))))
    (assert-true src "limn-text-mode.lisp readable")
    (when src
      (check (search "limn/keys:make-keymap" src)
             "uses limn/keys:make-keymap" nil)
      (check (or (search "limn/keys:define-key" src)
                 (search "(%def-cmd " src))
             "uses define-key or its %def-cmd wrapper" nil))))

;;; ── anti-pattern assertions ─────────────────────────────────────────────
;;;
;;; These check the file's source text doesn't contain known bypass
;;; shapes.  Naive string-search — false positives possible if someone
;;; comments out one of these patterns.  Worth that for catching the
;;; common drift case.

(defparameter *kdv37-key-string-bypass-patterns*
  '("(case key"
    "(case spec"
    "(string= key \""
    "(string= spec \""
    "(equal key \""
    "(equal spec \"")
  "Substrings that, when found in a major-mode source file, indicate
   key-string dispatch outside the keymap.")

(defun %kdv37-find-bypass-patterns (src)
  "Return list of patterns from *kdv37-key-string-bypass-patterns* that
   appear literally in SRC."
  (loop for p in *kdv37-key-string-bypass-patterns*
        when (search p src) collect p))

(deftest keymap-discipline-no-ad-hoc-pdf-mode
  "limn-pdf-mode.lisp has no hardcoded key-string dispatch."
  (let* ((src (%kdv37-read-file (%kdv37-path "limn-pdf-mode.lisp")))
         (hits (and src (%kdv37-find-bypass-patterns src))))
    (check (null hits)
           "no ad-hoc key dispatch in pdf-mode"
           "found patterns: ~s" hits)))

(deftest keymap-discipline-no-ad-hoc-text-mode
  "limn-text-mode.lisp has no hardcoded key-string dispatch."
  (let* ((src (%kdv37-read-file (%kdv37-path "limn-text-mode.lisp")))
         (hits (and src (%kdv37-find-bypass-patterns src))))
    (check (null hits)
           "no ad-hoc key dispatch in text-mode"
           "found patterns: ~s" hits)))

(deftest keymap-discipline-dispatch-walks-stack
  "limn::%dispatch-key walks the mode-buffer keymap stack (minor→major
   then global), so user-customizable bindings actually take effect."
  (let ((src (%kdv37-read-file (%kdv37-path "limn.lisp"))))
    (assert-true src "limn.lisp readable")
    (when src
      (check (search "%dispatch-key" src) "%dispatch-key defined" nil)
      (check (search "%mode-stack-lookup" src) "walks mode stack" nil)
      (check (search "*global-keymap*" src) "falls back to *global-keymap*" nil))))
