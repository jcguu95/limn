;;;; limn-completion — completing-read / minibuffer, Emacs-compatible.
;;;;
;;;; Pure Lisp. v0.25 §C.
;;;; Qt-tier (LimnMiniWindow focus management) is wired separately.
;;;; In unit-test "batch" mode, completing-read uses :initial-input as
;;;; the typed text and returns the best match without user interaction.

(defpackage #:limn/completion
  (:use #:cl)
  (:export #:completing-read
           #:read-from-minibuffer
           #:minibuffer-prompt #:minibuffer-contents
           #:minibuffer-completion-help
           #:*completion-styles*
           #:complete-with-styles
           #:quit-minibuffer
           #:quit-condition
           #:*enable-fuzzy-selector*
           #:enable-fuzzy-selector
           #:disable-fuzzy-selector))

(in-package #:limn/completion)

(defvar *completion-styles* '(substring prefix flex))

;;; ─── Fuzzy Selector 開關（§6）─────────────────────────────────────────

(defvar *enable-fuzzy-selector* nil
  "當設為 T 時，completing-read 會走 Vertico 垂直選單路徑（Orderless 模糊比對）。
   預設為 NIL，不破壞現有行為。")

(defun enable-fuzzy-selector ()
  "開啟 Fuzzy Selector 模式。"
  (setf *enable-fuzzy-selector* t))

(defun disable-fuzzy-selector ()
  "關閉 Fuzzy Selector 模式。"
  (setf *enable-fuzzy-selector* nil))

;;; Last minibuffer state (used by minibuffer-prompt / minibuffer-contents)
(defvar *current-prompt* "")
(defvar *current-contents* "")

(define-condition quit-condition (error) ()
  (:report (lambda (c s) (declare (ignore c)) (write-string "Quit" s))))

;;; ─── collection normalisation ─────────────────────────────────────

(defun %candidates (collection input pred)
  "Return all candidates from COLLECTION matching INPUT via PRED."
  (let ((raw
          (etypecase collection
            (list collection)
            (hash-table
             (let ((keys '()))
               (maphash (lambda (k _v) (declare (ignore _v)) (push k keys)) collection)
               keys))
            (function
             (funcall collection input pred nil)))))
    (if pred
        (remove-if-not pred raw)
        raw)))

;;; ─── completion styles ────────────────────────────────────────────

(defun %match-substring (input candidate)
  (search (string-downcase input) (string-downcase candidate)))

(defun %match-prefix (input candidate)
  (let ((ci (string-downcase input))
        (cc (string-downcase candidate)))
    (and (<= (length ci) (length cc))
         (string= ci cc :end2 (length ci)))))

(defun %match-flex (input candidate)
  "All chars of INPUT appear in CANDIDATE in order."
  (let ((pos 0))
    (every (lambda (ch)
             (let ((found (position ch candidate :start pos
                                                  :test #'char-equal)))
               (when found (setf pos (1+ found)))
               found))
           (coerce input 'list))))

(defun %style-name (style)
  (string-downcase (if (symbolp style) (symbol-name style) (string style))))

(defun complete-with-styles (input candidates &optional (styles *completion-styles*))
  "Return members of CANDIDATES that match INPUT with any style in STYLES."
  (remove-if-not
   (lambda (c)
     (some (lambda (style)
             (let ((name (%style-name style)))
               (cond
                 ((string= name "substring") (%match-substring input c))
                 ((string= name "prefix")    (%match-prefix    input c))
                 ((string= name "flex")      (%match-flex      input c))
                 (t nil))))
           styles))
   candidates))

;;; ─── completing-read ──────────────────────────────────────────────

(defun %try-live-minibuffer-read (prompt)
  "v0.38: if the runtime has installed a real *minibuffer-read* (i.e. a
   live session), use it.  Returns the typed string, or NIL if no
   live reader is installed (unit-test fallback)."
  (let* ((cmd-pkg (find-package '#:limn/cmd))
         (mb-sym  (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg)))
         (mb-fn   (and mb-sym (boundp mb-sym) (symbol-value mb-sym))))
    (when (and mb-fn (functionp mb-fn))
      (handler-case (funcall mb-fn prompt)
        (error () nil)))))

(defun completing-read (prompt collection
                        &key predicate require-match
                             initial-input history default
                             annotation-function)
  (setf *current-prompt* prompt)
  ;; §5 §6：當 Fuzzy Selector 開啟且在 live session 時，走 vertico-completing-read
  (when *enable-fuzzy-selector*
    (let ((vertico-pkg (find-package '#:limn/vertico)))
      (when (and vertico-pkg
                 (find-symbol "VERTICO-COMPLETING-READ" vertico-pkg))
        (return-from completing-read
          (funcall (symbol-function
                    (find-symbol "VERTICO-COMPLETING-READ" vertico-pkg))
                   prompt collection
                   :predicate predicate
                   :require-match require-match
                   :initial-input initial-input
                   :history history
                   :default default)))))
  ;; v0.38: in a live session, delegate to *minibuffer-read* to actually
  ;; open the minibuffer over the bridge.  Otherwise (unit tests) fall
  ;; through to the existing collection-matching behavior.
  (let ((live (%try-live-minibuffer-read prompt)))
    (when live
      (setf *current-contents* live)
      (when history (ignore-errors (%push-history history live)))
      (let ((all (%candidates collection live predicate)))
        (return-from completing-read
          (cond
            ((find live all :test #'equal) live)
            ((and require-match all) (first all))
            (t live))))))
  (let* ((input (or initial-input ""))
         (all-candidates (%candidates collection input predicate)))
    (setf *current-contents* input)

    ;; Call annotation-function for each candidate (side-effect only in tests)
    (when annotation-function
      (dolist (c all-candidates)
        (funcall annotation-function c)))

    ;; Match input against candidates
    (let ((matches (if (string= input "")
                       all-candidates
                       (complete-with-styles input all-candidates))))
      (cond
        ;; Empty input + default
        ((and (string= input "") default)
         (when history (ignore-errors (%push-history history default)))
         default)

        ;; Exact match
        ((find input all-candidates :test #'equal)
         (when history (ignore-errors (%push-history history input)))
         input)

        ;; Single match → return it
        ((= (length matches) 1)
         (let ((result (first matches)))
           (when history (ignore-errors (%push-history history result)))
           result))

        ;; Multiple matches → return first (batch mode)
        ((> (length matches) 1)
         (let ((result (first matches)))
           (when history (ignore-errors (%push-history history result)))
           result))

        ;; No match
        (require-match
         (error "No match for ~s in completing-read" input))

        ;; No match, no require-match → return raw input
        (t
         (when history (ignore-errors (%push-history history input)))
         input)))))

(defun %push-history (history item)
  (when (find-package '#:limn/history)
    (funcall (find-symbol "ADD-TO-HISTORY" '#:limn/history) history item)))

;;; ─── read-from-minibuffer ─────────────────────────────────────────

(defun read-from-minibuffer (prompt &key initial-contents keymap history)
  (declare (ignore keymap))
  (setf *current-prompt* prompt)
  (let ((contents (or initial-contents "")))
    (setf *current-contents* contents)
    (when history
      (ignore-errors (%push-history history contents)))
    contents))

;;; ─── minibuffer state ─────────────────────────────────────────────

(defun minibuffer-prompt ()
  *current-prompt*)

(defun minibuffer-contents ()
  *current-contents*)

;;; ─── quit ─────────────────────────────────────────────────────────

(defun quit-minibuffer ()
  (error 'quit-condition))

;;; ─── completion help (*Completions* buffer) ───────────────────────

(defun minibuffer-completion-help ()
  "Display completion candidates in *Completions* buffer."
  ;; In unit mode: no-op. Qt-tier wires this to a real split window.
  nil)

;;; ─── bridge wire-up helpers ───────────────────────────────────────

(defun %bridge-call (cmd &rest args)
  "Call CMD via limn:call when bridge is live; return nil otherwise."
  (let ((pkg (find-package '#:limn)))
    (when pkg
      (let ((call-fn (find-symbol "CALL" pkg)))
        (when call-fn
          (ignore-errors (apply call-fn cmd args)))))))

(defun %bridge-open-minibuffer (prompt)
  (%bridge-call "minibuffer/open")
  (%bridge-call "minibuffer/set-prompt" :|prompt| prompt))

(defun %bridge-close-minibuffer ()
  (%bridge-call "minibuffer/close"))

(defun %bridge-set-minibuffer-text (text)
  (%bridge-call "minibuffer/set-text" :|text| text))
