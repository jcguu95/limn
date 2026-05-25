;;;; limn-keys — Emacs-like keymap.
;;;;
;;;; A keymap is a hash from key-string → action OR sub-keymap (for prefix
;;;; keys). Lookup of a single key returns action / :prefix / nil.
;;;; Lookup of a sequence walks the prefix chain.
;;;;
;;;; Keys parsed from Emacs-style strings: "j", "C-s", "M-x", "RET", "SPC".
;;;; Modifier order is canonicalized so "C-M-s" and "M-C-s" are the same.

(defpackage #:limn/keys
  (:use #:cl)
  (:export #:make-keymap #:define-key #:lookup #:lookup-sequence
           #:parse-key-spec #:keymap-p #:keymap-parent
           #:invoke #:define-parent #:describe-bindings
           #:undefine-key
           #:lookup-with-prefix
           ;; v0.19 β
           #:*key-prefix* #:set-key-prefix
           #:*transient-keymap* #:set-transient-map
           ;; v0.28 — leader key + leader keymap
           #:*leader-key* #:*leader-keymap*))

(in-package #:limn/keys)

(defstruct keymap
  (bindings (make-hash-table :test 'equal))   ; canonical-key → action OR sub-keymap
  parent)                                       ; parent keymap, or nil

;;; ── key spec canonicalization ──────────────────────────────────────────

(defun canonical-key (spec)
  "Sort modifiers alphabetically so 'C-M-s' and 'M-C-s' map to the same string."
  (let* ((parts (split-on-dash spec))
         (base  (car (last parts)))
         (mods  (sort (butlast parts) #'string<)))
    (if mods
        (format nil "~{~a-~}~a" mods base)
        base)))

(defun split-on-dash (s)
  "Split 'C-M-s' into ('C' 'M' 's')."
  (split-string-on s #\-))

(defun split-string-on (s ch)
  (loop with start = 0
        with result = '()
        for i from 0 below (length s)
        when (char= (char s i) ch)
          do (push (subseq s start i) result)
             (setf start (1+ i))
        finally (push (subseq s start) result)
                (return (nreverse result))))

(defun get-output-stream-string-peek (stream)
  (declare (ignore stream))
  "")   ; not used in simplified impl

(defun parse-key-spec (spec)
  "Parse an Emacs-style key spec into its canonical form.
   Signals an error for empty/invalid input."
  (when (or (null spec) (zerop (length spec)))
    (error "empty key spec"))
  ;; Quick syntactic check
  (let ((parts (split-string-on spec #\-)))
    (cond
      ;; bare single segment
      ((= (length parts) 1) spec)
      ;; modifiers + base
      (t (canonical-key spec)))))

;;; ── keymap operations ──────────────────────────────────────────────────

(defun define-key (km spec action)
  (let* ((seq (split-string-on spec #\Space))
         (single (and (= (length seq) 1)))
         (cur km))
    (if single
        (setf (gethash (canonical-key (first seq)) (keymap-bindings cur)) action)
        ;; multi-key sequence: walk/create sub-keymaps
        (let ((last (car (last seq)))
              (prefix-keys (butlast seq)))
          (dolist (k prefix-keys)
            (let* ((ck   (canonical-key k))
                   (next (gethash ck (keymap-bindings cur))))
              (unless (keymap-p next)
                (setf next (make-keymap))
                (setf (gethash ck (keymap-bindings cur)) next))
              (setf cur next)))
          (setf (gethash (canonical-key last) (keymap-bindings cur)) action)))
    action))

(defun undefine-key (km spec)
  (let ((seq (split-string-on spec #\Space)))
    (if (= (length seq) 1)
        (remhash (canonical-key (first seq)) (keymap-bindings km))
        ;; walk to leaf, remove
        (let ((cur km))
          (dolist (k (butlast seq))
            (let ((next (gethash (canonical-key k) (keymap-bindings cur))))
              (unless (keymap-p next) (return-from undefine-key nil))
              (setf cur next)))
          (remhash (canonical-key (car (last seq))) (keymap-bindings cur))))))

(defun lookup (km spec)
  (let ((v (gethash (canonical-key spec) (keymap-bindings km))))
    (cond
      (v v)
      ((keymap-parent km) (lookup (keymap-parent km) spec))
      (t nil))))

(defun lookup-sequence (km keys)
  "Walk a key sequence. Returns final action, :prefix if mid-sequence,
   or nil if unknown."
  (let ((cur km))
    (loop for k in keys
          for last-p = (eq k (car (last keys)))
          for v = (gethash (canonical-key k) (keymap-bindings cur))
          do (cond
               ((null v)
                ;; Try parent only at the first step
                (if (and (eq cur km) (keymap-parent km))
                    (return (lookup-sequence (keymap-parent km) keys))
                    (return nil)))
               ((keymap-p v)
                (if last-p
                    (return :prefix)
                    (setf cur v)))
               (t  ; action
                (if last-p
                    (return v)
                    (return nil)))))))

(defun lookup-with-prefix (km spec arg)
  "Look up spec then invoke with the prefix arg. Returns the call's return value."
  (let ((action (lookup km spec)))
    (when (and action (functionp action))
      (funcall action arg))))

(defun invoke (km spec &rest args)
  (let ((action (lookup km spec)))
    (cond
      ((null action) (error "no binding for ~s" spec))
      ((functionp action) (apply action args))
      (t action))))

(defun define-parent (child parent)
  (setf (keymap-parent child) parent))

(defun describe-bindings (km)
  "Returns alist ((full-key-string . action) ...) — recursively walks
   prefix sub-keymaps, producing flat space-separated keys like 'C-x f'.

   v0.19 α: previously only top-level bindings appeared (sub-keymap
   values leaked as keymap objects in cdr); now we recurse so user-
   land which-key / discoverability can render the whole tree.

   Own bindings only — parent-inherited bindings are NOT included
   (caller can walk (keymap-parent km) manually if they want)."
  (%describe-bindings-prefixed km ""))

(defun %describe-bindings-prefixed (km prefix)
  (let ((out '()))
    (maphash
      (lambda (k v)
        (let ((full (if (zerop (length prefix))
                        k
                        (format nil "~a ~a" prefix k))))
          (cond
            ((keymap-p v)
             (setf out (nconc out (%describe-bindings-prefixed v full))))
            (t (push (cons full v) out)))))
      (keymap-bindings km))
    out))

;;; ── v0.19 β: *key-prefix* + key-prefix-changed hook ──────────────────
;;;
;;; Promoted from limn::*key-prefix* (internal) to limn/keys:: (public).
;;; User-land which-key implementations subscribe to event/key-prefix-
;;; changed to render the current sequence + likely next keys.

(defvar *key-prefix* '()
  "The framework's accumulator while walking a multi-key sequence.
   E.g. after the user presses C-x, this is ('C-x'); after C-x C-f
   it'd be ('C-x' 'C-f'). Reset to () when a complete binding fires
   or an unbound key terminates the sequence.

   Read freely; WRITE via set-key-prefix so the change hook fires.")

(defun set-key-prefix (new-value)
  "Set *key-prefix*, firing event/key-prefix-changed if value actually
   changed. Idempotent: re-setting to the current value is a no-op.

   Hook receives a plist (:|old| OLD :|new| NEW)."
  (let ((old *key-prefix*))
    (unless (equal old new-value)
      (setf *key-prefix* new-value)
      (let ((run-hook (find-symbol "RUN-HOOK" :limn/hooks)))
        (when run-hook
          (funcall run-hook "event/key-prefix-changed"
                   (list :|old| old :|new| new-value)))))))

;;; ── v0.19 β: set-transient-map + *transient-keymap* ──────────────────
;;;
;;; Looked up FIRST by lookup-key (over local / minor / major / global).
;;; Unlocks user-land hydra / repeat-mode without framework opinion on
;;; how those features should work — they're just keymaps that fire,
;;; and clearing is explicit via (set-transient-map nil) or implicit
;;; via :on-exit you wire yourself.

(defvar *transient-keymap* nil
  "Currently-active transient keymap, or nil. Consulted before any
   mode/local/global lookups when non-nil. SET via set-transient-map.")

(defvar *transient-on-exit* nil
  "Thunk to call when *transient-keymap* is replaced or cleared.
   Captured at set-transient-map time; cleared after firing.")

;;; ── v0.28 — leader key + leader keymap ───────────────────────────────
;;;
;;; *leader-key* names the key (Emacs-spec string, default "SPC") that
;;; introduces a dispatch through *leader-keymap*.  v0.28 map! macro's
;;; :leader option binds into *leader-keymap*; runtime dispatch (callers
;;; like the keystroke handler in repl.lisp) consults it when the leader
;;; key is pressed outside the minibuffer.
;;;
;;; The defvar guards preserve user overrides across reloads.

(defvar *leader-key* "SPC"
  "Key spec that opens *leader-keymap* dispatch.  Default \"SPC\" (Doom).
   Set via (setf limn/keys:*leader-key* ...).")

(defvar *leader-keymap* (make-keymap)
  "Global keymap consulted when *leader-key* is pressed.  Populated by
   user-land via (map! :leader ...) and friends.")

(defun set-transient-map (km &key on-exit)
  "Install KM as the topmost keymap consulted by lookup. KM=nil clears.

   :on-exit is a thunk called when this transient is either explicitly
   cleared (via set-transient-map nil) or replaced by another (Emacs
   convention — replacement counts as 'leaving' the previous one).

   The transient does NOT auto-clear on bound/unbound keystrokes
   by default — callers wanting that semantic can call (set-transient-
   map nil) from their bound actions, or use :on-exit + an external
   trigger (e.g. mode change)."
  ;; Fire prev :on-exit BEFORE swapping, with the on-exit slot cleared
  ;; so re-entry inside the thunk is safe.
  (when *transient-on-exit*
    (let ((fn *transient-on-exit*))
      (setf *transient-on-exit* nil)
      (funcall fn)))
  (setf *transient-keymap*  km
        *transient-on-exit* (and km on-exit)))
