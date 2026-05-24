;;;; limn-face — defface / theme system, Emacs-compatible.
;;;;
;;;; Pure Lisp. v0.25 §A.
;;;; Faces identified by symbol (name). C++ side consumes
;;;; sync-faces-payload to populate LimnFaceRegistry.

(defpackage #:limn/face
  (:use #:cl)
  (:export #:defface #:set-face-attribute #:face-attribute
           #:face-spec-set
           #:deftheme #:enable-theme #:disable-theme
           #:custom-theme-set-faces
           #:*face-table* #:*enabled-theme*
           #:sync-faces-payload))

(in-package #:limn/face)

;;; *face-table* maps face-symbol → plist of attributes.
;;; Themes are stored as special entries under the theme symbol.
(defvar *face-table* (make-hash-table))

;;; Theme storage: theme-symbol → alist of (face-symbol . attr-plist)
(defvar *theme-faces* (make-hash-table))

;;; Saved defaults (before any theme override)
(defvar *face-defaults* (make-hash-table))

(defvar *enabled-theme* nil)

;;; Canonical attribute keys we recognise
(defparameter *known-attrs*
  '(:foreground :background :bold :italic :underline :strike-through
    :height :family))

;;; ─── internal ─────────────────────────────────────────────────────

(defun %plist-put (plist key value)
  (let ((existing (member key plist)))
    (if existing
        (progn (setf (second existing) value) plist)
        (list* key value plist))))

(defun %face-plist (face)
  (or (gethash face *face-table*) '()))

;;; ─── defface ──────────────────────────────────────────────────────

(defmacro defface (name spec)
  `(progn
     (unless (gethash ,name *face-table*)
       (setf (gethash ,name *face-table*) '()))
     (face-spec-set ,name ,spec)
     ;; Save as default (pre-theme baseline)
     (setf (gethash ,name *face-defaults*)
           (copy-list (gethash ,name *face-table*)))
     ,name))

;;; ─── set-face-attribute / face-attribute ──────────────────────────

(defun set-face-attribute (face attr value)
  (let ((plist (%face-plist face)))
    (setf (gethash face *face-table*)
          (%plist-put plist attr value)))
  (%sync-to-bridge)
  value)

(defun face-attribute (face attr)
  (getf (%face-plist face) attr))

;;; ─── face-spec-set ────────────────────────────────────────────────

(defun face-spec-set (face spec)
  "Replace the face's attribute plist with SPEC (a plist)."
  (setf (gethash face *face-table*) (copy-list spec))
  face)

;;; ─── deftheme / enable-theme / disable-theme ──────────────────────

(defmacro deftheme (name doc)
  (declare (ignore doc))
  `(progn
     (unless (gethash ,name *theme-faces*)
       (setf (gethash ,name *theme-faces*) '()))
     ;; Also register in *face-table* so custom-variable-p etc. can find it
     (setf (gethash ,name *face-table*) (list :theme t))
     ,name))

(defun custom-theme-set-faces (theme &rest face-specs)
  "Associate face overrides with THEME.
   Each face-spec is (face-symbol attr-plist)."
  (setf (gethash theme *theme-faces*)
        (mapcar (lambda (spec)
                  (cons (first spec) (second spec)))
                face-specs)))

(defun enable-theme (theme)
  (setf *enabled-theme* theme)
  (let ((overrides (gethash theme *theme-faces*)))
    (dolist (pair overrides)
      (let ((face (car pair))
            (attrs (cdr pair)))
        (face-spec-set face attrs))))
  (%sync-to-bridge)
  theme)

(defun disable-theme (theme)
  (when (eq *enabled-theme* theme)
    ;; Restore all faces to their pre-theme defaults
    (let ((overrides (gethash theme *theme-faces*)))
      (dolist (pair overrides)
        (let* ((face (car pair))
               (defaults (gethash face *face-defaults*)))
          (setf (gethash face *face-table*)
                (copy-list defaults)))))
    (setf *enabled-theme* nil)
    (%sync-to-bridge))
  theme)

;;; ─── bridge wire-up ───────────────────────────────────────────────

(defun %sync-to-bridge ()
  "Push current face table to C++ via display/sync-faces.
   Graceful no-op when bridge (limn package) is not loaded."
  (let ((pkg (find-package '#:limn)))
    (when pkg
      (let ((call-fn (find-symbol "CALL" pkg)))
        (when call-fn
          (ignore-errors
            (let ((payload (sync-faces-payload)))
              (funcall call-fn "display/sync-faces" :|faces| payload))))))))

;;; ─── display/sync-faces payload ───────────────────────────────────

(defun %attr-string (plist key)
  (let ((v (getf plist key)))
    (when (and v (not (eq v t)) (not (eq v nil)))
      (if (stringp v) v (format nil "~a" v)))))

(defun sync-faces-payload ()
  "Return a list of plists, one per face, for the display/sync-faces wire call.
   Each plist: (:name \"face-name\" :foreground \"#...\" :bold t/nil ...)"
  (let ((result '()))
    (maphash (lambda (face attrs)
               ;; Skip theme meta-entries
               (unless (getf attrs :theme)
                 (push (list :name (string-downcase (symbol-name face))
                             :foreground    (getf attrs :foreground)
                             :background    (getf attrs :background)
                             :bold          (if (getf attrs :bold) t nil)
                             :italic        (if (getf attrs :italic) t nil)
                             :underline     (if (getf attrs :underline) t nil)
                             :strike-through (if (getf attrs :strike-through) t nil)
                             :height        (getf attrs :height)
                             :family        (getf attrs :family))
                       result)))
             *face-table*)
    result))
