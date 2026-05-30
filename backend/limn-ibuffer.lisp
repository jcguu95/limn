;;;; limn-ibuffer — ibuffer-mode (the *Buffer List* buffer).
;;;;
;;;; Reads limn/buffer registry, renders a table, lets the user mark and
;;;; act on buffers (d/s/x to kill/save). Mirrors limn-occur's structure:
;;;;
;;;;   - pure ibuffer-state (rows, current, marks, sort, filter) +
;;;;     standalone formatting / navigation / mark functions, so the
;;;;     module is unit-testable without a session;
;;;;   - dynamic-var I/O vtable (*ibuffer-write-fn* etc.) — tests progv-
;;;;     bind to no-op mocks, the live install plumbs them through
;;;;     limn:call;
;;;;   - one ibuffer-mode major mode with a dedicated keymap;
;;;;   - one singleton *ibuffer-state* (there is only ever one *Buffer
;;;;     List* window).
;;;;
;;;; Commands live in CL-USER per text-mode convention (M-x ibuffer,
;;;; ibuffer-next-line, ...).

(in-package #:cl-user)

(defpackage #:limn/ibuffer
  (:use #:cl)
  (:export #:install
           #:*ibuffer-state*
           ;; vtable
           #:*ibuffer-write-fn*
           #:*ibuffer-switch-fn*
           #:*ibuffer-save-fn*
           #:*ibuffer-kill-fn*
           #:*ibuffer-cursor-fn*
           ;; state struct
           #:ibuffer-state #:make-ibuffer-state #:ibuffer-state-p
           #:ibuffer-state-rows #:ibuffer-state-current
           #:ibuffer-state-marks #:ibuffer-state-sort-key
           #:ibuffer-state-filter
           #:ibuffer-state-ibuffer-buf-id
           ;; row struct
           #:ibuffer-row #:make-ibuffer-row #:ibuffer-row-p
           #:ibuffer-row-id #:ibuffer-row-path
           #:ibuffer-row-engine #:ibuffer-row-mode
           ;; pure API
           #:collect-rows #:sort-rows #:filter-rows
           #:format-ibuffer-results #:format-ibuffer-line #:format-mark
           #:render
           #:marks-of #:mark-set #:mark-clear #:unmark-all
           #:next-row #:prev-row #:current-row #:row-at
           #:line-offset-for-row
           #:+ibuffer-header+))

(in-package #:limn/ibuffer)

;;; ── vtable ─────────────────────────────────────────────────────────────
;;;
;;; All I/O routed through these so unit tests can swap them with
;;; progv. install replaces them with wire-talking lambdas.

(defvar *ibuffer-write-fn*
  (lambda (bid content) (declare (ignore bid content)))
  "fn (ibuffer-buf-id content) → void.
   Replace text of the *Buffer List* buffer with CONTENT.")

(defvar *ibuffer-switch-fn*
  (lambda (bid) (declare (ignore bid)))
  "fn (target-buf-id) → void.
   Bring target buffer to the front in w1.")

(defvar *ibuffer-save-fn*
  (lambda (bid) (declare (ignore bid)))
  "fn (buf-id) → void.  Execute S mark for this buffer.")

(defvar *ibuffer-kill-fn*
  (lambda (bid) (declare (ignore bid)))
  "fn (buf-id) → void.  Execute D mark — close wire buffer + unregister.")

(defvar *ibuffer-cursor-fn*
  (lambda (bid offset) (declare (ignore bid offset)))
  "fn (ibuffer-buf-id offset) → void.
   Move cursor to row's line start so the selection is visible.")

;;; ── data ───────────────────────────────────────────────────────────────

(defstruct (ibuffer-row (:conc-name ibuffer-row-))
  id
  path
  engine
  mode)   ; modeline-name string or nil

(defstruct (ibuffer-state (:conc-name ibuffer-state-))
  (rows '())
  (current nil)                                ; 0-based or nil
  (marks (make-hash-table :test 'equal))       ; buf-id → list of chars
  (sort-key :id)                               ; :id | :path | :engine
  (filter nil)                                 ; substring or nil
  (ibuffer-buf-id "*Buffer List*"))

(defvar *ibuffer-state* nil
  "Singleton state.  Populated by (M-x ibuffer); nil before first entry.")

;;; ── package-soft helpers ───────────────────────────────────────────────

(defun %limn-call (cmd &rest kw)
  "Dispatch to limn:call if a session is live; silently no-op otherwise
   (unit tests, repl-time loads)."
  (let ((sym (find-symbol "CALL" :limn)))
    (when (and sym (fboundp sym))
      (apply (symbol-function sym) cmd kw))))

(defun %response-data (r)
  (let ((rd (find-symbol "RESPONSE-DATA" :limn/bridge)))
    (when (and rd (fboundp rd) r)
      (funcall (symbol-function rd) r))))

(defun %mode-string-for (buf-id)
  "Modeline name of buf-id's current major mode, or nil."
  (let* ((rt (find-package '#:limn/runtime))
         (find-mb (and rt (find-symbol "FIND-MODE-BUFFER" rt))))
    (when (and find-mb (fboundp find-mb))
      (let* ((mb    (funcall (symbol-function find-mb) buf-id))
             (major (and mb (limn/mode:major-mode mb)))
             (m     (and major (limn/mode:find-mode major))))
        (and m (limn/mode:mode-modeline-name m))))))

;;; ── collect ────────────────────────────────────────────────────────────

(defun collect-rows ()
  "Walk limn/buffer registry into a fresh, unsorted list of ibuffer-rows.

   Includes the *Buffer List*'s own wire buffer — like Emacs ibuffer,
   the ibuffer is itself a listable buffer.  Caller renders / filters
   as desired."
  (loop for id in (limn/buffer:list-all)
        for b  = (limn/buffer:lookup id)
        when b
        collect (make-ibuffer-row
                 :id     id
                 :path   (limn/buffer:path b)
                 :engine (limn/buffer:engine b)
                 :mode   (%mode-string-for id))))

(defun %row-field (row key)
  (ecase key
    (:id     (ibuffer-row-id row))
    (:path   (ibuffer-row-path row))
    (:engine (ibuffer-row-engine row))))

(defun sort-rows (rows key)
  "Sort by KEY (:id :path :engine).  Stable string compare; nils sort last."
  (sort (copy-list rows)
        (lambda (a b)
          (let ((x (or (%row-field a key) ""))
                (y (or (%row-field b key) "")))
            (string< x y)))))

(defun filter-rows (rows substr)
  "Substring match against id and path (case-insensitive).  nil/empty
   passes everything through."
  (if (or (null substr) (zerop (length substr)))
      rows
      (let ((needle (string-downcase substr)))
        (remove-if-not
         (lambda (r)
           (let ((p (string-downcase (or (ibuffer-row-path r) "")))
                 (i (string-downcase (or (ibuffer-row-id   r) ""))))
             (or (search needle p :test #'char=)
                 (search needle i :test #'char=))))
         rows))))

;;; ── marks ──────────────────────────────────────────────────────────────

(defun marks-of (state id)
  (gethash id (ibuffer-state-marks state)))

(defun mark-set (state id char)
  "Add CHAR to ID's mark set (dedup)."
  (let* ((tbl (ibuffer-state-marks state))
         (cur (gethash id tbl)))
    (unless (member char cur :test #'char=)
      (setf (gethash id tbl) (append cur (list char))))))

(defun mark-clear (state id &optional char)
  "Drop CHAR from ID's marks, or clear ALL of ID's marks when CHAR is nil."
  (let ((tbl (ibuffer-state-marks state)))
    (if char
        (let ((cur (gethash id tbl)))
          (setf (gethash id tbl) (remove char cur :test #'char=)))
        (remhash id tbl))))

(defun unmark-all (state)
  (clrhash (ibuffer-state-marks state)))

;;; ── format ─────────────────────────────────────────────────────────────

(defparameter +ibuffer-header+
  ;; Auto-generate from the same format string format-ibuffer-line
  ;; uses, so column widths stay in sync mechanically.  Layout:
  ;;   cursor(1) + sp + mark(2) + sp + ID(17) + sp + ENGINE(8) + sp + PATH
  (format nil "~a ~a ~17a ~8a ~a" " " "M " "ID" "ENGINE" "PATH"))

(defun format-mark (chars)
  "Render a list of mark chars as a 2-char column (Emacs ibuffer style)."
  (cond
    ((null chars)        "  ")
    ((null (cdr chars))  (format nil "~c " (car chars)))
    (t                   (format nil "~c~c" (car chars) (cadr chars)))))

(defun format-ibuffer-line (row marks &optional current-p)
  "Render one ibuffer table row.  CURRENT-P draws a `>` in the leftmost
   column so the user can SEE which row is selected (sioyek's text caret
   is too thin to be obvious on a one-row move).  Width is constant — `>`
   and ` ` are both 1 char — so line-offset-for-row's math holds."
  (let ((id     (or (ibuffer-row-id     row) ""))
        (engine (or (ibuffer-row-engine row) ""))
        (path   (let ((p (or (ibuffer-row-path row) "")))
                  (if (zerop (length p)) "<no file>" p))))
    (format nil "~a ~a ~17a ~8a ~a"
            (if current-p ">" " ")
            (format-mark marks) id engine path)))

(defun format-ibuffer-results (state)
  (let ((rows (ibuffer-state-rows state))
        (cur  (ibuffer-state-current state)))
    (if (null rows)
        (format nil "~a~%No buffers.~%" +ibuffer-header+)
        (with-output-to-string (s)
          (format s "~a~%" +ibuffer-header+)
          (loop for r in rows
                for i from 0
                do (format s "~a~%"
                           (format-ibuffer-line
                            r (marks-of state (ibuffer-row-id r))
                            (and cur (eql i cur)))))))))

;;; ── navigation ─────────────────────────────────────────────────────────

(defun row-at (state index)
  (nth index (ibuffer-state-rows state)))

(defun current-row (state)
  (let ((i (ibuffer-state-current state)))
    (and i (row-at state i))))

(defun next-row (state)
  "Advance current pointer with wrap; nil → 0.  Returns state for chaining."
  (let* ((rows (ibuffer-state-rows state))
         (n    (length rows))
         (cur  (ibuffer-state-current state)))
    (when (plusp n)
      (setf (ibuffer-state-current state)
            (if (null cur) 0 (mod (1+ cur) n))))
    state))

(defun prev-row (state)
  (let* ((rows (ibuffer-state-rows state))
         (n    (length rows))
         (cur  (ibuffer-state-current state)))
    (when (plusp n)
      (setf (ibuffer-state-current state)
            (if (null cur) 0 (mod (1- cur) n))))
    state))

;;; ── render ─────────────────────────────────────────────────────────────

(defun line-offset-for-row (state index)
  "Codepoint offset to row INDEX's line start in the rendered buffer.
   Header is line 0 (offset 0); data rows follow."
  (let ((header-len (1+ (length +ibuffer-header+)))) ; + newline
    (loop for j below index
          for r     = (row-at state j)
          for marks = (marks-of state (ibuffer-row-id r))
          sum (1+ (length (format-ibuffer-line r marks))) into acc
          finally (return (+ header-len acc)))))

(defvar *ibuffer-trace* nil
  "When non-nil, each render prints a one-line diagnostic to
   *standard-output*: cur, rows, cursor offset, content size.
   Useful when a navigation key seems to do nothing — confirms
   whether render is even firing.")

(defun render (state)
  "Push formatted content through *ibuffer-write-fn*, then move the
   cursor to current row's line start."
  (let* ((content (format-ibuffer-results state))
         (bid     (ibuffer-state-ibuffer-buf-id state))
         (cur     (ibuffer-state-current state))
         (rows    (ibuffer-state-rows state))
         (target  (and cur rows (line-offset-for-row state cur))))
    (funcall *ibuffer-write-fn* bid content)
    (when (and cur rows)
      (funcall *ibuffer-cursor-fn* bid target))
    (when *ibuffer-trace*
      (format t "~&[ibuffer] render bid=~s cur=~s rows=~d cursor→~s content-len=~d~%"
              bid cur (length rows) target (length content))
      (force-output))
    state))

;;; ── default wire vtable ────────────────────────────────────────────────

(defun %install-default-vtable ()
  "Plumb the dynamic vars through limn:call.  Idempotent.
   Tests that want isolation progv-bind on top of these."
  (setf *ibuffer-write-fn*
        (lambda (bid content)
          ;; Replace existing text: delete 0..len, insert at 0.
          (let* ((tr   (%limn-call "buffer/text" :|buffer-id| bid))
                 (td   (%response-data tr))
                 (old  (or (getf td :|text|) ""))
                 (olen (length old)))
            (when (plusp olen)
              (%limn-call "buffer/delete" :|buffer-id| bid
                                          :|from| 0 :|to| olen))
            (when (plusp (length content))
              (%limn-call "buffer/insert" :|buffer-id| bid
                                          :|at| 0 :|text| content)))))
  (setf *ibuffer-switch-fn*
        (lambda (bid)
          (%limn-call "buffer/show" :|buffer-id| bid :|win-id| "w1")))
  (setf *ibuffer-save-fn*
        (lambda (bid)
          (%limn-call "buffer/save" :|buffer-id| bid)))
  (setf *ibuffer-kill-fn*
        (lambda (bid)
          ;; Wire-side close + Lisp-side unregister.  Either may fail
          ;; (e.g. buffer already gone); swallow so subsequent kills run.
          (handler-case (%limn-call "buffer/close" :|buffer-id| bid)
            (error () nil))
          (handler-case (limn/buffer:unregister bid)
            (error () nil))))
  (setf *ibuffer-cursor-fn*
        (lambda (bid offset)
          (%limn-call "buffer/cursor-set"
                      :|buffer-id| bid :|offset| offset))))

;;; ── helpers used by the M-x commands ───────────────────────────────────

(defun %ensure-ibuffer-buf-id ()
  "Allocate (or reuse) a wire-level text buffer for *Buffer List*.
   Returns the wire-allocated buffer-id, or nil if no session.
   Errors (no session, transport failure) collapse to nil so the
   caller can fall back to the symbolic name."
  (handler-case
      (let* ((r (%limn-call "bridge/engine-load"
                            :|win-id| "w1" :|engine| "text" :|path| ""))
             (d (%response-data r)))
        (getf d :|buffer-id|))
    (error () nil)))

(defun %activate-ibuffer-mode-on (bid)
  "Make sure BID has a mode-buffer and ibuffer-mode is its major mode."
  (let* ((rt (find-package '#:limn/runtime))
         (find-mb (and rt (find-symbol "FIND-MODE-BUFFER" rt)))
         (reg-mb  (and rt (find-symbol "REGISTER-MODE-BUFFER" rt))))
    (when (and find-mb reg-mb (fboundp find-mb) (fboundp reg-mb))
      (let ((mb (or (funcall (symbol-function find-mb) bid)
                    (let ((new (limn/mode:make-mode-buffer)))
                      (funcall (symbol-function reg-mb) bid new)
                      new)))
            (mode-sym (find-symbol "IBUFFER-MODE" :cl-user)))
        (when (and mode-sym (limn/mode:find-mode mode-sym))
          (handler-case (limn/mode:activate mb mode-sym)
            (error () nil)))))))

(defun %enter-ibuffer ()
  "Entry point.  Build state, render, switch w1 to *Buffer List*."
  (let* ((bid  (or (and *ibuffer-state*
                        (ibuffer-state-ibuffer-buf-id *ibuffer-state*))
                   (%ensure-ibuffer-buf-id)
                   "*Buffer List*"))
         (rows (sort-rows (collect-rows) :id))
         (state (make-ibuffer-state
                 :rows           rows
                 :current        (and rows 0)
                 :ibuffer-buf-id bid)))
    (setf *ibuffer-state* state)
    (render state)
    (funcall *ibuffer-switch-fn* bid)
    (%activate-ibuffer-mode-on bid)
    state))

(defun %revert ()
  (let ((s *ibuffer-state*))
    (when s
      (let* ((rows (filter-rows
                    (sort-rows (collect-rows) (ibuffer-state-sort-key s))
                    (ibuffer-state-filter s)))
             (cur  (ibuffer-state-current s))
             (n    (length rows)))
        (setf (ibuffer-state-rows s) rows
              (ibuffer-state-current s)
              (cond ((zerop n) nil)
                    ((null cur) 0)
                    ((>= cur n) (1- n))
                    (t cur)))
        (render s)))))

(defun %nav (fn)
  (when *ibuffer-state*
    (funcall fn *ibuffer-state*)
    (render *ibuffer-state*)))

(defun %visit ()
  (let ((row (and *ibuffer-state* (current-row *ibuffer-state*))))
    (when row
      (funcall *ibuffer-switch-fn* (ibuffer-row-id row)))))

(defun %mark-and-advance (char)
  (let ((row (and *ibuffer-state* (current-row *ibuffer-state*))))
    (when row
      (mark-set *ibuffer-state* (ibuffer-row-id row) char)
      (next-row *ibuffer-state*)
      (render *ibuffer-state*))))

(defun %unmark-and-advance ()
  (let ((row (and *ibuffer-state* (current-row *ibuffer-state*))))
    (when row
      (mark-clear *ibuffer-state* (ibuffer-row-id row))
      (next-row *ibuffer-state*)
      (render *ibuffer-state*))))

(defun %unmark-all ()
  (when *ibuffer-state*
    (unmark-all *ibuffer-state*)
    (render *ibuffer-state*)))

(defun %execute-marks ()
  "Apply S then D marks, then revert.  Order matters: save first
   in case D would have killed the buffer before save ran."
  (when *ibuffer-state*
    (let ((tbl (ibuffer-state-marks *ibuffer-state*))
          (kill-ids '()))
      (maphash
       (lambda (id marks)
         (when (member #\S marks :test #'char=)
           (funcall *ibuffer-save-fn* id))
         (when (member #\D marks :test #'char=)
           (push id kill-ids)))
       tbl)
      (dolist (id kill-ids)
        (funcall *ibuffer-kill-fn* id)))
    (clrhash (ibuffer-state-marks *ibuffer-state*))
    (%revert)))

(defun %sort-by (key-str)
  (when (and *ibuffer-state* (stringp key-str))
    (let ((key (cond
                 ((or (string-equal key-str "id")
                      (string-equal key-str "i"))     :id)
                 ((or (string-equal key-str "path")
                      (string-equal key-str "p"))     :path)
                 ((or (string-equal key-str "engine")
                      (string-equal key-str "e"))     :engine)
                 (t nil))))
      (when key
        (setf (ibuffer-state-sort-key *ibuffer-state*) key)
        (%revert)))))

(defun %set-filter (substr)
  (when *ibuffer-state*
    (setf (ibuffer-state-filter *ibuffer-state*)
          (and substr (plusp (length substr)) substr))
    (%revert)))

;;; ── keymap binding glue ────────────────────────────────────────────────

(defun %wrap-cmd (sym)
  "Build a key-binding lambda that defers to call-interactively.
   Ignores the EV plist — ibuffer-mode bindings have no self-insert,
   so we never need the originating key."
  (lambda (ev)
    (declare (ignore ev))
    (limn/cmd:call-interactively sym)))

(defun %def-cmd (km spec sym)
  (limn/keys:define-key km spec (%wrap-cmd sym)))

;;; ── commands (CL-USER, per text-mode convention) ───────────────────────

(in-package #:cl-user)

(limn/cmd:defcommand ibuffer (:interactive nil)
  (lambda () (limn/ibuffer::%enter-ibuffer)))

(limn/cmd:defcommand ibuffer-next-line (:interactive nil)
  (lambda () (limn/ibuffer::%nav #'limn/ibuffer:next-row)))

(limn/cmd:defcommand ibuffer-prev-line (:interactive nil)
  (lambda () (limn/ibuffer::%nav #'limn/ibuffer:prev-row)))

(limn/cmd:defcommand ibuffer-visit-buffer (:interactive nil)
  (lambda () (limn/ibuffer::%visit)))

(limn/cmd:defcommand ibuffer-mark-for-delete (:interactive nil)
  (lambda () (limn/ibuffer::%mark-and-advance #\D)))

(limn/cmd:defcommand ibuffer-mark-for-save (:interactive nil)
  (lambda () (limn/ibuffer::%mark-and-advance #\S)))

(limn/cmd:defcommand ibuffer-unmark (:interactive nil)
  (lambda () (limn/ibuffer::%unmark-and-advance)))

(limn/cmd:defcommand ibuffer-unmark-all (:interactive nil)
  (lambda () (limn/ibuffer::%unmark-all)))

(limn/cmd:defcommand ibuffer-do-execute (:interactive nil)
  (lambda () (limn/ibuffer::%execute-marks)))

(limn/cmd:defcommand ibuffer-revert (:interactive nil)
  (lambda () (limn/ibuffer::%revert)))

(limn/cmd:defcommand ibuffer-sort-by (:interactive "sSort by (id/path/engine): ")
  (lambda (k) (limn/ibuffer::%sort-by k)))

(limn/cmd:defcommand ibuffer-filter-by-substring (:interactive "sFilter substring: ")
  (lambda (s) (limn/ibuffer::%set-filter s)))

;;; ── install ────────────────────────────────────────────────────────────

(in-package #:limn/ibuffer)

(defun install ()
  "Idempotent setup: define ibuffer-mode + its keymap, wire the default
   vtable.  Called at file load time and safe to re-call."
  (let* ((mode-sym (intern "IBUFFER-MODE" :cl-user))
         (fund     (find-symbol "FUNDAMENTAL-MODE" :limn/runtime)))
    ;; Ensure parent exists (tests load modules in isolation).
    (when (and fund (not (limn/mode:find-mode fund)))
      (limn/mode:define-mode fund :type :major :modeline "Fund"))

    (let ((km (limn/keys:make-keymap)))
      (%def-cmd km "n"        (intern "IBUFFER-NEXT-LINE"           :cl-user))
      (%def-cmd km "<down>"   (intern "IBUFFER-NEXT-LINE"           :cl-user))
      (%def-cmd km "p"        (intern "IBUFFER-PREV-LINE"           :cl-user))
      (%def-cmd km "<up>"     (intern "IBUFFER-PREV-LINE"           :cl-user))
      (%def-cmd km "RET"      (intern "IBUFFER-VISIT-BUFFER"        :cl-user))
      (%def-cmd km "f"        (intern "IBUFFER-VISIT-BUFFER"        :cl-user))
      (%def-cmd km "d"        (intern "IBUFFER-MARK-FOR-DELETE"     :cl-user))
      (%def-cmd km "s"        (intern "IBUFFER-MARK-FOR-SAVE"       :cl-user))
      (%def-cmd km "u"        (intern "IBUFFER-UNMARK"              :cl-user))
      (%def-cmd km "U"        (intern "IBUFFER-UNMARK-ALL"          :cl-user))
      (%def-cmd km "x"        (intern "IBUFFER-DO-EXECUTE"          :cl-user))
      (%def-cmd km "g"        (intern "IBUFFER-REVERT"              :cl-user))
      ;; No `q` binding by design.  Emacs ibuffer's q runs quit-window
      ;; (bury this buffer + show the previous one).  Implementing that
      ;; cleanly needs buffer/show to reliably swap the QStackedWidget
      ;; visually when going from text-engine → mupdf, which exposes a
      ;; sioyek-side Qt paint quirk independent of ibuffer.  Until that
      ;; lands, leaving the binding out is honest: users leave ibuffer
      ;; by `RET` / `f` on a row (which visits a chosen buffer) or by
      ;; M-x switch-to-buffer.  Picking back up here is a follow-up.
      (%def-cmd km "S"        (intern "IBUFFER-SORT-BY"             :cl-user))
      (%def-cmd km "/"        (intern "IBUFFER-FILTER-BY-SUBSTRING" :cl-user))

      (limn/mode:define-mode mode-sym
                             :type :major
                             :parent fund
                             :modeline "IBuffer")
      (setf (limn/mode:mode-keymap (limn/mode:find-mode mode-sym)) km))

    (%install-default-vtable)
    mode-sym))

;;; Auto-install at load time.  Idempotent.
(install)
