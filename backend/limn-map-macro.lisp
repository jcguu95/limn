;;;; limn-map-macro — Doom-style map! macro (v0.28 §B).
;;;;
;;;; Pure-Lisp macro sugar over limn/keys:define-key.  No new runtime
;;;; state — all forms expand to a series of define-key calls.
;;;;
;;;; Usage:
;;;;   (map! :map km
;;;;     "j" #'down  "k" #'up)
;;;;
;;;;   (map! :map km :prefix "g"
;;;;     "g" #'first  "G" #'last)
;;;;
;;;;   (map! :mode 'pdf-mode
;;;;     "n" #'next-page)
;;;;
;;;;   (map! :leader
;;;;     "f f" #'find-file  "b b" #'switch-to-buffer)
;;;;
;;;; Options must appear before the alternating key/action pairs.

(defpackage #:limn/map-macro
  (:use #:cl)
  (:export #:map!))

(in-package #:limn/map-macro)

;;; ── compile-time helpers ─────────────────────────────────────────────────

(defun %parse-args (args)
  "Returns (values TARGET-FORM PREFIX-FORM PAIRS ERROR-STRING).
   ERROR-STRING (string) signals that the expansion should generate a
   runtime (error ...) rather than try to walk pairs — used so that
   tests can assert-error on malformed map! invocations."
  (let ((map-form nil)
        (mode-form nil)
        (leader-p nil)
        (prefix-form nil)
        (saw-map nil)
        (rest args))
    ;; Consume options up to the first non-keyword
    (loop while (and rest (keywordp (car rest))) do
      (let ((kw (pop rest)))
        (case kw
          (:map     (setf map-form  (pop rest)) (setf saw-map t))
          (:mode    (setf mode-form (pop rest)))
          (:leader  (setf leader-p  t))
          (:prefix  (setf prefix-form (pop rest)))
          (t (return-from %parse-args
               (values nil nil nil
                       (format nil "map!: unknown option ~s" kw)))))))
    (when (and saw-map leader-p)
      (return-from %parse-args
        (values nil nil nil "map!: :map and :leader are mutually exclusive")))
    (let ((target
            (cond (leader-p   'limn/keys:*leader-keymap*)
                  (saw-map    map-form)
                  (mode-form  `(limn/mode:mode-keymap
                                 (limn/mode:find-mode ,mode-form)))
                  (t (return-from %parse-args
                       (values nil nil nil
                               "map!: missing :map / :mode / :leader"))))))
      (values target prefix-form rest nil))))

;;; ── macro ────────────────────────────────────────────────────────────────

(defmacro map! (&rest args)
  (multiple-value-bind (target prefix pairs err)
      (%parse-args args)
    (cond
      (err `(error ,err))
      ;; Odd number of key/action pairs is user error → defer to runtime
      ((oddp (length pairs))
       `(error "map!: odd number of key/action forms"))
      (t
       (let ((km-sym   (gensym "KM"))
             (pre-sym  (gensym "PRE")))
         `(let ((,km-sym  ,target)
                (,pre-sym ,prefix))
            (when (null ,km-sym)
              (error "map!: target keymap is nil"))
            ,@(loop for (key action) on pairs by #'cddr
                    collect `(limn/keys:define-key
                                 ,km-sym
                                 (%maybe-prefix ,pre-sym ,key)
                                 ,action))
            ,km-sym))))))

(defun %maybe-prefix (pre key)
  "Prepend PRE + space to KEY, unless PRE is nil or empty string."
  (if (or (null pre) (zerop (length pre)))
      key
      (concatenate 'string pre " " key)))
