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
   #:*pdf-zoom-in-factor*
   #:*pdf-zoom-out-factor*
   #:*pdf-annotation-color*
   ;; §B search state
   #:*pdf-search-state* #:make-pdf-search-state
   #:pdf-search-state-buffer-id #:pdf-search-state-query
   #:pdf-search-state-hits #:pdf-search-state-current-index
   #:pdf-search-execute #:pdf-search-overlay-payload
   #:pdf-search-advance #:pdf-search-retreat #:pdf-search-reset
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
(limn/custom:defcustom *pdf-scroll-step* 3
  "Number of lines (approx) to scroll on j/k."
  :type 'integer :group 'pdf-mode)

#-:limn/custom-available
(defvar *pdf-scroll-step* 3
  "Lines to scroll on j/k.")

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

(defvar *pdf-search-state* nil
  "Currently active search state (one slot — single search at a time).")

(defvar *pdf-last-search-query* nil
  "Last query string used for / (Emacs convention: empty input replays).")

(defvar *pdf-wrapped-message* "Wrapped"
  "Text shown in echo area when search wraps.")

(defun pdf-search-execute (buffer-id query &key case-sensitive)
  "Send buffer/search wire call, store result in *pdf-search-state*,
   return state object. Empty query stored but no wire call."
  (when (and query (> (length query) 0))
    (setf *pdf-last-search-query* query)
    (let* ((r (%limn-call "buffer/search"
                           :|buffer-id| buffer-id
                           :|query| query
                           :|case-sensitive| (if case-sensitive t :false)))
           (d (%response-data r))
           (hits (and d (getf d :|hits|))))
      (setf *pdf-search-state*
            (make-pdf-search-state :buffer-id buffer-id
                                    :query query
                                    :hits (or hits '())
                                    :current-index 0))
      ;; v0.25 search-history integration (§T)
      (let ((add (find-symbol "ADD-TO-HISTORY" :limn/history)))
        (when (and add (fboundp add))
          (handler-case
              (funcall (symbol-function add) '*search-history* query)
            (error () nil))))
      *pdf-search-state*)))

(defun pdf-search-reset ()
  "Clear *pdf-search-state* and emit empty overlays."
  (setf *pdf-search-state* nil)
  (%limn-call "view/overlays" :|win-id| "w1" :|layers| '()))

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

(defun pdf-search-overlay-payload (state)
  "Generate overlays plist list. Current hit = opacity 0.6;
   others = 0.25. Multi-rect hits each get their own overlay entry."
  (when (and state (pdf-search-state-hits state))
    (let ((current-idx (pdf-search-state-current-index state))
          (acc nil)
          (i 0))
      (dolist (hit (pdf-search-state-hits state))
        (let* ((page (getf hit :|page|))
               (rects (getf hit :|rects|))
               (op (if (= i current-idx) 0.6 0.25)))
          (dolist (rect rects)
            (push (list :|type| "rect"
                         :|page| page
                         :|rect| rect
                         :|color| "#FFD700"
                         :|opacity| op)
                  acc)))
        (incf i))
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
   silent-skip; signals error / emits message on hard fail (no silent ok)."
  (let ((spath (%effective-sidecar-path path))
        (data (pdf-annotations-serialize anns)))
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
  "Convenience: load + overlay-payload."
  (pdf-annotations-overlay-payload (pdf-annotations-load path)))

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
  "Look up + return the annotation at (page, x, y) on PATH's sidecar."
  (pdf-annotation-at (pdf-annotations-load path) page x y))

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
    (let* ((v (limn/pdf-mode::%focused-view))
           (pc (or (getf v :|page-count|) 1))
           (target (limn/pdf-mode::%clamp-page (or prefix 0) pc)))
      (limn/pdf-mode::%page-set target))))

(limn/pdf-mode::%defcmd pdf-scroll-down nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (off (or (getf v :|offset-y|) 0.0))
           (step (/ limn/pdf-mode:*pdf-scroll-step* 30.0)))
      ;; Move within page via offset-y if engine supports it; otherwise
      ;; the wire layer ignores the field.
      (limn/pdf-mode::%limn-call "view/set" :|win-id| "w1"
                                  :|offset-y| (+ off step)))))

(limn/pdf-mode::%defcmd pdf-scroll-up nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (off (or (getf v :|offset-y|) 0.0))
           (step (/ limn/pdf-mode:*pdf-scroll-step* 30.0)))
      (limn/pdf-mode::%limn-call "view/set" :|win-id| "w1"
                                  :|offset-y| (max 0.0 (- off step))))))

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
    (let* ((v (limn/pdf-mode::%focused-view))
           (cur (getf v :|dark-mode|))
           (next (if (or (null cur) (eq cur :false)) t :false)))
      (limn/pdf-mode::%limn-call "bridge/engine-params"
                                  :|win-id| "w1" :|dark-mode| next))))

(limn/pdf-mode::%defcmd pdf-rotate-cw nil
  (lambda ()
    (let* ((v (limn/pdf-mode::%focused-view))
           (rot (or (getf v :|rotation|) 0))
           (next (mod (+ rot 90) 360)))
      (limn/pdf-mode::%limn-call "bridge/engine-params"
                                  :|win-id| "w1" :|rotation| next))))

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
               (state (limn/pdf-mode:pdf-search-execute buf query)))
          (when state
            (limn/pdf-mode::%limn-call
             "view/overlays" :|win-id| "w1"
             :|layers| (limn/pdf-mode:pdf-search-overlay-payload state))
            ;; Jump view to first hit page if any.
            (let ((hits (limn/pdf-mode:pdf-search-state-hits state)))
              (when (and hits (consp hits))
                (let ((p (getf (first hits) :|page|)))
                  (when (integerp p)
                    (limn/pdf-mode::%page-set p)))))))))))

(limn/pdf-mode::%defcmd pdf-isearch-next nil
  (lambda ()
    (let ((s limn/pdf-mode:*pdf-search-state*))
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
          (limn/pdf-mode::%limn-call
           "view/overlays" :|win-id| "w1"
           :|layers| (limn/pdf-mode:pdf-search-overlay-payload s)))))))

(limn/pdf-mode::%defcmd pdf-isearch-prev nil
  (lambda ()
    (let ((s limn/pdf-mode:*pdf-search-state*))
      (when s
        (limn/pdf-mode:pdf-search-retreat s)
        (let* ((hits (limn/pdf-mode:pdf-search-state-hits s)))
          (when (consp hits)
            (let* ((hit (nth (limn/pdf-mode:pdf-search-state-current-index s)
                              hits))
                   (p (getf hit :|page|)))
              (when (integerp p) (limn/pdf-mode::%page-set p)))))
        (limn/pdf-mode::%limn-call
         "view/overlays" :|win-id| "w1"
         :|layers| (limn/pdf-mode:pdf-search-overlay-payload s))))))

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
         (limn/pdf-mode:pdf-search-reset))))))

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

(limn/pdf-mode::%defcmd pdf-toc nil
  (lambda ()
    (let* ((bid (limn/pdf-mode::%focused-buffer-id))
           (r (and bid (limn/pdf-mode::%limn-call "buffer/toc"
                                                    :|buffer-id| bid)))
           (d (limn/pdf-mode::%response-data r))
           (items (and d (getf d :|items|))))
      (when (listp items)
        (let ((text (limn/pdf-mode:format-toc-tree items)))
          (limn/pdf-mode::%limn-call
           "bridge/win-float-create"
           :|name| limn/pdf-mode:*pdf-toc-buffer-name*
           :|text| text))))))

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

(defun limn/pdf-mode:pdf-set-bookmark-name (buffer-id char-name page)
  (limn/pdf-mode::%limn-call "bookmark/set"
                              :|buffer-id| buffer-id
                              :|name| char-name
                              :|page| page
                              :|x| 0.0 :|y| 0.0
                              :|note| ""))

(defun limn/pdf-mode:pdf-jump-bookmark-name (buffer-id char-name)
  (let* ((r (limn/pdf-mode::%limn-call "bookmark/get"
                                         :|buffer-id| buffer-id
                                         :|name| char-name))
         (d (and (limn/pdf-mode::%ok? r) (limn/pdf-mode::%response-data r)))
         (page (and d (getf d :|page|))))
    (when (integerp page)
      (limn/pdf-mode::%page-set page))))

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

(defun limn/pdf-mode:pdf-format-modeline (path page page-count zoom)
  "Format \"PDF: name [P/T] Z%\". Page is 1-indexed in display."
  (let ((basename (file-namestring (pathname path)))
        (zoom-pct (round (* 100 zoom))))
    (format nil "PDF: ~a   [~a / ~a]   ~a%"
            basename (1+ page) page-count zoom-pct)))

(defun limn/pdf-mode:pdf-mode-update-modeline (&key buffer-id path)
  (declare (ignore buffer-id))
  (let* ((v (limn/pdf-mode::%focused-view))
         (page (or (getf v :|page|) 0))
         (pc (or (getf v :|page-count|) 1))
         (zoom (or (getf v :|zoom|) 1.0))
         (label (limn/pdf-mode:pdf-format-modeline
                  (or path "/tmp/unknown.pdf")
                  page pc zoom)))
    (limn/pdf-mode::%limn-call "modeline/set" :|left| label)))

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
    ;; Load + paint annotations
    (let ((anns (limn/pdf-mode:pdf-annotations-load path)))
      (when anns
        (limn/pdf-mode::%limn-call
         "view/overlays" :|win-id| "w1"
         :|layers| (limn/pdf-mode:pdf-annotations-overlay-payload anns))))
    ;; Restore last-position
    (handler-case
        (limn/pdf-mode:pdf-mode-restore-last-position
         :buffer-id buffer-id :path path)
      (error () nil))
    ;; Update modeline
    (handler-case
        (limn/pdf-mode:pdf-mode-update-modeline
         :buffer-id buffer-id :path path)
      (error () nil))))

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
  ;; Clear search state
  (let ((s limn/pdf-mode:*pdf-search-state*))
    (when (and s (or (null buffer-id)
                     (equal buffer-id
                            (limn/pdf-mode:pdf-search-state-buffer-id s))))
      (setf limn/pdf-mode:*pdf-search-state* nil))))

(defun limn/pdf-mode:pdf-mode-on-buffer-focused (&key buffer-id)
  "Called when focus switches to BUFFER-ID. Reset stale per-buffer state."
  (let ((s limn/pdf-mode:*pdf-search-state*))
    (when (and s
               (not (equal buffer-id
                            (limn/pdf-mode:pdf-search-state-buffer-id s))))
      (setf limn/pdf-mode:*pdf-search-state* nil))))

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
  "Wrap a defcommand symbol as keymap binding lambda (mirrors text-mode)."
  (lambda (ev)
    (let ((*last-key* (getf ev :|key|)))
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
      ;; navigation
      (%def km "j"        (intern "PDF-SCROLL-DOWN" :cl-user))
      (%def km "k"        (intern "PDF-SCROLL-UP"   :cl-user))
      (%def km "<down>"   (intern "PDF-SCROLL-DOWN" :cl-user))
      (%def km "<up>"     (intern "PDF-SCROLL-UP"   :cl-user))
      (%def km "n"        (intern "PDF-NEXT-PAGE"   :cl-user))
      (%def km "p"        (intern "PDF-PREV-PAGE"   :cl-user))
      (%def km "J"        (intern "PDF-NEXT-PAGE"   :cl-user))
      (%def km "K"        (intern "PDF-PREV-PAGE"   :cl-user))
      (%def km "G"        (intern "PDF-LAST-PAGE"   :cl-user))
      (%def km "g g"      (intern "PDF-FIRST-PAGE"  :cl-user))
      ;; zoom
      (%def km "+"        (intern "PDF-ZOOM-IN"     :cl-user))
      (%def km "="        (intern "PDF-ZOOM-IN"     :cl-user))
      (%def km "-"        (intern "PDF-ZOOM-OUT"    :cl-user))
      (%def km "0"        (intern "PDF-ZOOM-RESET"  :cl-user))
      (%def km "W"        (intern "PDF-FIT-WIDTH"   :cl-user))
      (%def km "d"        (intern "PDF-TOGGLE-DARK" :cl-user))
      (%def km "r"        (intern "PDF-ROTATE-CW"   :cl-user))
      ;; search
      (%def km "/"        (intern "PDF-ISEARCH-FORWARD" :cl-user))
      ;; v0.37 Phase F: C-g during/after a search clears search-state +
      ;; overlays.  Without this binding, C-g hits the global keyboard-
      ;; quit which only closes the minibuffer — leaving stale search
      ;; highlights painted on the page (v027-search Ω4 saw 122 overlays
      ;; remaining after C-g).  pdf-isearch-quit is idempotent so binding
      ;; it here is safe even when no search is active.
      (%def km "C-g"      (intern "PDF-ISEARCH-QUIT" :cl-user))
      ;; annotation
      (%def km "h"        (intern "PDF-HIGHLIGHT-SELECTION" :cl-user))
      (%def km "H"        (intern "PDF-ANNOTATE-SELECTION"  :cl-user))
      ;; TOC
      (%def km "t"        (intern "PDF-TOC" :cl-user))

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
              (dolist (entry '(("j" pdf-scroll-down) ("k" pdf-scroll-up)
                                ("<down>" pdf-scroll-down)
                                ("<up>" pdf-scroll-up)
                                ("n" pdf-next-page) ("p" pdf-prev-page)
                                ("J" pdf-next-page) ("K" pdf-prev-page)
                                ("G" pdf-last-page) ("g g" pdf-first-page)
                                ("+" pdf-zoom-in)   ("=" pdf-zoom-in)
                                ("-" pdf-zoom-out)  ("0" pdf-zoom-reset)
                                ("W" pdf-fit-width)
                                ("d" pdf-toggle-dark)
                                ("r" pdf-rotate-cw)
                                ("/" pdf-isearch-forward)
                                ("C-g" pdf-isearch-quit)
                                ("h" pdf-highlight-selection)
                                ("H" pdf-annotate-selection)
                                ("t" pdf-toc)))
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
                       (error () nil)))))))

    (setf *installed-p* t)
    sym-pm))

;;; Auto-install on load (idempotent).
(install)
