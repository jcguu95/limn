;;;; limn-indent — v0.36 §B Indent system + §C current-column.
;;;;
;;;; Pure Lisp. Provides:
;;;;
;;;;   §C  char-display-width  — ASCII 1 / TAB dynamic / CJK 2 / control 2
;;;;       current-column      — counts display width from line start to point
;;;;
;;;;   §B  indent-to / move-to-column / back-to-indentation /
;;;;       indent-region / indent-rigidly / indent-relative /
;;;;       indent-for-tab-command / newline-and-indent
;;;;
;;;; Buffer-local variables (defined in CL-USER for user-facing names):
;;;;   *tab-width*           — int, default 8
;;;;   *indent-tabs-mode*    — bool, default t
;;;;   *fill-column*         — int, default 70 (plumbed; consumers ship later)
;;;;   *indent-line-function* — function, default INDENT-RELATIVE
;;;;
;;;; Vtable injection: buffer text / point / insert / delete go through
;;;; *BUFFER-*-FN* pointers — production wires them to limn:call, tests
;;;; install mocks.

(in-package #:cl-user)

;;; ── User-facing buffer-local vars (CL-USER package, defvar-local pattern).
;;;
;;; We use the v0.30 buffer-local mechanism: declare with defvar so a
;;; reload preserves any user customization, then mark buffer-local.
;;;
;;; *fill-column* is plumbed but not consumed yet (fill-paragraph lands
;;; later).

(defvar *tab-width* 8
  "Display width of a TAB character in columns. Buffer-local.")

(defvar *indent-tabs-mode* t
  "If non-nil, indent uses TAB characters where possible; otherwise SPC only.
   Buffer-local.")

(defvar *fill-column* 70
  "Right-edge column for fill commands. Plumbed for future use.")

(defvar *indent-line-function* nil
  "Function called by indent-for-tab-command / indent-region for each line.
   Defaults to INDENT-RELATIVE (set after that function is defined). Buffer-local.")

;; Register as buffer-local with limn/local at load time.
(eval-when (:load-toplevel :execute)
  (let ((pkg (find-package '#:limn/local)))
    (when pkg
      (let ((mvbl (find-symbol "MAKE-VARIABLE-BUFFER-LOCAL" pkg)))
        (when (and mvbl (fboundp mvbl))
          (funcall mvbl '*tab-width*)
          (funcall mvbl '*indent-tabs-mode*)
          (funcall mvbl '*fill-column*)
          (funcall mvbl '*indent-line-function*))))))

(defpackage #:limn/indent
  (:use #:cl)
  (:export ;; §C
           #:char-display-width
           #:current-column
           ;; §B
           #:indent-to
           #:move-to-column
           #:back-to-indentation
           #:indent-region
           #:indent-rigidly
           #:indent-relative
           #:indent-for-tab-command
           #:newline-and-indent
           ;; vtable hooks
           #:*buffer-text-fn*
           #:*buffer-insert-fn*
           #:*buffer-delete-fn*
           #:*point-fn*
           #:*set-point-fn*
           #:*buffer-text-len-fn*
           ;; runtime wireup
           #:install-wire-vtable))

(in-package #:limn/indent)

;;; ── vtable hooks ──────────────────────────────────────────────────────────

(defvar *buffer-text-fn*
  (lambda (bid) (declare (ignore bid)) ""))

(defvar *buffer-insert-fn*
  (lambda (bid off str) (declare (ignore bid off str)) nil))

(defvar *buffer-delete-fn*
  (lambda (bid from to) (declare (ignore bid from to)) nil))

(defvar *point-fn*
  (lambda (bid) (declare (ignore bid)) 0))

(defvar *set-point-fn*
  (lambda (bid off) (declare (ignore bid off)) nil))

(defvar *buffer-text-len-fn*
  (lambda (bid) (declare (ignore bid)) 0))

;;; ── current buffer + buffer-local var resolution ─────────────────────────

(defun %current-buffer-id ()
  (let* ((pkg (find-package '#:limn/excursion))
         (fn  (and pkg (find-symbol "CURRENT-BUFFER-ID" pkg))))
    (or (and fn (fboundp fn) (funcall fn))
        ;; Fallback: limn/local *current-buffer-id*
        (let* ((lp (find-package '#:limn/local))
               (sym (and lp (find-symbol "*CURRENT-BUFFER-ID*" lp))))
          (and sym (boundp sym) (symbol-value sym))))))

(defun %local-get (cl-user-sym default)
  "Read a buffer-local variable from CL-USER; fall back to symbol-value if
   limn/local isn't loaded; fall back to DEFAULT if symbol unbound."
  (let* ((pkg (find-package '#:limn/local))
         (get (and pkg (find-symbol "BUFFER-LOCAL-VALUE" pkg)))
         (bid (%current-buffer-id)))
    (handler-case
        (cond
          ((and get (fboundp get) bid)
           (funcall get cl-user-sym bid))
          ((boundp cl-user-sym)
           (symbol-value cl-user-sym))
          (t default))
      (error () (if (boundp cl-user-sym) (symbol-value cl-user-sym) default)))))

(defun %tab-width ()
  (let ((v (%local-get (find-symbol "*TAB-WIDTH*" :cl-user) 8)))
    (if (and (integerp v) (plusp v)) v 8)))

(defun %indent-tabs-mode ()
  (%local-get (find-symbol "*INDENT-TABS-MODE*" :cl-user) t))

(defun %indent-line-function ()
  (%local-get (find-symbol "*INDENT-LINE-FUNCTION*" :cl-user) nil))

;;; ── §C  char-display-width ─────────────────────────────────────────────────

(defun %cjk-wide-p (code)
  "Approximate East Asian Wide / Fullwidth + emoji ranges → display width 2.
   Lookup is intentionally coarse — covers the common ranges used in
   CJK + emoji testing without dragging in a full EAW table."
  (or (<= #x1100 code #x115F)            ; Hangul Jamo init
      (<= #x2E80 code #x303E)            ; CJK Radicals / Kangxi
      (<= #x3041 code #x33FF)            ; Hiragana, Katakana, CJK symbols
      (<= #x3400 code #x4DBF)            ; CJK ext A
      (<= #x4E00 code #x9FFF)            ; CJK Unified
      (<= #xA000 code #xA4CF)            ; Yi
      (<= #xAC00 code #xD7A3)            ; Hangul Syllables
      (<= #xF900 code #xFAFF)            ; CJK Compat
      (<= #xFE30 code #xFE4F)            ; CJK Compat Forms
      (<= #xFF00 code #xFF60)            ; Fullwidth
      (<= #xFFE0 code #xFFE6)            ; Fullwidth signs
      ;; Emoji rough ranges
      (<= #x1F300 code #x1F64F)
      (<= #x1F680 code #x1F6FF)
      (<= #x1F900 code #x1F9FF)
      (<= #x1FA70 code #x1FAFF)
      (<= #x1F1E6 code #x1F1FF)          ; Regional Indicator (flags)
      (<= #x20000 code #x2FFFD)          ; CJK ext B-F
      (<= #x30000 code #x3FFFD)))        ; CJK ext G

(defun char-display-width (ch &optional (col 0))
  "Visual width of CH when displayed at column COL.
   ASCII printable → 1; TAB → spaces to next tab-stop;
   newline/CR → 0; CJK fullwidth / emoji → 2; other control → 2 (fixed)."
  (let ((code (char-code ch))
        (tw   (if (zerop col) (%tab-width) (%tab-width))))
    (cond
      ((char= ch #\Newline) 0)
      ((char= ch #\Return)  0)
      ((char= ch #\Tab)
       (- tw (mod col tw)))
      ((and (>= code 32) (<= code 126)) 1)   ; ASCII printable
      ((%cjk-wide-p code) 2)
      ((< code 32) 2)                        ; other control char
      ((= code 127) 2)                       ; DEL
      (t 1))))                               ; non-CJK Unicode → 1

;;; ── line geometry helpers ─────────────────────────────────────────────────

(defun %line-start (text pos)
  "Offset of beginning of the line containing POS in TEXT."
  (or (position #\Newline text :end pos :from-end t)
      -1)                                   ; -1 → line starts at 0 (we +1)
  (1+ (or (position #\Newline text :end pos :from-end t)
          -1)))

(defun %line-end (text pos)
  "Offset of the end of the line containing POS (the newline or text end)."
  (or (position #\Newline text :start pos)
      (length text)))

(defun %column-at (text pos)
  "Compute display column of POS (counted from line start)."
  (let ((ls (%line-start text pos))
        (col 0))
    (loop for i from ls below pos do
      (incf col (char-display-width (char text i) col)))
    col))

(defun current-column ()
  "Display column of point in *current-buffer*."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid)))
    (%column-at text point)))

;;; ── §B  indent-to ─────────────────────────────────────────────────────────

(defun %make-indent-string (cur-col target-col)
  "Build a string to advance from CUR-COL to TARGET-COL using TAB+SPC if
   *indent-tabs-mode*, else only SPC."
  (let ((delta (- target-col cur-col))
        (tw    (%tab-width))
        (use-tabs (%indent-tabs-mode)))
    (when (<= delta 0)
      (return-from %make-indent-string ""))
    (cond
      ((not use-tabs)
       (make-string delta :initial-element #\Space))
      (t
       ;; Use TABs greedily, then SPCs.
       (with-output-to-string (s)
         (let ((c cur-col))
           ;; First TAB: only if it lands ≤ target.
           (loop while (let ((adv (- tw (mod c tw))))
                         (<= (+ c adv) target-col))
                 do (write-char #\Tab s)
                    (incf c (- tw (mod c tw))))
           (loop while (< c target-col)
                 do (write-char #\Space s)
                    (incf c))))))))

(defun indent-to (col &optional minimum)
  "Insert whitespace at point to reach column COL. If MINIMUM is given,
   ensure at least MINIMUM additional columns are inserted, even if we're
   already past COL. Returns final column."
  (let* ((bid     (%current-buffer-id))
         (point   (funcall *point-fn* bid))
         (cur-col (current-column))
         (target  (max col (+ cur-col (or minimum 0)))))
    (cond
      ((<= target cur-col)
       cur-col)
      (t
       (let ((indent-str (%make-indent-string cur-col target)))
         (when (> (length indent-str) 0)
           (funcall *buffer-insert-fn* bid point indent-str)))
       target))))

;;; ── §B  move-to-column ────────────────────────────────────────────────────

(defun %scan-line-to-column (text line-start target)
  "Walk from LINE-START in TEXT until we hit TARGET column or end-of-line.
   Returns (values reached-offset reached-column hit-tab-in-middle).
   If we land exactly on TARGET, reached-column = TARGET. If we land past
   it (e.g. CJK / TAB straddles target), reached-column > TARGET and
   reached-offset is the start of that wide char."
  (let ((i line-start) (col 0) (text-len (length text)))
    (loop
      (when (>= i text-len) (return (values i col nil)))
      (let ((c (char text i)))
        (when (char= c #\Newline)
          (return (values i col nil)))
        (let ((w (char-display-width c col)))
          (when (= col target) (return (values i col nil)))
          (when (> (+ col w) target)
            ;; Landing inside this char.
            (return (values i col (char= c #\Tab))))
          (incf col w)
          (incf i))))))

(defun move-to-column (col &optional force)
  "Move point to column COL on the current line. If COL > end-of-line,
   stop at EOL (or, if FORCE, append SPC to reach it). If COL lands
   inside a TAB or wide character: when FORCE is t and it's a TAB, expand
   the TAB into spaces and land exactly; otherwise stop at the start of
   the wide char. Returns the column actually reached."
  (let* ((bid (%current-buffer-id))
         (text (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (ls   (%line-start text point))
         (le   (%line-end text point)))
    (multiple-value-bind (off reached hit-tab)
        (%scan-line-to-column text ls col)
      (cond
        ;; Reached exactly.
        ((= reached col)
         (funcall *set-point-fn* bid off)
         col)
        ;; Landed inside something or at EOL.
        ((>= off le)
         ;; At or past EOL.
         (cond
           (force
            (let ((delta (- col reached)))
              (when (plusp delta)
                (funcall *buffer-insert-fn* bid le
                         (make-string delta :initial-element #\Space)))
              (funcall *set-point-fn* bid (+ le delta))
              col))
           (t
            (funcall *set-point-fn* bid le)
            reached)))
        ;; Landed inside a TAB or wide char, target between reached and reached+w.
        (hit-tab
         (cond
           (force
            ;; Expand the TAB: replace it with reached → next-tab-stop SPCs,
            ;; but only enough to reach target.
            (let* ((tw (%tab-width))
                   (full (- tw (mod reached tw)))
                   (needed (- col reached)))
              (funcall *buffer-delete-fn* bid off (1+ off))
              (funcall *buffer-insert-fn* bid off
                       (make-string full :initial-element #\Space))
              (funcall *set-point-fn* bid (+ off needed))
              col))
           (t
            (funcall *set-point-fn* bid off)
            reached)))
        ;; Landed inside a wide character (CJK), can't split.
        (t
         (funcall *set-point-fn* bid off)
         reached)))))

;;; ── §B  back-to-indentation ───────────────────────────────────────────────

(defun back-to-indentation ()
  "Move point to first non-whitespace char of current line; on a fully
   blank line, stop at EOL (matches Emacs behaviour)."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (ls    (%line-start text point))
         (le    (%line-end   text point))
         (i     ls))
    (loop while (and (< i le)
                     (let ((c (char text i)))
                       (or (char= c #\Space)
                           (char= c #\Tab))))
          do (incf i))
    (funcall *set-point-fn* bid i)
    i))

;;; ── §B  indent-rigidly ────────────────────────────────────────────────────

(defun %line-bounds (text pos)
  "Return (values line-start line-end) for the line containing POS."
  (values (%line-start text pos) (%line-end text pos)))

(defun %lines-in-range (text from to)
  "Return a fresh list of line-start offsets fully or partially within
   [FROM,TO). Always includes the line containing FROM."
  (let ((starts nil)
        (i from))
    (push (%line-start text i) starts)
    (loop while (< i to) do
      (let ((nl (position #\Newline text :start i :end to)))
        (cond
          ((null nl) (return))
          (t (push (1+ nl) starts) (setf i (1+ nl))))))
    (nreverse starts)))

(defun %line-blank-p (text ls le)
  (loop for i from ls below le
        always (let ((c (char text i)))
                 (or (char= c #\Space) (char= c #\Tab)))))

(defun indent-rigidly (from to count)
  "Add COUNT columns of leading whitespace to each line in [FROM,TO).
   Negative COUNT removes leading whitespace. Blank lines untouched.
   Returns NIL."
  (when (zerop count)
    (return-from indent-rigidly nil))
  (let* ((bid (%current-buffer-id))
         (text (funcall *buffer-text-fn* bid))
         (line-starts (%lines-in-range text from to))
         ;; Process from the end so earlier offsets stay valid.
         (rev (reverse line-starts)))
    (dolist (ls rev)
      (let* ((cur-text (funcall *buffer-text-fn* bid))
             (le (%line-end cur-text ls)))
        (cond
          ((%line-blank-p cur-text ls le)
           nil)
          ((plusp count)
           (funcall *buffer-insert-fn* bid ls
                    (make-string count :initial-element #\Space)))
          (t
           ;; Negative: count leading whitespace, strip min(|count|, leading).
           (let* ((leading
                    (loop for i from ls below le
                          while (let ((c (char cur-text i)))
                                  (or (char= c #\Space) (char= c #\Tab)))
                          count 1))
                  (strip (min leading (- count))))
             (when (plusp strip)
               (funcall *buffer-delete-fn* bid ls (+ ls strip))))))))
    nil))

;;; ── §B  indent-region ─────────────────────────────────────────────────────

(declaim (ftype (function () t) indent-relative))

(defun indent-region (from to)
  "For each line in [FROM,TO), call *indent-line-function* (with point at
   line start). Default is INDENT-RELATIVE. Lines are processed from the
   last back to the first so that line offsets earlier in the buffer
   stay valid even if the indent function inserts / deletes characters."
  (let* ((bid (%current-buffer-id))
         (text (funcall *buffer-text-fn* bid))
         (line-starts (%lines-in-range text from to))
         (fn (or (%indent-line-function) #'indent-relative)))
    (dolist (ls (reverse line-starts))
      (funcall *set-point-fn* bid ls)
      (handler-case (funcall fn) (error () nil)))
    nil))

;;; ── §B  indent-relative ───────────────────────────────────────────────────

(defun indent-relative ()
  "Indent point to align with the next non-whitespace column of the
   previous line, if any. On the first line: no-op. Simplified version
   that just calls indent-to to the previous line's end column."
  (let* ((bid (%current-buffer-id))
         (text (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (ls   (%line-start text point)))
    (when (zerop ls)
      ;; First line — nothing to copy from.
      (return-from indent-relative nil))
    ;; Previous line ends at ls - 1 (the newline before our line start).
    (let* ((prev-end (1- ls))
           (prev-ls  (%line-start text prev-end))
           ;; Find first non-whitespace on previous line, then jump to next
           ;; "tab stop"-like indent column (end of first word, etc.). For
           ;; v0.36 we keep the heuristic simple: target column = column of
           ;; previous line's last non-whitespace +1, or its length.
           (target  (%column-at text prev-end)))
      (declare (ignore prev-ls))
      (when (plusp target)
        (indent-to target)))))

(defun %indent-fallback (bid point)
  "Insert one tab-stop worth of indentation at POINT.  Respects
   indent-tabs-mode: t → literal tab character, nil → tab-width spaces."
  (let ((str (if (%indent-tabs-mode)
                 (string #\Tab)
                 (make-string (%tab-width) :initial-element #\Space))))
    (funcall *buffer-insert-fn* bid point str)
    (funcall *set-point-fn* bid (+ point (length str)))))

;;; ── runtime wireup ────────────────────────────────────────────────────────
;;;
;;; install-wire-vtable wires the vtable hooks to limn:call so the module
;;; works against a real running limn session. Idempotent; bootstrap calls
;;; this once at session start (see limn.lisp / limn-text-mode.lisp).

(defvar *wire-vtable-installed* nil)

(defun %wire-call (cmd &rest kw)
  (let ((sym (find-symbol "CALL" :limn)))
    (when (and sym (fboundp sym))
      (apply (symbol-function sym) cmd kw))))

(defun %wire-resp-data (r)
  (let ((rd (find-symbol "RESPONSE-DATA" :limn/bridge)))
    (when (and rd (fboundp rd) r)
      (funcall (symbol-function rd) r))))

(defun install-wire-vtable ()
  "Bind the vtable to live wire commands. Idempotent."
  (unless *wire-vtable-installed*
    (setf *buffer-text-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/text" :|buffer-id| bid))
                   (d (%wire-resp-data r)))
              (or (getf d :|text|) ""))))
    (setf *buffer-insert-fn*
          (lambda (bid off str)
            (%wire-call "buffer/cursor-set" :|buffer-id| bid :|offset| off)
            (%wire-call "buffer/insert"     :|buffer-id| bid :|text|   str)))
    (setf *buffer-delete-fn*
          (lambda (bid from to)
            (%wire-call "buffer/delete" :|buffer-id| bid
                        :|from| from :|to| to)))
    (setf *point-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/cursor-get" :|buffer-id| bid))
                   (d (%wire-resp-data r)))
              (or (getf d :|offset|) 0))))
    (setf *set-point-fn*
          (lambda (bid off)
            (%wire-call "buffer/cursor-set" :|buffer-id| bid :|offset| off)))
    (setf *buffer-text-len-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/text" :|buffer-id| bid))
                   (d (%wire-resp-data r))
                   (txt (and d (getf d :|text|))))
              (if (stringp txt) (length txt) 0))))
    (setf *wire-vtable-installed* t))
  t)

;;; Install the default indent-line-function now that indent-relative is defined.
;;; v0.37 Phase F: previous code only set the default if cl-user
;;; already had *INDENT-LINE-FUNCTION* interned and bound — which
;;; never happens at load time, so indent-for-tab-command in fresh
;;; sessions saw nil and silently no-op'd ("after TAB key, buffer has
;;; indent (got \"\")" in v036-tab-key-text-mode).  intern guarantees
;;; the symbol exists; proclaim + setf gives it a default value the
;;; buffer-local layer can override per-buffer.
(eval-when (:load-toplevel :execute)
  (let ((sym (intern "*INDENT-LINE-FUNCTION*" :cl-user)))
    (proclaim `(special ,sym))
    (unless (and (boundp sym) (symbol-value sym))
      (setf (symbol-value sym) #'indent-relative))))

;;; ── §B  indent-for-tab-command + newline-and-indent ───────────────────────

(defun indent-for-tab-command ()
  "Invoke the buffer's *indent-line-function*.  v0.37 Phase F: when
   that function leaves point/buffer unchanged (e.g. indent-relative
   on the first line, where there's no prior indent to copy), fall
   back to inserting one tab-stop worth of whitespace at point.
   Matches Emacs `indent-for-tab-command` (which similarly degrades
   to tab-to-tab-stop when the indent function is a no-op).  Without
   this fallback, Tab on a brand-new empty buffer silently did
   nothing, breaking v036-tab-key-text-mode."
  (let* ((bid       (%current-buffer-id))
         (before-pt (and bid (funcall *point-fn* bid)))
         (before-tx (and bid (funcall *buffer-text-fn* bid)))
         (fn        (%indent-line-function)))
    (when fn (funcall fn))
    (when bid
      (let ((after-pt (funcall *point-fn* bid))
            (after-tx (funcall *buffer-text-fn* bid)))
        (when (and (eql before-pt after-pt)
                   (string= (or before-tx "") (or after-tx "")))
          (%indent-fallback bid after-pt))))))

(defun newline-and-indent ()
  "Insert a newline at point, then call indent-line-function on the new line."
  (let* ((bid (%current-buffer-id))
         (point (funcall *point-fn* bid)))
    (funcall *buffer-insert-fn* bid point (string #\Newline))
    (indent-for-tab-command)))
