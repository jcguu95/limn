;;;; limn-pdf-mode — PDF reading mode (SPEC v0.27).
;;;;
;;;; Pure Lisp (除了 §B 用 C++ cmd_buffer_search wire 命令外)。
;;;; 將 sioyek 原本 C++ 寫死的 PDF UX 全數移到 Lisp:
;;;;   §A 翻頁 / 捲動 / 縮放 / 旋轉 / 暗色
;;;;   §B 搜尋（buffer/search wire + Lisp 狀態機）
;;;;   §C Annotation: struct / content-keyed sidecar / 持久化 / 像素 overlay
;;;;   §D TOC (buffer/toc → *PDF-TOC* buffer)
;;;;   §E Bookmark UI (整合 v0.17 bookmark/* wire + v0.24 limn-bookmark)
;;;;   §F Modeline 格式化
;;;;   §G defcustom variables（color / scroll-step / zoom factor）
;;;;   §H discoverability (describe-key 走既有 v0.25 path)
;;;;   §I lifecycle hooks (on-buffer-opened/closed/focused)
;;;;   §O 身份: sidecar 用 content hash 不是 path（dogfooder 搬檔不掉資料）
;;;;   §P 健壯: atomic write、partial-load 容忍壞 entry
;;;;   §R schema versioning + migrate
;;;;   §T last-position resume
;;;;   §V export-org / recent-pdf-list
;;;;
;;;; 依賴：
;;;;   limn/mode     define-mode / activate / find-mode
;;;;   limn/keys     make-keymap / define-key / lookup-sequence
;;;;   limn/cmd      defcommand / *prefix-arg* / *minibuffer-read*
;;;;   limn/runtime  register-engine-default-mode
;;;;   limn/hooks    add-hook
;;;;   limn/custom   defcustom (v0.25)
;;;;   limn/history  add-to-history *search-history* (v0.25)

(in-package #:cl-user)

(defpackage #:limn/pdf-mode
  (:use #:cl)
  (:export
   #:install
   ;; §A vars
   #:*pdf-scroll-step*
   #:*pdf-half-page-step*           ; v0.37 Phase D
   #:*pdf-page-step*                ; v0.39 (C-f / C-b)
   #:*pdf-zoom-in-factor*
   #:*pdf-zoom-out-factor*
   #:*pdf-default-zoom*              ; v0.38 B18
   #:*pdf-annotation-color*
   ;; §B search state
   #:*pdf-search-state* #:make-pdf-search-state
   #:pdf-search-state-buffer-id #:pdf-search-state-query
   #:pdf-search-state-hits #:pdf-search-state-current-index
   #:pdf-search-execute #:pdf-search-overlay-payload
   #:pdf-search-advance #:pdf-search-retreat #:pdf-search-reset
   ;; v0.39.11 A1+A4 additions
   #:pdf-format-search-counter
   #:pdf-search-filter-hits
   #:pdf-search-narrow-by-substring
   #:pdf-search-rank-fuzzy
   #:*pdf-last-search-query* #:*pdf-wrapped-message*
   ;; §C annotation
   #:make-pdf-annotation #:pdf-annotation-p
   #:pdf-annotation-id #:pdf-annotation-page #:pdf-annotation-rects
   #:pdf-annotation-color #:pdf-annotation-note #:pdf-annotation-created-at
   #:pdf-annotations-serialize #:pdf-annotations-deserialize
   #:pdf-annotations-sidecar-path
   #:pdf-annotations-content-hash-sidecar-path
   #:pdf-annotations-save #:pdf-annotations-load
   #:pdf-annotations-overlay-payload
   #:pdf-annotations-for-buffer
   #:pdf-annotations-delete-at-point
   #:pdf-annotations-at-point
   #:pdf-annotation-at
   #:pdf-annotations-migrate
   #:pdf-annotations-export-org
   #:*pdf-annotations-schema-version*
   ;; §D TOC
   #:*pdf-toc-buffer-name*
   #:format-toc-tree #:parse-toc-line-page
   ;; §E bookmark
   #:pdf-set-bookmark-name #:pdf-jump-bookmark-name
   #:pdf-delete-bookmark-name
   ;; §E.2 bookmark sidecar (v0.37 Phase F batch 18 — persistence
   ;; lives in user-Lisp; C++ wire is in-memory only)
   #:pdf-bookmarks-sidecar-path
   #:pdf-bookmarks-save #:pdf-bookmarks-load
   ;; §F modeline
   #:pdf-format-modeline #:pdf-mode-update-modeline
   ;; §I hooks
   #:pdf-mode-on-buffer-opened
   #:pdf-mode-on-buffer-closed
   #:pdf-mode-on-buffer-focused
   ;; §T last-position
   #:pdf-mode-save-last-position
   #:pdf-mode-restore-last-position
   ;; §V workflow features
   #:pdf-recent-list
   ;; vtable
   #:*limn-call-fn* #:*now-fn*
   #:*annotations-write-fn* #:*annotations-read-fn*
   #:*file-content-hash-fn*
   #:*last-position-write-fn* #:*last-position-read-fn*))

(in-package #:limn/pdf-mode)

;;; ═════════════════════════════════════════════════════════════════════
;;; vtable / dynamic injection
;;; ═════════════════════════════════════════════════════════════════════

(defun %call-impl (cmd &rest args)
  "Default *limn-call-fn*: thread through to limn:call when bound."
  (let* ((pkg (find-package :limn))
         (sym (and pkg (find-symbol "CALL" pkg))))
    (when (and sym (fboundp sym))
      (apply (symbol-function sym) cmd args))))

(defvar *limn-call-fn* #'%call-impl
  "Wire call indirection. Tests rebind to a recording mock.")

(defvar *now-fn* #'get-universal-time
  "Clock indirection. Tests rebind to a fake clock.")

(defun %limn-call (cmd &rest args)
  (apply *limn-call-fn* cmd args))

(defun %response-data (r)
  (let ((rd (find-symbol "RESPONSE-DATA" :limn/bridge)))
    (if (and rd (fboundp rd) r)
        (funcall (symbol-function rd) r)
        (getf r :|data|))))

(defun %ok? (r) (eq (getf r :|ok|) t))

;;; ─── file content hash (for sidecar key) ────────────────────────────

(defun %sha256-of-string (s)
  "Quick portable hex digest. Not cryptographic — just a stable digest
   for sidecar key derivation. We use a simple SBCL-friendly polynomial
   hash that matches across runs."
  (let ((acc 14695981039346656037)         ; FNV-1a 64-bit offset basis
        (prime 1099511628211))
    (loop for c across (string s) do
      (setf acc (mod (* (logxor acc (char-code c)) prime)
                      18446744073709551616)))
    (format nil "~(~32,'0x~)" acc)))

(defun %content-hash-impl (path)
  "Default *file-content-hash-fn*: read file content, return hex digest."
  (handler-case
      (with-open-file (in path :direction :input
                                :element-type 'character
                                :external-format :latin1)
        (let* ((sz (file-length in))
               (buf (make-array (or sz 0) :element-type 'character))
               (n (and sz (read-sequence buf in))))
          (declare (ignore n))
          (%sha256-of-string buf)))
    (error () nil)))

(defvar *file-content-hash-fn* #'%content-hash-impl
  "Indirection to compute file-content sha256.
   Tests rebind to inject deterministic hashes.")

;;; ─── annotation I/O vtable ──────────────────────────────────────────

(defun %atomic-write-file (path data)
  "Write DATA to PATH via .tmp + rename for atomicity."
  (ensure-directories-exist path)
  (let ((tmp (concatenate 'string (namestring path) ".tmp")))
    (with-open-file (out tmp :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string data out))
    (rename-file tmp path)))

(defun %read-file-string (path)
  (when (probe-file path)
    (with-open-file (in path :direction :input)
      (let* ((sz (file-length in))
             (buf (make-string (or sz 0))))
        (read-sequence buf in)
        buf))))

(defvar *annotations-write-fn* #'%atomic-write-file
  "Vtable: (path data-string) → write. Default = atomic .tmp+rename.")

(defvar *annotations-read-fn* #'%read-file-string
  "Vtable: (path) → string or NIL. Default = read whole file or NIL.")

(defvar *last-position-write-fn* nil
  "Vtable: (key data-plist) → write last-position. Default uses sidecar dir.")

(defvar *last-position-read-fn* nil
  "Vtable: (key) → plist or NIL.")

;;; ═════════════════════════════════════════════════════════════════════
;;; §G defcustom — user-tunable variables
;;; ═════════════════════════════════════════════════════════════════════

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((custom-pkg (find-package '#:limn/custom)))
    (when (and custom-pkg (find-symbol "DEFCUSTOM" custom-pkg))
      (push :limn/custom-available *features*))))

#+:limn/custom-available
(limn/custom:defcustom *pdf-scroll-step* 0.1
  "Fraction of the visible screen height to scroll on j/k (0.0–1.0).
   Uses view/scroll :dy so it is correct at any zoom level."
  :type 'float :group 'pdf-mode)

#-:limn/custom-available
(defvar *pdf-scroll-step* 0.1
  "Screen-fraction to scroll on j/k (0.0–1.0). Passed to view/scroll :dy.")

#+:limn/custom-available
(limn/custom:defcustom *pdf-zoom-in-factor* 1.25
  "Multiplier for zoom-in (+/=)."
  :type 'number :group 'pdf-mode)

#-:limn/custom-available
(defvar *pdf-zoom-in-factor* 1.25)

#+:limn/custom-available
(limn/custom:defcustom *pdf-zoom-out-factor* 0.8
  "Multiplier for zoom-out (-)."
  :type 'number :group 'pdf-mode)

#-:limn/custom-available
(defvar *pdf-zoom-out-factor* 0.8)

;; v0.38 B18: default zoom applied to newly-opened PDF buffers.
;; NIL means: don't override the engine's natural zoom (1.0).  Set to
;; a number (e.g. 1.5) in user init.lisp to make every PDF open at that
;; zoom level.
(defvar *pdf-default-zoom* nil
  "Override zoom applied on every pdf-mode buffer-opened.  NIL = no override.
   Set in user init.lisp, e.g. (setf limn/pdf-mode:*pdf-default-zoom* 1.5).")

#+:limn/custom-available
(limn/custom:defcustom *pdf-annotation-color* "#FFD700"
  "Default annotation highlight color (hex)."
  :type 'color :group 'pdf-mode)

#-:limn/custom-available
(defvar *pdf-annotation-color* "#FFD700")

;;; ═════════════════════════════════════════════════════════════════════
;;; §B search state + helpers
;;; ═════════════════════════════════════════════════════════════════════

(defstruct pdf-search-state
  (buffer-id   nil)
  (query       nil)
  (hits        nil)             ; list of (:|page| P :|rects| ((x0 y0 x1 y1)...))
  (current-index 0 :type integer))

;; v0.39: per-window search state. Keyed by win-id string so that
;; multiple frames showing the same buffer each have their own
;; independent search cursor. *current-win-id* is a dynamic variable
;; that %wrap-cmd binds from the incoming key event's :win-id field;
;; all search helpers read/write through the accessors below.
(defvar *pdf-search-states* (make-hash-table :test #'equal)
  "win-id → pdf-search-state.  Replaces the old single *pdf-search-state*.")

(defvar *current-win-id* "w1"
  "Dynamic variable holding the win-id of the window that fired the
   current key event.  Bound by %wrap-cmd from ev's :win-id field.")

(defun %search-state ()
  "Return the active search state for the current window."
  (gethash *current-win-id* *pdf-search-states*))

(defun %set-search-state (state)
  "Set (or clear, if STATE is nil) the search state for the current window."
  (if state
      (setf (gethash *current-win-id* *pdf-search-states*) state)
      (remhash *current-win-id* *pdf-search-states*))
  state)

;; Keep the old name as a compatibility alias that reads the focused win.
(defun %compat-search-state ()
  "Return *pdf-search-state* equivalent for the current focused window."
  (%search-state))

;;; --- public export alias (old code that uses *pdf-search-state* directly) --
;;; Nothing outside this file should access *pdf-search-state* directly;
;;; internal helpers all use %search-state / %set-search-state now.
(defvar *pdf-search-state* nil
  "DEPRECATED: old single-slot global.  Kept for external callers only.
   Actual state is in *pdf-search-states* keyed by win-id.")

(defvar *pdf-last-search-query* nil
  "Last query string used for / (Emacs convention: empty input replays).")

(defvar *pdf-wrapped-message* "Wrapped"
  "Text shown in echo area when search wraps.")

(defun %flatten-page-hits (page-hits)
  "Wire `buffer/search` groups hits by page: each entry is
     (:|page| P :|rects| (rect ...) :|texts| (text ...))
   But n/p must navigate ONE OCCURRENCE at a time, not one page at
   a time — otherwise a page with three 'path' matches counts as
   a single index and %select-current-hit ends up spanning rect[0]
   to rect[N-1], swallowing everything between the first and last
   match on that page.

   This helper rewrites the wire payload into a flat per-occurrence
   list: each output hit carries exactly one rect (in :|rects|, so
   pdf-search-overlay-payload's existing dolist still works) and the
   single text excerpt for that occurrence."
  (loop for hit in page-hits
        for page  = (getf hit :|page|)
        for rects = (getf hit :|rects|)
        for texts = (getf hit :|texts|)
        nconc (loop for r in rects
                    for i from 0
                    for tx = (and (consp texts) (nth i texts))
                    collect (list :|page|  page
                                  :|rects| (list r)
                                  :|texts| (and tx (list tx))
                                  :|text|  (or tx "")))))

(defun %do-search-wire (buffer-id query &key case-sensitive)
  "Wire-only helper: do the buffer/search round-trip and install a
   new pdf-search-state with flattened hits.  Does NOT touch
   *pdf-filter-depth* or *pdf-search-overlay-history* — the caller
   decides whether this is a fresh / (clear both) or an M-n re-search
   (preserve history, bump depth).  Returns the new state or NIL."
  (when (and query (> (length query) 0))
    (let* ((r (%limn-call "buffer/search"
                           :|buffer-id| buffer-id
                           :|query| query
                           :|case-sensitive| (if case-sensitive t :false)))
           (d (%response-data r))
           (raw-hits (and d (getf d :|hits|)))
           (flat-hits (%flatten-page-hits (or raw-hits '()))))
      (%set-search-state
       (make-pdf-search-state :buffer-id buffer-id
                               :query query
                               :hits flat-hits
                               :current-index 0))
      (%search-state))))

(defun pdf-search-execute (buffer-id query &key case-sensitive)
  "Fresh / search: wire round-trip + reset filter depth + clear
   overlay history + seed the narrow-line context with this search's
   hit lines (so the FIRST M-n can intersect).  M-n uses
   %do-search-wire directly so it can preserve history."
  (when (and query (> (length query) 0))
    (setf *pdf-last-search-query* query)
    (setf *pdf-filter-depth* 0)             ; fresh search resets filter colors
    (%set-overlay-history nil)               ; fresh search clears prior colors
    (let ((state (%do-search-wire buffer-id query :case-sensitive case-sensitive)))
      ;; Seed narrow context from this search's hit lines.
      (when state
        (%set-narrow-lines
         (%lines-from-hits (pdf-search-state-hits state))))
      ;; v0.25 search-history integration (§T)
      (let ((add (find-symbol "ADD-TO-HISTORY" :limn/history)))
        (when (and add (fboundp add))
          (handler-case
              (funcall (symbol-function add) '*search-history* query)
            (error () nil))))
      state)))

(defun pdf-search-reset ()
  "Clear search state for the current window and remove overlays."
  (%set-search-state nil)
  (setf *pdf-filter-depth* 0)
  (%set-overlay-history nil)
  (%set-narrow-lines nil)
  (%limn-call "view/overlays" :|win-id| *current-win-id* :|layers| '()))

(defun pdf-search-advance (state)
  "Move current-index forward (wrap). Safe on empty/nil hits."
  (when state
    (let ((hits (pdf-search-state-hits state)))
      (when (and (listp hits) (> (length hits) 0))
        (setf (pdf-search-state-current-index state)
              (mod (1+ (pdf-search-state-current-index state))
                   (length hits))))))
  state)

(defun pdf-search-retreat (state)
  (when state
    (let ((hits (pdf-search-state-hits state)))
      (when (and (listp hits) (> (length hits) 0))
        (setf (pdf-search-state-current-index state)
              (mod (1- (pdf-search-state-current-index state))
                   (length hits))))))
  state)

(defun pdf-search-overlay-payload (state &optional color)
  "Generate overlays plist list.  Multi-rect hits each get their own
   overlay entry.

   v0.39.14 user feedback: full-strength 0.60 yellow looked like a
   real annotation highlight and competed visually with the page
   text.  Dropped current/other alphas across both depths.

     depth 0 (/ search):   current 0.42, other 0.18
     depth>0 (M-n / M-f):  current 0.34, other 0.15"
  (let* ((effective-color
           (or color
               (if (zerop *pdf-filter-depth*)
                   "#FFD700"
                   (%pdf-filter-color (1- *pdf-filter-depth*)))))
         (alpha-current (if (zerop *pdf-filter-depth*) 0.42 0.34))
         (alpha-other   (if (zerop *pdf-filter-depth*) 0.18 0.15)))
    (when (and state (pdf-search-state-hits state))
      (let ((current-idx (pdf-search-state-current-index state))
            (acc nil)
            (i 0))
      (dolist (hit (pdf-search-state-hits state))
        (let* ((page (getf hit :|page|))
               (rects (getf hit :|rects|))
               (op (if (= i current-idx) alpha-current alpha-other)))
          (dolist (rect rects)
            (push (list :|type| "rect"
                         :|page| page
                         :|rect| rect
                         :|color| effective-color
                         :|opacity| op)
                  acc)))
        (incf i))
      (nreverse acc)))))

;; v0.39.14 cumulative narrow — keep prior search colors visible.
;;
;; User wanted: `/ path` shows yellow; then `M-n init` ADDS cyan on
;; top, with the yellow still there.  Previously M-n's view/overlays
;; call replaced the whole layer list and the yellow disappeared.
;;
;; *pdf-search-overlay-history* is a per-window list of FROZEN layer-
;; lists from prior search/narrow steps.  pdf-search-reset and a
;; fresh `/` search clear it.  Each M-n appends the CURRENT payload
;; (computed BEFORE the new search) into history, then runs the new
;; search; the next view/overlays sends (history-flat ++ new-layers)
;; so all colors stack visually.  n/p still navigates only the latest
;; search's hits — which matches "the colored prior ones are
;; reference, the current one is what I'm scrolling through".
(defvar *pdf-search-overlay-history* (make-hash-table :test #'equal)
  "win-id → list of frozen overlay layer-lists (each entry is itself
   a plist-of-rects, i.e. the output of pdf-search-overlay-payload
   at the moment that search was done).")

(defun %overlay-history () (gethash *current-win-id* *pdf-search-overlay-history*))
(defun %set-overlay-history (v)
  (if v (setf (gethash *current-win-id* *pdf-search-overlay-history*) v)
        (remhash *current-win-id* *pdf-search-overlay-history*))
  v)

(defun %composite-overlay-layers (state-payload)
  "Concatenate (oldest→newest history) ++ state-payload.  Returns
   the full :|layers| list to ship via view/overlays."
  (let ((history (%overlay-history)))
    (apply #'append
           (append (reverse history)            ; oldest first for stacking
                   (list (or state-payload '()))))))

(defun %emit-search-overlays (state &optional color)
  "Send composite (history + current) view/overlays for STATE.
   Centralised so every search nav command treats the cumulative
   layers uniformly."
  (%limn-call "view/overlays"
              :|win-id| *current-win-id*
              :|layers| (%composite-overlay-layers
                          (pdf-search-overlay-payload state color))))

;; v0.39.15 line-narrow context — what makes M-n actually narrow.
;;
;; Each successful / or M-n stores the (page . normalised-line-text)
;; pairs of its hits' lines into *pdf-narrow-lines*.  The NEXT M-n
;; issues a fresh buffer/search but then keeps only those new hits
;; whose (page, line) is in the stored set; the set is then tightened
;; to those surviving hits.  Successive M-n therefore tighten
;; recursively: M-n init after / path keeps only "init" occurrences
;; on lines that contained "path"; another M-n return keeps only
;; "return" occurrences on lines that contained both.
;;
;; Paragraph-level narrow would need block info from MuPDF that the
;; current :texts wire field doesn't carry — line is what we have
;; today and matches the user's "如果 paragraph 很麻煩，那我們就先做
;; line" instruction.
(defvar *pdf-narrow-lines* (make-hash-table :test #'equal)
  "win-id → list of (page . normalised-line-text) tuples representing
   the intersected line set across the current / + M-n chain.")

(defun %narrow-lines () (gethash *current-win-id* *pdf-narrow-lines*))
(defun %set-narrow-lines (v)
  (if v (setf (gethash *current-win-id* *pdf-narrow-lines*) v)
        (remhash *current-win-id* *pdf-narrow-lines*))
  v)

(defun %normalise-line-text (s)
  "Lowercase + trim + collapse internal whitespace runs."
  (when (stringp s)
    (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) s))
           (lower (string-downcase trimmed))
           (out (make-string-output-stream))
           (prev-space nil))
      (loop for ch across lower
            do (cond
                 ((or (char= ch #\Space) (char= ch #\Tab)
                      (char= ch #\Newline) (char= ch #\Return))
                  (unless prev-space
                    (write-char #\Space out)
                    (setf prev-space t)))
                 (t (write-char ch out) (setf prev-space nil))))
      (get-output-stream-string out))))

(defun %lines-from-hits (hits)
  "Extract the unique (page . normalised-line-text) tuples from HITS."
  (let ((seen (make-hash-table :test #'equal))
        (acc nil))
    (dolist (h hits)
      (let* ((page (getf h :|page|))
             (raw  (or (getf h :|text|)
                       (and (consp (getf h :|texts|))
                            (first (getf h :|texts|)))))
             (norm (and raw (%normalise-line-text raw)))
             (key  (and (integerp page) norm
                        (and (plusp (length norm)) (cons page norm)))))
        (when (and key (not (gethash key seen)))
          (setf (gethash key seen) t)
          (push key acc))))
    (nreverse acc)))

(defun %hits-in-narrow-set (hits narrow-set)
  "Keep only hits whose (page, line-text) is in NARROW-SET.
   NARROW-SET is a list of (page . norm-text) cons cells; we look up
   via a transient hash for O(N+M)."
  (let ((tbl (make-hash-table :test #'equal)))
    (dolist (e narrow-set) (setf (gethash e tbl) t))
    (loop for h in hits
          for page = (getf h :|page|)
          for raw  = (or (getf h :|text|)
                         (and (consp (getf h :|texts|))
                              (first (getf h :|texts|))))
          for norm = (and raw (%normalise-line-text raw))
          when (and (integerp page) norm
                    (gethash (cons page norm) tbl))
            collect h)))

;; v0.39.11 A4 follow-up: track filter depth so successive M-n / M-f
;; rotate colors (mild rainbow).  Reset whenever a fresh / search runs.
(defvar *pdf-filter-depth* 0
  "How many M-n / M-f filters have been chained on top of the latest /
   search.  Reset by pdf-search-execute and pdf-search-reset.
   Per-window via a hash-table would be tidier, but the current
   single-window dogfood doesn't need it; promote later if needed.")

(defparameter *pdf-filter-colors*
  #("#00DDFF"   ; cyan — first narrow
    "#FF66CC"   ; magenta — second
    "#66FF66"   ; mint
    "#FFAA00"   ; orange
    "#AA66FF"  ) ; violet
  "Color cycle for narrowed-result overlays.")

(defun %pdf-filter-color (&optional depth)
  (aref *pdf-filter-colors*
        (mod (or depth *pdf-filter-depth*)
             (length *pdf-filter-colors*))))

;;; --- v0.39.11 A1: match counter -----------------------------------

(defun pdf-format-search-counter (&optional state)
  "Return string \"N / T\" (1-indexed current / total hits) for STATE
   or the current window's state when omitted.  NIL if no active search."
  (let ((s (or state (%search-state))))
    (when s
      (let ((hits (pdf-search-state-hits s)))
        (when (and (consp hits) (plusp (length hits)))
          (format nil "~a / ~a"
                  (1+ (pdf-search-state-current-index s))
                  (length hits)))))))

(defun %refresh-search-modeline ()
  "Re-emit the full modeline so the search counter (\"N / T\") appears
   in BOTH :|left| (embedded — guaranteed visible regardless of Qt's
   modeline column layout) and :|right|.  Called after every
   search-state mutation."
  (handler-case
      (let* ((bid (and (find-package :limn/pdf-mode)
                       (find-symbol "%FOCUSED-BUFFER-ID" :limn/pdf-mode)))
             (path-fn (and (find-package :limn/pdf-mode)
                           (find-symbol "*BUFFER-ID-TO-PATH*" :limn/pdf-mode)))
             (bid-v (and bid (fboundp bid) (funcall (symbol-function bid))))
             (path (and bid-v path-fn (boundp path-fn)
                        (gethash bid-v (symbol-value path-fn)))))
        (pdf-mode-update-modeline :buffer-id bid-v :path path))
    (error () nil)))

;;; v0.39.12 follow-up — auto-select the current hit on every n/p so
;;; the user can M-w copy it, and so they visually know WHICH match is
;;; current (otherwise "match 3 / 17" in modeline says nothing about
;;; where on the page).  Emits view/selection-set with begin =
;;; top-left of the hit's first rect, end = bottom-right of the
;;; LAST rect on the same page (handles multi-rect line wraps).
(defun %select-current-hit (state)
  (when state
    (let* ((hits (pdf-search-state-hits state))
           (idx  (pdf-search-state-current-index state))
           (hit  (and (consp hits) (nth idx hits)))
           (page (and hit (getf hit :|page|)))
           (rects (and hit (getf hit :|rects|)))
           (first-r (and (consp rects) (first rects)))
           (last-r  (and (consp rects)
                         (or (car (last rects)) first-r))))
      (when (and (integerp page) first-r last-r
                 (>= (length first-r) 4) (>= (length last-r) 4))
        (handler-case
            (%limn-call "view/selection-set"
                        :|win-id| *current-win-id*
                        :|begin| (list :|page| page
                                       :|x|    (nth 0 first-r)
                                       :|y|    (nth 1 first-r))
                        :|end|   (list :|page| page
                                       :|x|    (nth 2 last-r)
                                       :|y|    (nth 3 last-r))
                        :|mode|  "char")
          (error () nil))))))

;;; --- v0.39.11 A4: narrow + fuzzy filters --------------------------

(defun pdf-search-filter-hits (state pred)
  "Walk STATE's hits.  For each rect inside each hit, call (PRED page
   rect text).  Build a new hits list keeping only rects whose PRED
   returned non-NIL (along with their parallel :|texts| entry).  Hits
   that lose all rects are dropped.  Returns a NEW hits list — does
   not mutate STATE.  Order-preserving."
  (let ((kept-hits nil))
    (dolist (hit (pdf-search-state-hits state))
      (let* ((page  (getf hit :|page|))
             (rects (getf hit :|rects|))
             (texts (getf hit :|texts|))
             (kept-r nil)
             (kept-t nil)
             (i 0))
        (dolist (r rects)
          (let ((tx (and (consp texts) (nth i texts))))
            (when (funcall pred page r (or tx ""))
              (push r  kept-r)
              (push tx kept-t)))
          (incf i))
        (when kept-r
          (push (list :|page|  page
                      :|rects| (nreverse kept-r)
                      :|texts| (nreverse kept-t))
                kept-hits))))
    (nreverse kept-hits)))

(defun pdf-search-narrow-by-substring (state substring)
  "Return new hits list keeping only rects whose :|texts| line contains
   SUBSTRING (case-insensitive)."
  (let ((needle (string-downcase substring)))
    (pdf-search-filter-hits
     state
     (lambda (page rect text)
       (declare (ignore page rect))
       (and (stringp text)
            (search needle (string-downcase text)))))))

(defun pdf-search-rank-fuzzy (state query)
  "Return new hits list: rects scored by limn/search::fuzzy-score
   against QUERY; zero-score rects dropped.  Within each hit, rects
   are reordered best-first; the hit list itself stays in document
   order (we don't reorder pages, to keep next/prev intuitive)."
  (let ((q (string-downcase query))
        (scorer (find-symbol "FUZZY-SCORE" :limn/search)))
    (unless (and scorer (fboundp scorer))
      (return-from pdf-search-rank-fuzzy
        (pdf-search-state-hits state)))
    (let ((acc nil))
      (dolist (hit (pdf-search-state-hits state))
        (let* ((page  (getf hit :|page|))
               (rects (getf hit :|rects|))
               (texts (getf hit :|texts|))
               (scored nil))
          (loop for r in rects
                for i from 0
                for tx = (and (consp texts) (nth i texts))
                for s = (and (stringp tx)
                             (funcall (symbol-function scorer)
                                      q (string-downcase tx)))
                when (and (numberp s) (plusp s))
                  do (push (cons s (cons r tx)) scored))
          (when scored
            (let* ((sorted (sort scored #'> :key #'car))
                   (kept-r (mapcar (lambda (e) (cadr e)) sorted))
                   (kept-t (mapcar (lambda (e) (cddr e)) sorted)))
              (push (list :|page| page
                          :|rects| kept-r
                          :|texts| kept-t)
                    acc)))))
      (nreverse acc))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §C annotation — struct + sidecar I/O + content-hash key + schema
;;; ═════════════════════════════════════════════════════════════════════

(defvar *pdf-annotations-schema-version* 1
  "Current sidecar schema version. Bumped on incompatible changes.")

(defvar *uuid-counter* 0)
(defun %fresh-uuid ()
  (format nil "u-~a-~a"
          (funcall *now-fn*)
          (incf *uuid-counter*)))

;; --- v0.39.11 in-memory cache (D2) -----------------------------------
;; Eliminates re-read-sidecar-per-mouse-event hot path. Cache entries are
;; plain plists keyed by PATH (string=):
;;   (:|loaded-at| TS
;;    :|by-page|   hash-table[page → list-of-annotation]
;;    :|all|       list-of-annotation)
;; Built lazily by %annotations-cache-build, populated eagerly by
;; pdf-mode-on-buffer-opened, invalidated by pdf-annotations-save.
;; pdf-annotation-at remains pure (works on caller-supplied lists) so
;; existing tests that don't go through a path still pass.
(defvar *pdf-annotations-cache* (make-hash-table :test #'equal)
  "path-string → cache-entry plist. See module comment above.")

(defstruct (pdf-annotation
            (:constructor %raw-make-pdf-annotation))
  (id        nil)
  (page      0 :type integer)
  (rects     nil)               ; list of (x0 y0 x1 y1)
  (color     "#FFD700")
  (note      nil)
  (created-at 0))

;; Public constructor: fills id / created-at via vtable when caller omits them.
;; Has to handle the case where caller doesn't pass :color either — fall back to
;; *pdf-annotation-color* (defcustom).
(defun make-pdf-annotation (&key id page rects (color nil color-p)
                                  note created-at)
  (%raw-make-pdf-annotation
   :id (or id (%fresh-uuid))
   :page (or page 0)
   :rects rects
   :color (if color-p color *pdf-annotation-color*)
   :note note
   :created-at (or created-at (funcall *now-fn*))))

(defun pdf-annotations-serialize (anns)
  "Serialize list of pdf-annotation to a versioned schema string:
   (:VERSION 1 :ANNOTATIONS ((:id ... :page ... ...) ...))"
  (let ((entries
          (mapcar (lambda (a)
                    (list :id        (pdf-annotation-id a)
                          :page      (pdf-annotation-page a)
                          :rects     (pdf-annotation-rects a)
                          :color     (pdf-annotation-color a)
                          :note      (pdf-annotation-note a)
                          :created-at (pdf-annotation-created-at a)))
                  anns)))
    (with-output-to-string (out)
      (write (list :version *pdf-annotations-schema-version*
                    :annotations entries)
              :stream out :readably t))))

(defun %try-read-form (str)
  "Read one s-expr from STR; return NIL on read error."
  (handler-case
      (with-input-from-string (in str) (read in nil nil))
    (error () nil)))

(defun pdf-annotations-deserialize (str)
  "Parse a serialized sidecar back to list of pdf-annotation.
   Tolerant of partial corruption: skip individual bad entries; if
   the outer form is unreadable, try a permissive recovery."
  (when (and str (stringp str) (> (length str) 0))
    (let ((form (%try-read-form str)))
      (cond
        ((null form) nil)
        ((and (listp form) (or (eq (getf form :version) 0)
                                (eq (getf form :version) :v0)
                                (eq (getf form :version) nil)))
         ;; Either ancient (no version) or v0 — migrate first.
         (let ((migrated (pdf-annotations-migrate form)))
           (%decode-entries (getf migrated :annotations))))
        ((and (listp form) (getf form :annotations))
         (%decode-entries (getf form :annotations)))
        ((listp form)
         ;; Permissive: form is a raw list of entry-plists.
         (%decode-entries form))
        (t nil)))))

(defun %decode-entries (entries)
  (let ((acc nil))
    (dolist (e entries)
      (let ((a (handler-case (%decode-one e)
                 (error () nil))))
        (when a (push a acc))))
    (nreverse acc)))

(defun %decode-one (e)
  (when (and (listp e) (getf e :id))
    (make-pdf-annotation
     :id        (getf e :id)
     :page      (getf e :page 0)
     :rects     (getf e :rects)
     :color     (or (getf e :color) "#FFD700")
     :note      (getf e :note)
     :created-at (or (getf e :created-at) 0))))

(defun pdf-annotations-migrate (data)
  "Migrate a versioned-or-not plist up to current schema version.
   Idempotent: returns DATA unchanged if already current."
  (cond
    ((null data) (list :version *pdf-annotations-schema-version*
                       :annotations '()))
    ((not (listp data)) data)
    (t
     (let ((v (or (getf data :version) 0)))
       (cond
         ((eql v *pdf-annotations-schema-version*) data)
         ((< v *pdf-annotations-schema-version*)
          ;; v0 → v1: same shape, just stamp version.
          (list :version *pdf-annotations-schema-version*
                :annotations (or (getf data :annotations) '())))
         (t data))))))

(defun %home ()
  (or (ignore-errors (sb-posix:getenv "HOME"))
      (namestring (user-homedir-pathname))))

(defun pdf-annotations-sidecar-path (path)
  "Path-keyed sidecar (legacy / fallback)."
  (let ((slug (%sha256-of-string (namestring path))))
    (pathname (format nil "~a/.limn/annotations/~a.lisp"
                       (%home) slug))))

(defun pdf-annotations-content-hash-sidecar-path (path)
  "Content-keyed sidecar (preferred; survives rename/move)."
  (let ((hash (funcall *file-content-hash-fn* path)))
    (when hash
      (pathname (format nil "~a/.limn/annotations/~a.lisp"
                         (%home) hash)))))

(defun %effective-sidecar-path (path)
  "Prefer content-hashed path; fall back to path-keyed."
  (or (pdf-annotations-content-hash-sidecar-path path)
      (pdf-annotations-sidecar-path path)))

(defun pdf-annotations-save (path anns)
  "Write ANNS list to sidecar for PATH. Returns t on success, nil on
   silent-skip; signals error / emits message on hard fail (no silent ok).
   Always invalidates the in-memory cache for PATH (next read rebuilds)."
  (let ((spath (%effective-sidecar-path path))
        (data (pdf-annotations-serialize anns)))
    ;; Invalidate first so a subsequent read can't observe stale state
    ;; even if the write below errors (we'd rather rebuild than serve stale).
    (%annotations-cache-invalidate path)
    (handler-case
        (progn (funcall *annotations-write-fn* spath data) t)
      (error (e)
        (handler-case
            (%limn-call "message/echo"
                         :|text| (format nil "annotation save failed: ~a" e))
          (error () nil))
        nil))))

(defun pdf-annotations-load (path)
  "Read sidecar for PATH. Returns list (possibly empty). Never errors."
  (handler-case
      (let* ((spath-content (pdf-annotations-content-hash-sidecar-path path))
             (spath-path    (pdf-annotations-sidecar-path path))
             (data
               (or (and spath-content
                        (funcall *annotations-read-fn* spath-content))
                   ;; Fallback to legacy path-keyed sidecar.
                   (and spath-path
                        (funcall *annotations-read-fn* spath-path)))))
        (or (pdf-annotations-deserialize data) '()))
    (error () '())))

;; --- v0.39.11 cache helpers + query surface (D2) ---------------------

(defun %path-key (path)
  "Normalise PATH to a string suitable for keying *pdf-annotations-cache*."
  (cond ((null path) nil)
        ((stringp path) path)
        ((pathnamep path) (namestring path))
        (t (princ-to-string path))))

(defun %annotations-cache-build (path)
  "Load sidecar for PATH, build by-page index, store in cache. Returns
   the cache-entry plist. Safe to call repeatedly — rebuilds each call."
  (let* ((key (%path-key path))
         (all (pdf-annotations-load path))
         (by-page (make-hash-table :test #'eql)))
    (dolist (a all)
      (let ((p (pdf-annotation-page a)))
        (push a (gethash p by-page))))
    ;; Preserve insertion order within each page bucket (we pushed, so reverse).
    (maphash (lambda (k v) (setf (gethash k by-page) (nreverse v))) by-page)
    (let ((entry (list :|loaded-at| (funcall *now-fn*)
                       :|by-page|   by-page
                       :|all|       all)))
      (when key (setf (gethash key *pdf-annotations-cache*) entry))
      entry)))

(defun %annotations-cache-get (path)
  "Return the cache entry for PATH, building on miss."
  (let ((key (%path-key path)))
    (or (and key (gethash key *pdf-annotations-cache*))
        (%annotations-cache-build path))))

(defun %annotations-cache-invalidate (path)
  "Drop the cache entry for PATH. Called from pdf-annotations-save."
  (let ((key (%path-key path)))
    (when key (remhash key *pdf-annotations-cache*))))

(defun pdf-annotations-on-page (path page)
  "O(1) lookup: all annotations on PAGE for PATH. Builds cache on miss."
  (let* ((entry (%annotations-cache-get path))
         (by-page (getf entry :|by-page|)))
    (or (and by-page (gethash page by-page)) '())))

(defun pdf-annotations-pages-with-notes (path)
  "Sorted list of pages on PATH that have at least one annotation whose
   :type is :note or :both. Consumed by the icon-marker agent (D4)."
  (let* ((entry (%annotations-cache-get path))
         (by-page (getf entry :|by-page|))
         (pages '()))
    (when by-page
      (maphash (lambda (p anns)
                 (when (some (lambda (a)
                               (let ((tp (pdf-annotation-type a)))
                                 (or (eq tp :note) (eq tp :both))))
                             anns)
                   (push p pages)))
               by-page))
    (sort pages #'<)))

(defun pdf-annotations-with-tag (path tag)
  "Linear scan over all annotations for PATH; return those whose :tags
   contain TAG (string=). Consumed by annotation-UX agent (D5)."
  (let* ((entry (%annotations-cache-get path))
         (all   (getf entry :|all|)))
    (remove-if-not
     (lambda (a)
       (and (pdf-annotation-tags a)
            (find tag (pdf-annotation-tags a) :test #'string=)))
     all)))

(defun pdf-annotations-overlay-payload (anns)
  "Convert annotation list to view/overlays payload."
  (mapcar (lambda (a)
            (list :|type| "rect"
                  :|page| (pdf-annotation-page a)
                  ;; first rect (multi-rect anno: caller expands if needed)
                  :|rect| (first (pdf-annotation-rects a))
                  :|color| (pdf-annotation-color a)
                  :|opacity| 0.6))
          anns))

(defun pdf-annotations-for-buffer (path)
  "Convenience: overlay-payload, via cache (builds on miss)."
  (let ((entry (%annotations-cache-get path)))
    (pdf-annotations-overlay-payload (getf entry :|all|))))

(defun pdf-annotation-at (anns page x y)
  "First annotation in ANNS whose rect contains (page, x, y), or NIL."
  (find-if (lambda (a)
             (and (= page (pdf-annotation-page a))
                  (some (lambda (r)
                          (and (<= (first r)  x) (<= x (third r))
                               (<= (second r) y) (<= y (fourth r))))
                        (pdf-annotation-rects a))))
           anns))

(defun pdf-annotations-at-point (path page x y)
  "Look up + return the annotation at (page, x, y) on PATH's sidecar.
   Goes through the page index (cache) to skip annotations on other
   pages — significant speedup for sidecars with many pages."
  (pdf-annotation-at (pdf-annotations-on-page path page) page x y))

(defun pdf-annotations-delete-at-point (path page x y)
  "Delete the annotation at (page, x, y) from PATH's sidecar (no-op if none)."
  (let* ((anns (pdf-annotations-load path))
         (target (pdf-annotation-at anns page x y)))
    (when target
      (let ((remaining (remove target anns :test #'eq)))
        (pdf-annotations-save path remaining)
        (%refresh-overlays path remaining)
        t))))

(defun %refresh-overlays (path anns)
  (declare (ignore path))
  (%limn-call "view/overlays" :|win-id| "w1"
               :|layers| (pdf-annotations-overlay-payload anns)))

(defun pdf-annotations-export-org (anns path)
  "Format ANNS as an org-mode document."
  (let ((basename (file-namestring (pathname path))))
    (with-output-to-string (out)
      (format out "* Annotations: ~a~%" basename)
      (dolist (a anns)
        (format out "** Page ~a~%" (1+ (pdf-annotation-page a)))
        (when (pdf-annotation-note a)
          (format out "   ~a~%" (pdf-annotation-note a)))
        (format out "   :PROPERTIES:~%")
        (format out "   :ID: ~a~%" (pdf-annotation-id a))
        (format out "   :CREATED-AT: ~a~%" (pdf-annotation-created-at a))
        (format out "   :END:~%")))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §A — navigation commands (defined in CL-USER)
;;;
;;; Each command's body is a top-level defun (so install can re-register
;;; with limn/cmd:register-command after any test calls clear-commands).
;;; ═════════════════════════════════════════════════════════════════════

(in-package #:cl-user)

(defvar limn/pdf-mode::*command-registry* nil
  "Alist of (CMD-NAME SPEC BODY-FN). install iterates to (re-)register.")

(defun limn/pdf-mode::%register-pdf-commands ()
  "Re-install every pdf-* command into limn/cmd's *commands* registry.
   Survives tests that call clear-commands between runs."
  (let ((reg (find-symbol "REGISTER-COMMAND" :limn/cmd)))
    (when (and reg (fboundp reg))
      (dolist (entry limn/pdf-mode::*command-registry*)
        (destructuring-bind (name spec body-fn) entry
          (funcall (symbol-function reg) name spec nil body-fn))))))

(defmacro limn/pdf-mode::%defcmd (name spec body)
  "Like defcommand, but also push into *command-registry* so install
   can re-register after clear-commands."
  (let ((body-var (gensym "BODY"))
        (reg-var  (gensym "REG")))
    `(let ((,body-var ,body)
           (,reg-var (find-symbol "REGISTER-COMMAND" :limn/cmd)))
       (when (and ,reg-var (fboundp ,reg-var))
         (funcall (symbol-function ,reg-var) ',name ,spec nil ,body-var))
       (setf limn/pdf-mode::*command-registry*
             (cons (list ',name ,spec ,body-var)
                    (remove-if (lambda (e) (eq (first e) ',name))
                                limn/pdf-mode::*command-registry*)))
       ',name)))

(defvar limn/pdf-mode::*last-key* nil
  "Most recently dispatched key, bound by keymap wrapper.")

(defun limn/pdf-mode::%focused-buffer-id ()
  "Read buffer-id of currently focused window via view/get."
  (let* ((r (limn/pdf-mode::%limn-call "view/get" :|win-id| "w1"))
         (d (limn/pdf-mode::%response-data r)))
    (getf d :|buffer-id|)))

(defun limn/pdf-mode::%focused-view ()
  "Return current view state plist (page/zoom/page-count/offset-y/...)."
  (let* ((r (limn/pdf-mode::%limn-call "view/get" :|win-id| "w1"))
         (d (limn/pdf-mode::%response-data r)))
    (or d '())))

(defun limn/pdf-mode::%page-set (page)
  (limn/pdf-mode::%limn-call "view/set" :|win-id| "w1" :|page| page))

(defun limn/pdf-mode::%zoom-set (z)
  (limn/pdf-mode::%limn-call "view/set" :|win-id| "w1" :|zoom| z))

(defun limn/pdf-mode::%clamp-page (page page-count)
  (max 0 (min page (1- (max 1 page-count)))))

(limn/pdf-mode::%defcmd pdf-next-page nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (p (or (getf v :|page|) 0))
           (pc (or (getf v :|page-count|) 1)))
      (limn/pdf-mode::%page-set
       (limn/pdf-mode::%clamp-page (1+ p) pc)))))

(limn/pdf-mode::%defcmd pdf-prev-page nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (p (or (getf v :|page|) 0))
           (pc (or (getf v :|page-count|) 1)))
      (limn/pdf-mode::%page-set
       (limn/pdf-mode::%clamp-page (1- p) pc)))))

(limn/pdf-mode::%defcmd pdf-first-page nil
  (lambda ()
    (limn/pdf-mode::%page-set 0)))

(limn/pdf-mode::%defcmd pdf-last-page nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (pc (or (getf v :|page-count|) 1)))
      (limn/pdf-mode::%page-set (1- pc)))))

(limn/pdf-mode::%defcmd pdf-goto-page "p"
  (lambda (prefix)
    ;; v0.38 B11: with prefix N → page N; without prefix → last page.
    ;; This matches vim convention: `5G` jumps to page 5, plain `G`
    ;; jumps to end.  Old behavior (no prefix → page 0) was unused.
    (let* ((v (limn/pdf-mode::%focused-view))
           (pc (or (getf v :|page-count|) 1))
           (default-target (max 0 (1- pc)))
           (target (limn/pdf-mode::%clamp-page (or prefix default-target) pc)))
      (limn/pdf-mode::%page-set target))))

;; v0.38 B13: pdf-scroll-down/up honor numeric prefix-arg.
;; `5j` scrolls 5× the base step; plain `j` scrolls 1×.
;;
;; v0.39: switched from view/set :offset-y (raw document coords — step 0.1
;; doc-unit while pages are ~840 units tall → effectively no movement) to
;; view/scroll :dy (screen fraction, zoom-invariant).
(limn/pdf-mode::%defcmd pdf-scroll-down "p"
  (lambda (&optional prefix)
    (let* ((n    (or prefix 1))
           (step (* n limn/pdf-mode:*pdf-scroll-step*)))
      (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1" :|dy| step))))

(limn/pdf-mode::%defcmd pdf-scroll-up "p"
  (lambda (&optional prefix)
    (let* ((n    (or prefix 1))
           (step (* n limn/pdf-mode:*pdf-scroll-step*)))
      (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1" :|dy| (- step)))))

(limn/pdf-mode::%defcmd pdf-zoom-in nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (z (or (getf v :|zoom|) 1.0)))
      (limn/pdf-mode::%zoom-set (* z limn/pdf-mode:*pdf-zoom-in-factor*)))))

(limn/pdf-mode::%defcmd pdf-zoom-out nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (z (or (getf v :|zoom|) 1.0)))
      (limn/pdf-mode::%zoom-set (* z limn/pdf-mode:*pdf-zoom-out-factor*)))))

(limn/pdf-mode::%defcmd pdf-zoom-reset nil
  (lambda ()
    (limn/pdf-mode::%zoom-set 1.0)))

(limn/pdf-mode::%defcmd pdf-fit-width nil
  (lambda ()
    ;; Simplification: send a hint; C++ engine-params interprets "fit-width".
    (limn/pdf-mode::%limn-call "bridge/engine-params"
                                :|win-id| "w1" :|fit| "width")))

(limn/pdf-mode::%defcmd pdf-toggle-dark nil
  (lambda ()
    ;; v0.37 fixup: was calling "bridge/engine-params" which is NOT a
    ;; registered wire command — silently failed.  Strict pixel test
    ;; for "dark mode preserves overlay" caught it because dark mode
    ;; never actually toggled in any prior run.  Real path is
    ;; view/set with :|engine-params| nested object (see C++
    ;; cmd_view_set line ~709).
    ;;
    ;; v0.38 W05 fix (G'-2): reader was reading top-level :|dark-mode|,
    ;; but C++ collect_view_state nests it under :|engine-params|. So
    ;; cur always returned NIL → next always computed T → toggle was
    ;; one-way (off→on works once, on→off never).  Read nested path.
    (let* ((v (limn/pdf-mode::%focused-view))
           (cur (getf (getf v :|engine-params|) :|dark-mode|))
           (next (if (or (null cur) (eq cur :false)) t :false)))
      (limn/pdf-mode::%limn-call "view/set"
                                  :|win-id| "w1"
                                  :|engine-params| (list :|dark-mode| next)))))

(limn/pdf-mode::%defcmd pdf-rotate-cw nil
  (lambda ()
    ;; v0.38 B1 fix: was calling "bridge/engine-params" which is NOT a
    ;; registered wire cmd (same bug as v0.37 G'-1 toggle-dark, never
    ;; fixed for rotate-cw).  Real path is view/set with :|engine-params|
    ;; nested object.  Also: rotation lives at engine-params/rotation,
    ;; not top-level (same G'-2 issue as dark-mode reader).
    (let* ((v (limn/pdf-mode::%focused-view))
           (rot (or (getf (getf v :|engine-params|) :|rotation|) 0))
           (next (mod (+ rot 90) 360)))
      (limn/pdf-mode::%limn-call "view/set"
                                  :|win-id| "w1"
                                  :|engine-params| (list :|rotation| next)))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §B search commands
;;; ═════════════════════════════════════════════════════════════════════

(limn/pdf-mode::%defcmd pdf-isearch-forward nil
  (lambda ()
    (let* ((reader (find-symbol "*MINIBUFFER-READ*" :limn/cmd))
           (read-fn (and reader (boundp reader) (symbol-value reader)))
           (query (and read-fn (funcall read-fn "Search: "))))
      (when (and (stringp query) (= 0 (length query)))
        (setf query limn/pdf-mode:*pdf-last-search-query*))
      (when (and (stringp query) (> (length query) 0))
        (let* ((buf (limn/pdf-mode::%focused-buffer-id))
               (v   (limn/pdf-mode::%focused-view))
               (cur-page (or (getf v :|page|) 0))
               (state (limn/pdf-mode:pdf-search-execute buf query)))
          (when state
            ;; v0.39.11 follow-up: start from the user's CURRENT page
            ;; (find first hit whose page >= cur-page); fall back to
            ;; first hit if everything is behind us.  This stops the
            ;; jarring "jump back to page 0" behaviour the user hit
            ;; in dogfood.
            (let* ((hits (limn/pdf-mode:pdf-search-state-hits state))
                   (forward-idx
                     (and (consp hits)
                          (loop for h in hits
                                for i from 0
                                when (let ((p (getf h :|page|)))
                                       (and (integerp p) (>= p cur-page)))
                                  return i)))
                   (start-idx (or forward-idx 0)))
              (when (consp hits)
                (setf (limn/pdf-mode:pdf-search-state-current-index state)
                      start-idx)
                (let* ((hit (nth start-idx hits))
                       (p   (getf hit :|page|)))
                  (when (integerp p) (limn/pdf-mode::%page-set p)))))
            (limn/pdf-mode::%emit-search-overlays state)
            (limn/pdf-mode::%select-current-hit state)
            (limn/pdf-mode::%refresh-search-modeline)))))))

(limn/pdf-mode::%defcmd pdf-isearch-next nil
  (lambda ()
    (let ((s (limn/pdf-mode::%search-state)))
      (when s
        (let* ((hits (limn/pdf-mode:pdf-search-state-hits s))
               (old-idx (limn/pdf-mode:pdf-search-state-current-index s)))
          (limn/pdf-mode:pdf-search-advance s)
          (let ((new-idx (limn/pdf-mode:pdf-search-state-current-index s)))
            ;; wrap detection: old was last, new is 0
            (when (and (consp hits)
                       (= old-idx (1- (length hits)))
                       (= new-idx 0))
              (limn/pdf-mode::%limn-call
               "message/echo" :|text| limn/pdf-mode:*pdf-wrapped-message*)))
          ;; navigate
          (when (consp hits)
            (let* ((hit (nth (limn/pdf-mode:pdf-search-state-current-index s)
                              hits))
                   (p (getf hit :|page|)))
              (when (integerp p) (limn/pdf-mode::%page-set p))))
          (limn/pdf-mode::%emit-search-overlays s)
          (limn/pdf-mode::%select-current-hit s)
          (limn/pdf-mode::%refresh-search-modeline))))))

(limn/pdf-mode::%defcmd pdf-isearch-prev nil
  (lambda ()
    (let ((s (limn/pdf-mode::%search-state)))
      (when s
        (limn/pdf-mode:pdf-search-retreat s)
        (let* ((hits (limn/pdf-mode:pdf-search-state-hits s)))
          (when (consp hits)
            (let* ((hit (nth (limn/pdf-mode:pdf-search-state-current-index s)
                              hits))
                   (p (getf hit :|page|)))
              (when (integerp p) (limn/pdf-mode::%page-set p)))))
        (limn/pdf-mode::%emit-search-overlays s)
        (limn/pdf-mode::%select-current-hit s)
        (limn/pdf-mode::%refresh-search-modeline)))))

(limn/pdf-mode::%defcmd pdf-isearch-quit nil
  (lambda ()
    ;; v0.37 Phase F: when the minibuffer is open (we're mid-read, or
    ;; some other command left it open), delegate to the global
    ;; keyboard-quit so the standard cancel path runs — minibuffer
    ;; reader sees minibuffer-cancelled, the bind wrapper swallows
    ;; that, and minibuffer/close fires.  Otherwise this binding would
    ;; shadow C-g's normal "close minibuffer" semantics for users in
    ;; pdf-mode (batch-os-demo: "minibuffer closed after C-g"
    ;; regressed when pdf-mode-map first got its own C-g binding).
    ;; When the minibuffer is closed, pdf-isearch-quit's job is the
    ;; search-state reset (clears the on-screen highlights left from
    ;; the last search) — covered by v027-search Ω4.
    (let* ((mb-r (handler-case
                     (limn/pdf-mode::%limn-call "minibuffer/get")
                   (error () nil)))
           (mb-d (limn/pdf-mode::%response-data mb-r))
           ;; The bridge's JSON false decodes to the keyword :false, NOT
           ;; NIL — so a plain (and mb-d (getf mb-d :|open|)) treats a
           ;; closed minibuffer as "open" (any non-nil keyword is truthy
           ;; in CL).  v027-search Ω4 was the symptom: C-g delegated to
           ;; keyboard-quit instead of running pdf-search-reset, and
           ;; overlays stayed on screen.
           (mb-open (and mb-d (eq (getf mb-d :|open|) t))))
      (cond
        (mb-open
         (let* ((kq (find-symbol "KEYBOARD-QUIT" :limn/runtime))
                (call-int (find-symbol "CALL-INTERACTIVELY" :limn/cmd)))
           (if (and kq call-int (fboundp call-int))
               (handler-case (funcall call-int kq) (error () nil))
               ;; Fallback: just close the minibuffer.
               (handler-case (limn/pdf-mode::%limn-call "minibuffer/close")
                 (error () nil)))))
        (t
         (limn/pdf-mode:pdf-search-reset)
         (limn/pdf-mode::%refresh-search-modeline))))))

;;; v0.37 Phase D: search backward.  Same prompt as forward but the
;;; result-cursor starts at the last hit (vim ? semantic).  Reuses the
;;; existing search engine — we just reverse the initial index after
;;; the scan returns.
(limn/pdf-mode::%defcmd pdf-isearch-backward nil
  (lambda ()
    (let* ((reader (find-symbol "*MINIBUFFER-READ*" :limn/cmd))
           (read-fn (and reader (boundp reader) (symbol-value reader)))
           (query (and read-fn (funcall read-fn "Search backward: "))))
      (when (and (stringp query) (= 0 (length query)))
        (setf query limn/pdf-mode:*pdf-last-search-query*))
      (when (and (stringp query) (> (length query) 0))
        (let* ((buf (limn/pdf-mode::%focused-buffer-id))
               (state (limn/pdf-mode:pdf-search-execute buf query))
               (hits (and state (limn/pdf-mode:pdf-search-state-hits state))))
          (when (and state (consp hits))
            ;; Position result-cursor at the LAST hit instead of the first
            ;; so the user lands on the latest match (vim ? semantic).
            (setf (limn/pdf-mode:pdf-search-state-current-index state)
                  (1- (length hits)))
            (limn/pdf-mode::%emit-search-overlays state)
            (let* ((p (getf (nth (1- (length hits)) hits) :|page|)))
              (when (integerp p)
                (limn/pdf-mode::%page-set p)))
            (limn/pdf-mode::%select-current-hit state)
            (limn/pdf-mode::%refresh-search-modeline)))))))

;;; v0.39: smart n / p — walk search hits when a search is active,
;;; otherwise fall back to next-page / prev-page.  This lets n/p serve
;;; double duty: normal page navigation most of the time, and forward/
;;; backward result navigation immediately after a / or ? search.
;;; pdf-isearch-quit (C-g) clears *pdf-search-state*, restoring plain
;;; page-navigation semantics.

(limn/pdf-mode::%defcmd pdf-n nil
  (lambda ()
    (let ((s (limn/pdf-mode::%search-state)))
      (if (and s (consp (limn/pdf-mode:pdf-search-state-hits s)))
          ;; ── search active: advance to next hit ──────────────────────
          (let* ((hits    (limn/pdf-mode:pdf-search-state-hits s))
                 (old-idx (limn/pdf-mode:pdf-search-state-current-index s)))
            (limn/pdf-mode:pdf-search-advance s)
            (let ((new-idx (limn/pdf-mode:pdf-search-state-current-index s)))
              (when (and (= old-idx (1- (length hits)))
                         (= new-idx 0))
                (limn/pdf-mode::%limn-call
                 "message/echo" :|text| limn/pdf-mode:*pdf-wrapped-message*)))
            (let* ((hit (nth (limn/pdf-mode:pdf-search-state-current-index s) hits))
                   (p   (getf hit :|page|)))
              (when (integerp p) (limn/pdf-mode::%page-set p)))
            (limn/pdf-mode::%emit-search-overlays s)
            (limn/pdf-mode::%select-current-hit s)
            (limn/pdf-mode::%refresh-search-modeline))
          ;; ── no active search: next page ─────────────────────────────
          (let* ((v  (limn/pdf-mode::%focused-view))
                 (p  (or (getf v :|page|) 0))
                 (pc (or (getf v :|page-count|) 1)))
            (limn/pdf-mode::%page-set
             (limn/pdf-mode::%clamp-page (1+ p) pc)))))))

(limn/pdf-mode::%defcmd pdf-p nil
  (lambda ()
    (let ((s (limn/pdf-mode::%search-state)))
      (if (and s (consp (limn/pdf-mode:pdf-search-state-hits s)))
          ;; ── search active: retreat to previous hit ──────────────────
          (progn
            (limn/pdf-mode:pdf-search-retreat s)
            (let* ((hits (limn/pdf-mode:pdf-search-state-hits s))
                   (hit  (nth (limn/pdf-mode:pdf-search-state-current-index s)
                               hits))
                   (p    (getf hit :|page|)))
              (when (integerp p) (limn/pdf-mode::%page-set p)))
            (limn/pdf-mode::%emit-search-overlays s)
            (limn/pdf-mode::%select-current-hit s)
            (limn/pdf-mode::%refresh-search-modeline))
          ;; ── no active search: previous page ─────────────────────────
          (let* ((v  (limn/pdf-mode::%focused-view))
                 (p  (or (getf v :|page|) 0))
                 (pc (or (getf v :|page-count|) 1)))
            (limn/pdf-mode::%page-set
             (limn/pdf-mode::%clamp-page (1- p) pc)))))))

;;; --- v0.39.11 A4: pdf-isearch-narrow / pdf-isearch-fuzzy commands ---

(limn/pdf-mode::%defcmd pdf-isearch-narrow nil
  ;; v0.39.12 follow-up: re-SEARCH rather than filter.  Previous
  ;; behaviour kept the original rects (the "the" boxes) and just
  ;; v0.39.15 line-narrow:
  ;;   M-n issues a fresh buffer/search for the new query, then keeps
  ;;   only the new hits whose LINE was also a line of the prior
  ;;   search.  Recursively tightens — three M-n in a row leaves only
  ;;   the lines where all three queries appeared.
  ;;
  ;;   The prior search's overlay payload is pushed onto
  ;;   *pdf-search-overlay-history* so its color stays visible under
  ;;   the new color (cumulative rainbow per user spec).
  (lambda ()
    (let* ((s (limn/pdf-mode::%search-state))
           (reader (find-symbol "*MINIBUFFER-READ*" :limn/cmd))
           (read-fn (and reader (boundp reader) (symbol-value reader))))
      (cond
        ((not s)
         (handler-case
             (limn/pdf-mode::%limn-call "message/echo"
                                        :|text| "No active search to narrow")
           (error () nil)))
        ((not read-fn) nil)
        (t
         (let* ((needle (funcall read-fn "Narrow search for: "))
                (buf (limn/pdf-mode::%focused-buffer-id))
                (v   (limn/pdf-mode::%focused-view))
                (cur-page (or (getf v :|page|) 0))
                (prior-payload
                  (limn/pdf-mode:pdf-search-overlay-payload s))
                (prior-history (limn/pdf-mode::%overlay-history))
                (prior-narrow  (limn/pdf-mode::%narrow-lines))
                (next-depth (1+ limn/pdf-mode::*pdf-filter-depth*)))
           (cond
             ((or (not (stringp needle)) (zerop (length needle))) nil)
             (t
              (let* ((new-state
                       (limn/pdf-mode::%do-search-wire buf needle))
                     (raw-new-hits
                       (and new-state
                            (limn/pdf-mode:pdf-search-state-hits new-state)))
                     ;; Intersect by line.  When prior-narrow is empty
                     ;; (shouldn't happen if pdf-search-execute seeded
                     ;; it, but defensive), behave like the previous
                     ;; "fresh re-search" semantic.
                     (kept (if (consp prior-narrow)
                               (limn/pdf-mode::%hits-in-narrow-set
                                raw-new-hits prior-narrow)
                               raw-new-hits)))
                ;; History + depth bump happen regardless of result
                ;; count so prior colors stay visible even on no-match.
                (limn/pdf-mode::%set-overlay-history
                 (cons prior-payload prior-history))
                (setf limn/pdf-mode::*pdf-filter-depth* next-depth)
                (cond
                  ((null kept)
                   (limn/pdf-mode::%emit-search-overlays nil)
                   (handler-case
                       (limn/pdf-mode::%limn-call
                        "message/echo"
                        :|text| (format nil
                                        "No matches for ~s on the same lines"
                                        needle))
                     (error () nil)))
                  (t
                   ;; Tighten narrow context to the surviving hits'
                   ;; lines so the NEXT M-n narrows further.
                   (limn/pdf-mode::%set-narrow-lines
                    (limn/pdf-mode::%lines-from-hits kept))
                   ;; Replace state hits with the kept subset and pick
                   ;; the first hit at/after the current page.
                   (setf (limn/pdf-mode:pdf-search-state-hits new-state)
                         kept)
                   (let ((start
                           (or (loop for h in kept for i from 0
                                     when (let ((p (getf h :|page|)))
                                            (and (integerp p)
                                                 (>= p cur-page)))
                                       return i)
                               0)))
                     (setf (limn/pdf-mode:pdf-search-state-current-index
                            new-state)
                           start)
                     (let* ((hit (nth start kept))
                            (p   (getf hit :|page|)))
                       (when (integerp p)
                         (limn/pdf-mode::%page-set p))))
                   (limn/pdf-mode::%emit-search-overlays new-state)
                   (limn/pdf-mode::%select-current-hit new-state))))
              (limn/pdf-mode::%refresh-search-modeline)))))))))

;; v0.39.15: pdf-isearch-fuzzy removed per user feedback ("先移除掉.
;; 我覺得這個應該有更好的做法").  M-f keybinding also dropped from
;; the install block.

;;; v0.37 Phase D: half-page scroll (vim C-d / C-u).  Uses offset-y
;;; deltas the same way pdf-scroll-down does, but with a larger step.
;;; v0.39: now uses view/scroll :dy (screen fraction) like pdf-scroll-down.

(defvar limn/pdf-mode:*pdf-half-page-step* 0.5
  "Screen fraction to scroll for C-d / C-u (0.0–1.0).
   0.5 = half the visible screen, matching vim's default behaviour.
   v0.39: passed directly to view/scroll :dy (was broken view/set :offset-y).")

(limn/pdf-mode::%defcmd pdf-half-page-down nil
  (lambda ()
    (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1"
                                :|dy| limn/pdf-mode:*pdf-half-page-step*)))

(limn/pdf-mode::%defcmd pdf-half-page-up nil
  (lambda ()
    (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1"
                                :|dy| (- limn/pdf-mode:*pdf-half-page-step*))))

;;; v0.39: full-page scroll (vim C-f / C-b).  One whole visible screen.

(defvar limn/pdf-mode:*pdf-page-step* 1.0
  "Screen fraction to scroll for C-f / C-b (full page = 1.0).")

(limn/pdf-mode::%defcmd pdf-page-down nil
  (lambda ()
    (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1"
                                :|dy| limn/pdf-mode:*pdf-page-step*)))

(limn/pdf-mode::%defcmd pdf-page-up nil
  (lambda ()
    (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1"
                                :|dy| (- limn/pdf-mode:*pdf-page-step*))))

;;; v0.39: horizontal scroll (vim h / l).  Same step as j/k but on :dx.
;;; Honors numeric prefix-arg.

(limn/pdf-mode::%defcmd pdf-scroll-left "p"
  (lambda (&optional prefix)
    (let* ((n    (or prefix 1))
           (step (* n limn/pdf-mode:*pdf-scroll-step*)))
      (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1" :|dx| (- step)))))

(limn/pdf-mode::%defcmd pdf-scroll-right "p"
  (lambda (&optional prefix)
    (let* ((n    (or prefix 1))
           (step (* n limn/pdf-mode:*pdf-scroll-step*)))
      (limn/pdf-mode::%limn-call "view/scroll" :|win-id| "w1" :|dx| step))))

;;; v0.37 Phase D: close the focused PDF buffer (vim q).  Routes to
;;; buffer/close on the focused buffer-id.
(limn/pdf-mode::%defcmd pdf-close nil
  (lambda ()
    (let ((bid (limn/pdf-mode::%focused-buffer-id)))
      (when bid
        (limn/pdf-mode::%limn-call "buffer/close" :|buffer-id| bid)))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §C annotation commands
;;; ═════════════════════════════════════════════════════════════════════

(defun limn/pdf-mode::%current-pdf-path ()
  "Get :path of the focused PDF buffer (for sidecar key).
   v0.37 Phase F: the original implementation called the wire command
   buffer/state — which doesn't exist in the C++ bridge, so it always
   returned NIL.  %add-annotation fell back to \"/tmp/unknown.pdf\",
   so the sidecar got keyed on that fake path and never matched the
   real file's content-hash key on reload (v027-annotate Ω3 / v027-
   content-move / v027-workflow Ω10 all hit this).  Use the
   *buffer-id-to-path* cache populated by pdf-mode-on-buffer-opened
   (which now receives the real path from emit_buffer_opened)."
  (let ((bid (limn/pdf-mode::%focused-buffer-id)))
    (and bid (gethash bid limn/pdf-mode::*buffer-id-to-path*))))

(defun limn/pdf-mode::%selection ()
  "Get the current selection as a (:|page| P :|rects| ((x1 y1 x2 y2)))
   plist.  v0.37 Phase F: the bridge's view/selection-get returns the
   selection as :|active| / :|begin|{:|page|,:|x|,:|y|} / :|end|{...} /
   :|mode| / :|text| — there is no :|rects| field on the wire (and
   never has been since the wire schema settled in v0.15).  This
   helper synthesizes a single-rect bounding box from begin/end so
   downstream callers (%add-annotation) keep the old :|page|/:|rects|
   contract.  Returns NIL when no selection is active or coords are
   missing — %add-annotation treats that as a no-op."
  (let* ((r (limn/pdf-mode::%limn-call "view/selection-get" :|win-id| "w1"))
         (d (limn/pdf-mode::%response-data r)))
    (when (and d (getf d :|active|))
      (let* ((b (getf d :|begin|))
             (e (getf d :|end|))
             (page (or (and b (getf b :|page|))
                       (and e (getf e :|page|))
                       0))
             (bx (and b (getf b :|x|))) (by (and b (getf b :|y|)))
             (ex (and e (getf e :|x|))) (ey (and e (getf e :|y|))))
        (when (and (numberp bx) (numberp by) (numberp ex) (numberp ey))
          (list :|page| page
                :|rects| (list (list (min bx ex) (min by ey)
                                     (max bx ex) (max by ey)))))))))

(defun limn/pdf-mode::%add-annotation (note)
  "Build + persist + paint an annotation from the current selection."
  (let* ((sel (limn/pdf-mode::%selection))
         (rects (and sel (getf sel :|rects|)))
         (sel-page (and sel (getf sel :|page|)))
         (v (limn/pdf-mode::%focused-view))
         (page (or sel-page (getf v :|page|) 0))
         (path (or (limn/pdf-mode::%current-pdf-path) "/tmp/unknown.pdf")))
    (when (and rects (consp rects))
      (let* ((existing (limn/pdf-mode:pdf-annotations-load path))
             ;; replace if a different anno covers same first rect
             (filtered (remove-if
                         (lambda (a)
                           (and (= (limn/pdf-mode:pdf-annotation-page a)
                                    page)
                                (equal (first
                                         (limn/pdf-mode:pdf-annotation-rects a))
                                        (first rects))))
                         existing))
             (new (limn/pdf-mode:make-pdf-annotation
                   :page page :rects rects :note note)))
        (let ((all (append filtered (list new))))
          (limn/pdf-mode:pdf-annotations-save path all)
          ;; v0.37 Phase F: the wire schema for view/overlays takes
          ;; :|layers| (an array of overlay objects), NOT :|overlays|.
          ;; Sending the latter silently sets layers to NULL — the C++
          ;; side treats that as "clear all overlays".  Result: sidecar
          ;; saved fine, but no rect appeared on screen and view/get
          ;; returned overlays=[].  Fixed schema name.
          (limn/pdf-mode::%limn-call
           "view/overlays" :|win-id| "w1"
           :|layers| (limn/pdf-mode:pdf-annotations-overlay-payload all)))))))

(limn/pdf-mode::%defcmd pdf-highlight-selection nil
  (lambda ()
    (limn/pdf-mode::%add-annotation nil)))

(limn/pdf-mode::%defcmd pdf-annotate-selection nil
  (lambda ()
    (let* ((reader (find-symbol "*MINIBUFFER-READ*" :limn/cmd))
           (read-fn (and reader (boundp reader) (symbol-value reader)))
           (note (and read-fn (funcall read-fn "Note: "))))
      (limn/pdf-mode::%add-annotation note))))

(limn/pdf-mode::%defcmd pdf-delete-annotation nil
  (lambda ()
    (let* ((path (limn/pdf-mode::%current-pdf-path))
           (v (limn/pdf-mode::%focused-view))
           (page (or (getf v :|page|) 0))
           (off-x (or (getf v :|offset-x|) 0.5))
           (off-y (or (getf v :|offset-y|) 0.5)))
      (when path
        (limn/pdf-mode:pdf-annotations-delete-at-point
         path page off-x off-y)))))

;;; v0.39 W13 — copy current PDF selection text onto the kill-ring.
;;; Emacs convention: M-w `copy-region-as-kill`.  PDF read-only buffers
;;; can't `kill`, only copy, so this is the only kill-family command
;;; in pdf-mode.  Subsequent C-y / `yank` in any text-mode buffer pulls
;;; the head of *kill-ring* and inserts at point — cross-engine paste.
(limn/pdf-mode::%defcmd pdf-copy-region-as-kill nil
  (lambda ()
    (let* ((r (limn/pdf-mode::%limn-call "view/selection-get"
                                          :|win-id| "w1"))
           (d (limn/pdf-mode::%response-data r))
           (txt (and d (getf d :|text|))))
      (when (and txt (stringp txt) (plusp (length txt)))
        ;; 1. Push onto the Lisp-internal kill ring (for C-y within limn).
        (let ((kpkg (find-package '#:limn/kill)))
          (when kpkg
            (let ((kn (find-symbol "KILL-NEW" kpkg)))
              (when (and kn (fboundp kn))
                (funcall (symbol-function kn) txt)))))
        ;; 2. Write to the OS system clipboard via pbcopy (macOS).
        ;;    Pure Lisp — no C++ wire needed.
        (handler-case
            (uiop:run-program '("pbcopy")
                              :input (make-string-input-stream txt)
                              :ignore-error-status t)
          (error () nil))
        ;; 3. Echo confirmation.
        (handler-case
            (limn/pdf-mode::%limn-call "message/echo"
                                        :|text| "Copied selection")
          (error () nil))))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §D TOC
;;; ═════════════════════════════════════════════════════════════════════

(defvar limn/pdf-mode:*pdf-toc-buffer-name* "*PDF-TOC*"
  "Buffer name for the TOC display.")

(defun limn/pdf-mode:format-toc-tree (toc &optional (depth 0))
  "Render a TOC (list of :title :page :children plists) as indented
   text. Empty TOC → empty string."
  (if (null toc)
      ""
      (with-output-to-string (out)
        (dolist (item toc)
          (let ((title (getf item :|title|))
                (page (getf item :|page| 0))
                (children (getf item :|children|)))
            (loop repeat (* depth 2) do (write-char #\Space out))
            (format out "~a  ~a~%" title (1+ (or page 0)))
            (when children
              (write-string
               (limn/pdf-mode:format-toc-tree children (1+ depth))
               out)))))))

(defun limn/pdf-mode:parse-toc-line-page (line-or-buf)
  "Extract integer page from a TOC line (or first line of buffer)."
  (let* ((line (if (find #\Newline line-or-buf)
                   (subseq line-or-buf 0 (position #\Newline line-or-buf))
                   line-or-buf))
         (n (position-if-not (lambda (c)
                                (or (digit-char-p c) (char= c #\Space)))
                              (reverse line)))
         (suffix (if n
                     (subseq line (- (length line) n))
                     line))
         (digits (string-trim '(#\Space) suffix)))
    (when (and digits (every #'digit-char-p digits))
      ;; 1-indexed in display → 0-indexed internally
      (1- (parse-integer digits)))))

;; v0.38 B14: helpers to flatten the nested TOC tree into a single list
;; of (title page depth) tuples for completing-read.
(defun limn/pdf-mode::%toc-flatten (items depth)
  "Walk the TOC tree producing a flat list of (:title T :page P :depth D)
   plists in display order (parent before its children)."
  (let ((acc nil))
    (dolist (it items)
      (let ((title (getf it :|title|))
            (page  (or (getf it :|page|) 0))
            (kids  (getf it :|children|)))
        (push (list :title title :page page :depth depth) acc)
        (when (listp kids)
          (dolist (sub (limn/pdf-mode::%toc-flatten kids (1+ depth)))
            (push sub acc)))))
    (nreverse acc)))

(defun limn/pdf-mode::%toc-line (entry)
  "Render one flat TOC entry as 'PAGE  INDENT TITLE  PAGE' for
   completing-read display.  The trailing PAGE is what
   parse-toc-line-page picks up (TITLE may itself end in digits
   like 'Chapter 1', so we cannot rely on title-then-page parsing
   alone — but the parse looks at the LAST run of digits, so any
   title-internal digits are fine as long as the page comes after.
   Leading PAGE is also displayed for quick visual scan."
  (let* ((title (or (getf entry :title) ""))
         (page  (or (getf entry :page) 0))
         (depth (or (getf entry :depth) 0))
         (display-page (1+ page))
         (indent (with-output-to-string (s)
                   (loop repeat (* depth 2) do (write-char #\Space s))))
         ;; sentinel "  " separator + trailing page — parse-toc-line-page
         ;; grabs trailing digits past any non-digit, so the title's own
         ;; trailing digits get the prefix re-read as one number.  To
         ;; ensure correctness we append an em-dash plus the page:
         (suffix (format nil " — p.~a" display-page)))
    (format nil "~a~a~a" indent title suffix)))

(limn/pdf-mode::%defcmd pdf-toc nil
  (lambda ()
    ;; v0.38 B14: open completing-read with TOC entries.  Pre-v0.38
    ;; sent the formatted tree to a `bridge/win-float-create :|text|`
    ;; call but that wire command ignores :|text| so the user saw
    ;; nothing interactive.  This new impl flattens the tree, shows
    ;; each entry "  P | Title" via completing-read, then parses out
    ;; the page and jumps.
    ;;
    ;; v0.39 W04 fix: `buffer/toc` returns the items array directly
    ;; as `data` (see cmd_buffer_toc / send_ok_array), not wrapped
    ;; as `{items: [...]}`.  Pre-fix used `(getf d :|items|)` which
    ;; on the actual response (a list of TOC plists) either errored
    ;; with malformed-property-list or silently returned NIL — either
    ;; way `items` was nil, `(when (listp items) ...)` skipped, and
    ;; the user pressing `t` saw nothing happen because completing-
    ;; read never opened.  Was the entire reason W04 A.1 failed.
    (let* ((bid (limn/pdf-mode::%focused-buffer-id))
           (r (and bid (limn/pdf-mode::%limn-call "buffer/toc"
                                                    :|buffer-id| bid)))
           (items (limn/pdf-mode::%response-data r)))
      (when (listp items)
        (let* ((flat (limn/pdf-mode::%toc-flatten items 0))
               (lines (mapcar #'limn/pdf-mode::%toc-line flat))
               (completing (find-symbol "COMPLETING-READ" '#:limn/completion))
               (pick (and completing (fboundp completing)
                          (funcall (symbol-function completing)
                                   "TOC: " lines :require-match t))))
          (when (and pick (stringp pick) (plusp (length pick)))
            (let ((p (limn/pdf-mode:parse-toc-line-page pick)))
              (when (integerp p)
                (limn/pdf-mode::%page-set p)))))))))

(limn/pdf-mode::%defcmd pdf-toc-jump-at-point nil
  (lambda (&optional line)
    (let* ((line-text (or line ""))
           (p (and line-text
                   (handler-case
                       (limn/pdf-mode:parse-toc-line-page line-text)
                     (error () nil)))))
      (when (integerp p)
        (limn/pdf-mode::%page-set p)))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §E bookmarks
;;; ═════════════════════════════════════════════════════════════════════
;;;
;;; The C++ wire (bookmark/set, /get, /list, /delete) is in-memory only,
;;; scoped to one buffer-id's lifetime.  Cross-open persistence
;;; ("close + reopen restores my marks") lives here in user-Lisp via
;;; sidecar files at ~/.limn/bookmarks/{path-hash}.lisp — same pattern
;;; as annotations.  See v027-workflow Ω6/Ω9 and macOS
;;; test-bookmark-cleared-on-buffer-close (asserts the C++ side is
;;; in-memory only).

(defun limn/pdf-mode:pdf-bookmarks-sidecar-path (path)
  "Path-keyed sidecar.  We use the path hash (not content) for
   bookmarks because page numbers are stable across file edits in
   ways that pixel-level annotations aren't."
  (let ((slug (limn/pdf-mode::%sha256-of-string (namestring path))))
    (pathname (format nil "~a/.limn/bookmarks/~a.lisp"
                       (limn/pdf-mode::%home) slug))))

(defun limn/pdf-mode:pdf-bookmarks-save (path bookmarks)
  "Write BOOKMARKS (list of plists with :name :page :x :y :note) to
   the sidecar for PATH.  Atomic write.  Returns T on success."
  (let ((spath (limn/pdf-mode:pdf-bookmarks-sidecar-path path)))
    (handler-case
        (progn
          (ensure-directories-exist spath)
          (let ((tmp (concatenate 'string (namestring spath) ".tmp")))
            (with-open-file (out tmp :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create)
              (write (list :version 1 :bookmarks bookmarks)
                     :stream out :readably t))
            (rename-file tmp spath))
          t)
      (error () nil))))

(defun limn/pdf-mode:pdf-bookmarks-load (path)
  "Read bookmark list from sidecar for PATH.  Returns NIL when no
   sidecar exists or it can't be parsed."
  (let ((spath (limn/pdf-mode:pdf-bookmarks-sidecar-path path)))
    (handler-case
        (when (probe-file spath)
          (with-open-file (in spath :direction :input)
            (let ((data (read in nil nil)))
              (and (listp data) (getf data :bookmarks)))))
      (error () nil))))

(defun limn/pdf-mode::%bookmark-upsert (list rec)
  "Replace bookmark by name in LIST or append; return new list."
  (let ((name (getf rec :name))
        (updated nil))
    (let ((new (mapcar (lambda (b)
                         (if (and (not updated) (equal (getf b :name) name))
                             (progn (setf updated t) rec)
                             b))
                       list)))
      (if updated new (append new (list rec))))))

(defun limn/pdf-mode::%bookmark-path-for-buffer (buffer-id)
  "Look up cached path for BUFFER-ID (populated by
   pdf-mode-on-buffer-opened).  Returns string or NIL."
  (and buffer-id
       (gethash buffer-id limn/pdf-mode::*buffer-id-to-path*)))

(defun limn/pdf-mode:pdf-set-bookmark-name (buffer-id char-name page)
  "Set bookmark CHAR-NAME on BUFFER-ID at PAGE.  Calls wire +
   mirrors to the path-keyed sidecar so close+reopen restores it."
  (let ((r (limn/pdf-mode::%limn-call "bookmark/set"
                                       :|buffer-id| buffer-id
                                       :|name| char-name
                                       :|page| page
                                       :|x| 0.0 :|y| 0.0
                                       :|note| "")))
    (when (limn/pdf-mode::%ok? r)
      (let ((path (limn/pdf-mode::%bookmark-path-for-buffer buffer-id)))
        (when path
          (let ((existing (limn/pdf-mode:pdf-bookmarks-load path))
                (rec (list :name char-name :page page
                           :x 0.0 :y 0.0 :note "")))
            (limn/pdf-mode:pdf-bookmarks-save
             path (limn/pdf-mode::%bookmark-upsert existing rec))))))
    r))

(defun limn/pdf-mode:pdf-delete-bookmark-name (buffer-id char-name)
  "Delete bookmark CHAR-NAME from BUFFER-ID + the path-keyed sidecar."
  (let ((r (limn/pdf-mode::%limn-call "bookmark/delete"
                                       :|buffer-id| buffer-id
                                       :|name| char-name)))
    (let ((path (limn/pdf-mode::%bookmark-path-for-buffer buffer-id)))
      (when path
        (let ((existing (limn/pdf-mode:pdf-bookmarks-load path)))
          (when existing
            (limn/pdf-mode:pdf-bookmarks-save
             path (remove-if (lambda (b) (equal (getf b :name) char-name))
                              existing))))))
    r))

(defun limn/pdf-mode:pdf-jump-bookmark-name (buffer-id char-name)
  (let* ((r (limn/pdf-mode::%limn-call "bookmark/get"
                                         :|buffer-id| buffer-id
                                         :|name| char-name))
         (d (and (limn/pdf-mode::%ok? r) (limn/pdf-mode::%response-data r)))
         (page (and d (getf d :|page|))))
    (when (integerp page)
      (limn/pdf-mode::%page-set page))))

(defun limn/pdf-mode::%restore-bookmarks-for-buffer (buffer-id path)
  "Called from pdf-mode-on-buffer-opened: re-install path-keyed
   sidecar bookmarks onto the new buffer-id via the C++ wire.  This
   is what makes close+reopen restore them — the C++ side is by
   design in-memory only (macOS test-bookmark-cleared-on-buffer-close)."
  (when (and buffer-id path)
    (dolist (b (limn/pdf-mode:pdf-bookmarks-load path))
      (handler-case
          (limn/pdf-mode::%limn-call
           "bookmark/set"
           :|buffer-id| buffer-id
           :|name| (or (getf b :name) "")
           :|page| (or (getf b :page) 0)
           :|x| (or (getf b :x) 0.0)
           :|y| (or (getf b :y) 0.0)
           :|note| (or (getf b :note) ""))
        (error () nil)))))

(limn/pdf-mode::%defcmd pdf-set-bookmark nil
  (lambda (&optional name)
    (let* ((rt (find-package :limn/runtime))
           (key-read (and rt (find-symbol "*KEY-READ-FN*" rt)))
           (c (or name
                  (and key-read (boundp key-read)
                       (funcall (symbol-value key-read)))
                  "a"))
           (bid (limn/pdf-mode::%focused-buffer-id))
           (v (limn/pdf-mode::%focused-view))
           (page (or (getf v :|page|) 0)))
      (when bid
        (limn/pdf-mode:pdf-set-bookmark-name bid c page)))))

(limn/pdf-mode::%defcmd pdf-jump-bookmark nil
  (lambda (&optional name)
    (let* ((rt (find-package :limn/runtime))
           (key-read (and rt (find-symbol "*KEY-READ-FN*" rt)))
           (c (or name
                  (and key-read (boundp key-read)
                       (funcall (symbol-value key-read)))
                  "a"))
           (bid (limn/pdf-mode::%focused-buffer-id)))
      (when bid
        (limn/pdf-mode:pdf-jump-bookmark-name bid c)))))

(limn/pdf-mode::%defcmd pdf-list-bookmarks nil
  (lambda ()
    (let* ((bid (limn/pdf-mode::%focused-buffer-id))
           (r (and bid (limn/pdf-mode::%limn-call "bookmark/list"
                                                    :|buffer-id| bid)))
           (d (limn/pdf-mode::%response-data r))
           (items (and d (getf d :|items|)))
           (names (and items (mapcar (lambda (e) (getf e :|name|)) items)))
           (reader (find-symbol "*MINIBUFFER-READ*" :limn/cmd))
           (read-fn (and reader (boundp reader) (symbol-value reader))))
      (when (and bid names read-fn)
        (let ((pick (funcall read-fn
                              (format nil "Jump to bookmark (~{~a~^, ~}): "
                                       names))))
          (when (and pick (stringp pick) (find pick names :test #'string=))
            (limn/pdf-mode:pdf-jump-bookmark-name bid pick)))))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §F modeline
;;; ═════════════════════════════════════════════════════════════════════

(defun limn/pdf-mode:pdf-format-modeline (path page page-count zoom
                                          &optional counter)
  "Format \"PDF: name [P/T] Z%  [N / T-matches]\". Page is 1-indexed.
   COUNTER is the optional search-match string (\"3 / 17\") shown only
   when a search is active.  Embedded in the left slot so it always
   renders, regardless of whether Qt's modeline layout shows :right."
  (let ((basename (file-namestring (pathname path)))
        (zoom-pct (round (* 100 zoom))))
    (if (and counter (stringp counter) (plusp (length counter)))
        (format nil "PDF: ~a   [~a / ~a]   ~a%   match ~a"
                basename (1+ page) page-count zoom-pct counter)
        (format nil "PDF: ~a   [~a / ~a]   ~a%"
                basename (1+ page) page-count zoom-pct))))

(defun limn/pdf-mode:pdf-mode-update-modeline (&key buffer-id path)
  (declare (ignore buffer-id))
  (let* ((v (limn/pdf-mode::%focused-view))
         (page (or (getf v :|page|) 0))
         (pc (or (getf v :|page-count|) 1))
         (zoom (or (getf v :|zoom|) 1.0))
         (counter (limn/pdf-mode:pdf-format-search-counter))
         (label (limn/pdf-mode:pdf-format-modeline
                  (or path "/tmp/unknown.pdf")
                  page pc zoom counter)))
    (limn/pdf-mode::%limn-call "modeline/set"
                                :|left|  label
                                :|right| (or counter ""))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §M mouse-driven text selection
;;;
;;; Left-button press  → remember anchor (handled via mouse-click hook).
;;; Left-button move   → update selection via view/selection-set
;;;                      (mouse-drag carries anchor + delta in page-norm).
;;; M-w                → copy selected text to kill ring (existing binding).
;;; C-g / next click   → clear selection (view/selection-clear).
;;;
;;; Coordinate convention: mouse-click / mouse-drag events from C++ carry
;;; page-normalized x/y (0.0–1.0) — the same space view/selection-set
;;; expects, so no coordinate conversion is needed here.
;;; ═════════════════════════════════════════════════════════════════════

(defun limn/pdf-mode::%on-mouse-click (ev)
  "Hook handler for 'mouse-click' events.
   Left click: clear any previous selection, store anchor for potential drag."
  (let ((button (getf ev :|button|))
        (page   (getf ev :|page|)))
    (when (and (eql button 1) (integerp page) (>= page 0))
      ;; Clear previous selection so a plain click always resets it.
      (handler-case
          (limn/pdf-mode::%limn-call
           "view/selection-clear" :|win-id| "w1")
        (error () nil)))))

(defun limn/pdf-mode::%on-mouse-drag (ev)
  "Hook handler for 'mouse-drag' events.
   Left-button drag: extend the text selection from anchor to current pos."
  (let ((button (getf ev :|button|))
        (page   (getf ev :|page|))
        (ax     (getf ev :|x|))
        (ay     (getf ev :|y|))
        (dx     (getf ev :|dx|))
        (dy     (getf ev :|dy|)))
    (when (and (eql button 1)
               (integerp page) (>= page 0)
               (numberp ax) (numberp ay)
               (numberp dx) (numberp dy))
      ;; Anchor (begin) is where drag started; current pos is anchor+delta.
      (let ((end-x (+ ax dx))
            (end-y (+ ay dy)))
        ;; Ensure begin is always top-left in reading order.
        (let* ((swap-p (or (> ay end-y)
                           (and (= ay end-y) (> ax end-x))))
               (bx (if swap-p end-x ax))
               (by (if swap-p end-y ay))
               (ex (if swap-p ax end-x))
               (ey (if swap-p ay end-y)))
          (handler-case
              (limn/pdf-mode::%limn-call
               "view/selection-set"
               :|win-id| "w1"
               :|begin| (list :|page| page :|x| bx :|y| by)
               :|end|   (list :|page| page :|x| ex :|y| ey)
               :|mode|  "char")
            (error () nil)))))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §I lifecycle hooks
;;; ═════════════════════════════════════════════════════════════════════

(defvar limn/pdf-mode::*buffer-id-to-path* (make-hash-table :test #'equal)
  "Map buffer-id → PDF path. Populated on buffer-opened so we can save
   last-position on buffer-closed (when the wire event no longer has
   :|path|).")

(defun limn/pdf-mode:pdf-mode-on-buffer-opened (&key buffer-id path engine)
  "Called when a buffer is opened. For mupdf buffers: load sidecar
   annotations, restore last-position, update modeline."
  (when (and (stringp engine) (string= engine "mupdf") path
             (plusp (length path)))
    ;; Track buffer-id → path so buffer-closed can save last-position
    (when buffer-id
      (setf (gethash buffer-id limn/pdf-mode::*buffer-id-to-path*) path))
    ;; Load + paint annotations.  v0.39.11 D2: populate cache eagerly so
    ;; the first mouse-click hot path is a hash lookup, not a re-read.
    (let* ((entry (limn/pdf-mode::%annotations-cache-build path))
           (anns  (getf entry :|all|)))
      (when anns
        (limn/pdf-mode::%limn-call
         "view/overlays" :|win-id| "w1"
         :|layers| (limn/pdf-mode:pdf-annotations-overlay-payload anns))))
    ;; Restore bookmarks from path-keyed sidecar (v0.37 Phase F batch 18).
    ;; C++ wire is in-memory only by design; this is where the close+
    ;; reopen "my marks survive" guarantee actually lives.
    (handler-case
        (limn/pdf-mode::%restore-bookmarks-for-buffer buffer-id path)
      (error () nil))
    ;; Restore last-position
    (handler-case
        (limn/pdf-mode:pdf-mode-restore-last-position
         :buffer-id buffer-id :path path)
      (error () nil))
    ;; Update modeline
    (handler-case
        (limn/pdf-mode:pdf-mode-update-modeline
         :buffer-id buffer-id :path path)
      (error () nil))
    ;; v0.38 B18: apply *pdf-default-zoom* if set in user init.lisp.
    ;; NOTE: this defun is in cl-user package (see in-package at top of
    ;; file), so bare *pdf-default-zoom* would resolve to cl-user's
    ;; symbol — must qualify with limn/pdf-mode: prefix.
    (let ((z limn/pdf-mode:*pdf-default-zoom*))
      (when (and z (numberp z))
        (handler-case
            (limn/pdf-mode::%limn-call "view/set"
                                        :|win-id| "w1"
                                        :|zoom| z)
          (error () nil))))))

(defun limn/pdf-mode:pdf-mode-on-buffer-closed (&key buffer-id)
  "Called before a PDF buffer closes: save last-position, clear search state."
  ;; Save last-position if we know the path
  (let ((path (and buffer-id
                    (gethash buffer-id limn/pdf-mode::*buffer-id-to-path*))))
    (when path
      (handler-case
          (limn/pdf-mode:pdf-mode-save-last-position
           :buffer-id buffer-id :path path)
        (error () nil))
      (remhash buffer-id limn/pdf-mode::*buffer-id-to-path*)))
  ;; Clear search state for any window that was searching this buffer.
  (maphash (lambda (win-id s)
              (when (and s (or (null buffer-id)
                               (equal buffer-id
                                      (limn/pdf-mode:pdf-search-state-buffer-id s))))
                (remhash win-id limn/pdf-mode::*pdf-search-states*)))
            limn/pdf-mode::*pdf-search-states*))

(defun limn/pdf-mode:pdf-mode-on-buffer-focused (&key buffer-id)
  "Called when focus switches to BUFFER-ID. Reset stale per-buffer search."
  (maphash (lambda (win-id s)
              (when (and s
                         (not (equal buffer-id
                                     (limn/pdf-mode:pdf-search-state-buffer-id s))))
                (remhash win-id limn/pdf-mode::*pdf-search-states*)))
            limn/pdf-mode::*pdf-search-states*))

;;; ═════════════════════════════════════════════════════════════════════
;;; §T last-position
;;; ═════════════════════════════════════════════════════════════════════

(defun limn/pdf-mode::%last-position-path (path)
  (let ((hash (or (funcall limn/pdf-mode:*file-content-hash-fn* path)
                  "unknown")))
    (pathname (format nil "~a/.limn/positions/~a.lisp"
                       (limn/pdf-mode::%home) hash))))

(defun limn/pdf-mode::%last-position-write (key data)
  (ensure-directories-exist key)
  (with-open-file (out key :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write data :stream out :readably t)))

(defun limn/pdf-mode::%last-position-read (key)
  (when (probe-file key)
    (with-open-file (in key :direction :input)
      (read in nil nil))))

(defun limn/pdf-mode:pdf-mode-save-last-position (&key buffer-id path)
  (declare (ignore buffer-id))
  (let* ((v (limn/pdf-mode::%focused-view))
         (data (list :page (or (getf v :|page|) 0)
                     :offset-y (or (getf v :|offset-y|) 0.0)
                     :zoom (or (getf v :|zoom|) 1.0)))
         (key (limn/pdf-mode::%last-position-path path))
         (writer (or limn/pdf-mode:*last-position-write-fn*
                     #'limn/pdf-mode::%last-position-write)))
    (handler-case (funcall writer key data)
      (error () nil))))

(defun limn/pdf-mode:pdf-mode-restore-last-position (&key buffer-id path)
  (declare (ignore buffer-id))
  (let* ((key (limn/pdf-mode::%last-position-path path))
         (reader (or limn/pdf-mode:*last-position-read-fn*
                     #'limn/pdf-mode::%last-position-read))
         (data (handler-case (funcall reader key) (error () nil))))
    (when (and data (listp data))
      (let ((p (getf data :page)))
        (when (integerp p)
          (limn/pdf-mode::%page-set p))))))

;;; ═════════════════════════════════════════════════════════════════════
;;; §V workflow features
;;; ═════════════════════════════════════════════════════════════════════

(defun limn/pdf-mode:pdf-recent-list ()
  "Filter v0.24 recentf list for .pdf entries."
  (let ((sym (find-symbol "*RECENTF-LIST*" :limn/recentf)))
    (when (and sym (boundp sym))
      (remove-if-not
       (lambda (p) (and (stringp p)
                        (search ".pdf" (string-downcase p))))
       (symbol-value sym)))))

;;; ═════════════════════════════════════════════════════════════════════
;;; Install — keymap + mode registration + hook subscriptions
;;; ═════════════════════════════════════════════════════════════════════

(in-package #:limn/pdf-mode)

(defun %wrap-cmd (sym)
  "Wrap a defcommand symbol as keymap binding lambda (mirrors text-mode).
   v0.39: also binds *current-win-id* from the event so all commands
   that call %search-state / %set-search-state operate on the correct
   per-window slot (multi-frame support)."
  (lambda (ev)
    (let ((*last-key*       (getf ev :|key|))
          (*current-win-id* (or (getf ev :|win-id|) *current-win-id*)))
      (limn/cmd:call-interactively sym))))

(defun %def (km spec sym)
  (limn/keys:define-key km spec (%wrap-cmd sym)))

(defvar *installed-p* nil)

(defun install ()
  "Idempotent setup: define pdf-mode, build keymap, register as default
   mode for engine=mupdf, subscribe to buffer-opened/closed hooks."
  (let* ((sym-pm (intern "PDF-MODE" :cl-user))
         (mode-pkg (find-package '#:limn/mode))
         (find-mode (find-symbol "FIND-MODE" mode-pkg))
         (existing (and find-mode (funcall find-mode sym-pm))))

    ;; Build keymap fresh.
    (let ((km (limn/keys:make-keymap)))
      ;; ── navigation: vim hjkl + arrow keys ─────────────────────────
      ;; v0.39: hjkl are pure scroll (screen-fraction via view/scroll).
      ;; The old "h = highlight, l = next-page" sioyek defaults were
      ;; dropped — they shadowed vim conventions and surprised dogfooders.
      (%def km "h"        (intern "PDF-SCROLL-LEFT"  :cl-user))
      (%def km "j"        (intern "PDF-SCROLL-DOWN"  :cl-user))
      (%def km "k"        (intern "PDF-SCROLL-UP"    :cl-user))
      (%def km "l"        (intern "PDF-SCROLL-RIGHT" :cl-user))
      (%def km "<left>"   (intern "PDF-SCROLL-LEFT"  :cl-user))
      (%def km "<down>"   (intern "PDF-SCROLL-DOWN"  :cl-user))
      (%def km "<up>"     (intern "PDF-SCROLL-UP"    :cl-user))
      (%def km "<right>"  (intern "PDF-SCROLL-RIGHT" :cl-user))
      ;; page-level navigation.
      ;; v0.39: n/p are smart — they walk search hits when a search is
      ;; active (*pdf-search-state* non-nil) and fall back to page
      ;; navigation otherwise.  J/K are always page-level.
      (%def km "n"        (intern "PDF-N"           :cl-user))
      (%def km "p"        (intern "PDF-P"           :cl-user))
      (%def km "J"        (intern "PDF-NEXT-PAGE"   :cl-user))
      (%def km "K"        (intern "PDF-PREV-PAGE"   :cl-user))
      ;; v0.38: b = prev-page (less convention).  NB: do NOT bind SPC —
      ;; SPC is the Doom-style leader key (limn/keys:*leader-key*).
      ;; Pre-fix W22/W23/W25 broke when pdf-mode-map's SPC binding shadowed
      ;; *leader-keymap* dispatch.
      (%def km "b"        (intern "PDF-PREV-PAGE"   :cl-user))
      ;; v0.38 B11: vim convention — G alone → last page; NG → page N.
      ;; pdf-goto-page now defaults to last page when prefix is nil, so
      ;; binding it on G gives both behaviors via one command.
      (%def km "G"        (intern "PDF-GOTO-PAGE"   :cl-user))
      (%def km "g g"      (intern "PDF-FIRST-PAGE"  :cl-user))
      ;; zoom
      (%def km "+"        (intern "PDF-ZOOM-IN"     :cl-user))
      (%def km "="        (intern "PDF-ZOOM-IN"     :cl-user))
      (%def km "-"        (intern "PDF-ZOOM-OUT"    :cl-user))
      (%def km "0"        (intern "PDF-ZOOM-RESET"  :cl-user))
      (%def km "W"        (intern "PDF-FIT-WIDTH"   :cl-user))
      (%def km "d"        (intern "PDF-TOGGLE-DARK" :cl-user))
      (%def km "r"        (intern "PDF-ROTATE-CW"   :cl-user))
      ;; v0.37 Phase D: half-page (vim C-d / C-u)
      (%def km "C-d"      (intern "PDF-HALF-PAGE-DOWN" :cl-user))
      (%def km "C-u"      (intern "PDF-HALF-PAGE-UP"   :cl-user))
      ;; v0.39: full-page (vim C-f / C-b)
      (%def km "C-f"      (intern "PDF-PAGE-DOWN"   :cl-user))
      (%def km "C-b"      (intern "PDF-PAGE-UP"     :cl-user))
      ;; search
      (%def km "/"        (intern "PDF-ISEARCH-FORWARD"  :cl-user))
      (%def km "?"        (intern "PDF-ISEARCH-BACKWARD" :cl-user)) ; v0.37 Phase D
      ;; v0.37 Phase F: C-g during/after a search clears search-state +
      ;; overlays.  Without this binding, C-g hits the global keyboard-
      ;; quit which only closes the minibuffer — leaving stale search
      ;; highlights painted on the page (v027-search Ω4 saw 122 overlays
      ;; remaining after C-g).  pdf-isearch-quit is idempotent so binding
      ;; it here is safe even when no search is active.
      (%def km "C-g"      (intern "PDF-ISEARCH-QUIT" :cl-user))
      ;; v0.39.15 A: line-narrow only (M-f / fuzzy was removed).
      (%def km "M-n"      (intern "PDF-ISEARCH-NARROW" :cl-user))
      ;; annotation — H stays as annotate (M-h is left free for users
      ;; who want to bind highlight-selection somewhere out of hjkl's way).
      (%def km "H"        (intern "PDF-ANNOTATE-SELECTION"  :cl-user))
      ;; v0.39 W13 — M-w copies the current PDF selection text onto
      ;; the kill-ring so a follow-up C-y in any text buffer pastes it.
      (%def km "M-w"      (intern "PDF-COPY-REGION-AS-KILL" :cl-user))
      ;; TOC
      (%def km "t"        (intern "PDF-TOC" :cl-user))
      ;; v0.37 Phase D: file + session ops
      (%def km "o"        (intern "FIND-FILE"       :cl-user)) ; vim :e analog
      (%def km "q"        (intern "PDF-CLOSE"       :cl-user)) ; vim q
      ;; Note: ":" is intentionally NOT bound in pdf-mode — it should
      ;; pass through as a literal character.  M-x (global keymap) is
      ;; the command-palette; M-: (global keymap) evaluates a lisp form.

      ;; Register the mode (or update its keymap if already registered,
      ;; but respect user-overridden bindings).
      (if existing
          ;; Preserve user-modified bindings: don't clobber km wholesale.
          ;; Only set our default keys if they don't already have a
          ;; binding pointing somewhere else.
          (let ((existing-km (limn/mode:mode-keymap existing)))
            (when existing-km
              ;; First install: existing-km is empty → copy our km in.
              ;; Reinstall: existing-km has user overrides → merge defaults
              ;; only for keys without a binding.
              (dolist (entry '(;; v0.39: vim-style hjkl scroll
                                ("h" pdf-scroll-left)  ("j" pdf-scroll-down)
                                ("k" pdf-scroll-up)    ("l" pdf-scroll-right)
                                ("<left>"  pdf-scroll-left)
                                ("<down>"  pdf-scroll-down)
                                ("<up>"    pdf-scroll-up)
                                ("<right>" pdf-scroll-right)
                                ("n" pdf-n) ("p" pdf-p)   ; v0.39 smart dispatch
                                ("b" pdf-prev-page)
                                ("J" pdf-next-page) ("K" pdf-prev-page)
                                ("G" pdf-goto-page) ("g g" pdf-first-page)
                                ("+" pdf-zoom-in)   ("=" pdf-zoom-in)
                                ("-" pdf-zoom-out)  ("0" pdf-zoom-reset)
                                ("W" pdf-fit-width)
                                ("d" pdf-toggle-dark)
                                ("r" pdf-rotate-cw)
                                ("/" pdf-isearch-forward)
                                ("?" pdf-isearch-backward)
                                ("C-g" pdf-isearch-quit)
                                ("M-n" pdf-isearch-narrow)
                                ("H" pdf-annotate-selection)
                                ("t" pdf-toc)
                                ;; v0.37 Phase D additions
                                ("C-d" pdf-half-page-down)
                                ("C-u" pdf-half-page-up)
                                ;; v0.39: full-page (vim C-f / C-b)
                                ("C-f" pdf-page-down)
                                ("C-b" pdf-page-up)
                                ("o"   find-file)
                                ("q"   pdf-close)
                                ;; v0.39 W13
                                ("M-w" pdf-copy-region-as-kill)))
                (let* ((spec (first entry))
                       (cmd (second entry))
                       (parts
                         (loop for i = 0 then (1+ j)
                                for j = (position #\Space spec :start i)
                                collect (subseq spec i j)
                                while j))
                       (existing-binding
                         (limn/keys:lookup-sequence existing-km parts)))
                  (unless existing-binding
                    (%def existing-km spec (intern (symbol-name cmd) :cl-user)))))))
          ;; Fresh install.
          (let ((m (limn/mode:define-mode sym-pm
                                           :type :major
                                           :modeline "PDF")))
            (declare (ignore m))
            (setf (limn/mode:mode-keymap (limn/mode:find-mode sym-pm)) km))))

    ;; Register engine-default-mode "mupdf" → pdf-mode.
    (let ((reg (find-symbol "REGISTER-ENGINE-DEFAULT-MODE" :limn/runtime)))
      (when (and reg (fboundp reg))
        (funcall (symbol-function reg) "mupdf" sym-pm)))

    ;; Subscribe to buffer-opened hook for sidecar/last-position/modeline.
    (unless *installed-p*
      (let ((add (find-symbol "ADD-HOOK" :limn/hooks)))
        (when (and add (fboundp add))
          (funcall (symbol-function add) "event/buffer-opened"
                   (lambda (ev)
                     (when (equal (getf ev :|engine|) "mupdf")
                       (handler-case
                           (pdf-mode-on-buffer-opened
                            :buffer-id (getf ev :|buffer-id|)
                            :path (getf ev :|path|)
                            :engine "mupdf")
                         (error () nil)))))
          (funcall (symbol-function add) "event/buffer-closed"
                   (lambda (ev)
                     (handler-case
                         (pdf-mode-on-buffer-closed
                          :buffer-id (getf ev :|buffer-id|))
                       (error () nil))))
          ;; v0.39: mouse-driven text selection.
          ;; Left-click clears old selection; left-drag extends it.
          ;; NB: hook names must use the "event/" prefix — that is what
          ;; limn/dispatch:event-hook-name returns, and what the pump
          ;; thread fires.  Bare "mouse-click" / "mouse-drag" never
          ;; matched; that was the root cause of the feature not working.
          (funcall (symbol-function add) "event/mouse-click"
                   (lambda (ev)
                     (handler-case (%on-mouse-click ev) (error () nil))))
          (funcall (symbol-function add) "event/mouse-drag"
                   (lambda (ev)
                     (handler-case (%on-mouse-drag ev) (error () nil)))))))

    (setf *installed-p* t)
    sym-pm))

;;; Auto-install on load (idempotent).
(install)
