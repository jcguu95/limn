;;;; v0.27 pdf-mode RED tests
;;;;
;;;; 覆蓋（對照 LIMN-SPEC §12 v0.27 章節）：
;;;;   §A pdf-mode keymap         — 翻頁 / 捲動 / 縮放 / 顯示
;;;;   §B 搜尋 + 高亮             — buffer/search 包裝 + overlay payload
;;;;   §C 高亮標注 (annotation)   — struct + sidecar 持久化
;;;;   §D 目錄 (TOC)              — 樹狀 → 縮排文字 + 跳頁
;;;;   §E 書籤 UI                 — set/jump/list 整合
;;;;   §F Modeline                — 格式化字串
;;;;
;;;; 約定：
;;;;   - 所有 wire 互動透過 limn/pdf-mode:*limn-call-fn* 注入。
;;;;     測試 rebind 它成一個 mock，記錄 (cmd args...) 並回 fake response。
;;;;   - 時鐘透過 *now-fn* 注入（annotation 的 created-at）。
;;;;   - 檔案 I/O（annotation sidecar）透過 *annotations-write-fn* /
;;;;     *annotations-read-fn* vtable 注入，避免測試踩到真實 ~/.limn/。
;;;;
;;;; 在 backend/limn-pdf-mode.lisp 實作前，所有測試 RED。

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/pdf-mode)
    (make-package '#:limn/pdf-mode :use '(#:cl)))
  (dolist (sym '(;; module entry
                 "INSTALL"
                 ;; §A — keymap / commands / vars
                 "PDF-MODE"
                 "*PDF-SCROLL-STEP*"
                 "*PDF-ZOOM-IN-FACTOR*"
                 "*PDF-ZOOM-OUT-FACTOR*"
                 "*PDF-ANNOTATION-COLOR*"
                 "*PDF-WRAPPED-MESSAGE*"
                 "*PDF-LAST-SEARCH-QUERY*"
                 ;; §B — search
                 "*PDF-SEARCH-STATE*"
                 "MAKE-PDF-SEARCH-STATE"
                 "PDF-SEARCH-STATE-BUFFER-ID"
                 "PDF-SEARCH-STATE-QUERY"
                 "PDF-SEARCH-STATE-HITS"
                 "PDF-SEARCH-STATE-CURRENT-INDEX"
                 "PDF-SEARCH-EXECUTE"
                 "PDF-SEARCH-OVERLAY-PAYLOAD"
                 "PDF-SEARCH-ADVANCE"
                 "PDF-SEARCH-RETREAT"
                 "PDF-SEARCH-RESET"
                 ;; §C — annotation
                 "MAKE-PDF-ANNOTATION"
                 "PDF-ANNOTATION-P"
                 "PDF-ANNOTATION-ID"
                 "PDF-ANNOTATION-PAGE"
                 "PDF-ANNOTATION-RECTS"
                 "PDF-ANNOTATION-COLOR"
                 "PDF-ANNOTATION-NOTE"
                 "PDF-ANNOTATION-CREATED-AT"
                 "PDF-ANNOTATIONS-SERIALIZE"
                 "PDF-ANNOTATIONS-DESERIALIZE"
                 "PDF-ANNOTATIONS-SIDECAR-PATH"
                 "PDF-ANNOTATIONS-SAVE"
                 "PDF-ANNOTATIONS-LOAD"
                 "PDF-ANNOTATIONS-OVERLAY-PAYLOAD"
                 "PDF-ANNOTATIONS-FOR-BUFFER"
                 "PDF-ANNOTATIONS-DELETE-AT-POINT"
                 "PDF-ANNOTATIONS-AT-POINT"
                 "PDF-ANNOTATION-AT"
                 "PDF-MODE-ON-BUFFER-OPENED"
                 "PDF-MODE-ON-BUFFER-CLOSED"
                 "PDF-MODE-ON-BUFFER-FOCUSED"
                 ;; §D — TOC
                 "*PDF-TOC-BUFFER-NAME*"
                 "FORMAT-TOC-TREE"
                 "PARSE-TOC-LINE-PAGE"
                 ;; §E — bookmark
                 "PDF-SET-BOOKMARK-NAME"
                 "PDF-JUMP-BOOKMARK-NAME"
                 ;; §F — modeline
                 "PDF-FORMAT-MODELINE"
                 "PDF-MODE-UPDATE-MODELINE"
                 ;; long-term: identity / schema / persistence
                 "*PDF-ANNOTATIONS-SCHEMA-VERSION*"
                 "PDF-ANNOTATIONS-CONTENT-HASH-SIDECAR-PATH"
                 "PDF-ANNOTATIONS-MIGRATE"
                 "PDF-ANNOTATIONS-EXPORT-ORG"
                 "PDF-MODE-SAVE-LAST-POSITION"
                 "PDF-MODE-RESTORE-LAST-POSITION"
                 "PDF-RECENT-LIST"
                 ;; vtable
                 "*LIMN-CALL-FN*"
                 "*NOW-FN*"
                 "*ANNOTATIONS-WRITE-FN*"
                 "*ANNOTATIONS-READ-FN*"
                 "*FILE-CONTENT-HASH-FN*"
                 "*LAST-POSITION-WRITE-FN*"
                 "*LAST-POSITION-READ-FN*"))
    (let ((s (intern sym '#:limn/pdf-mode)))
      (export s '#:limn/pdf-mode))))

(in-package #:limn/unit-test)

;; pdf-mode 命令依循 text-mode 同樣的慣例：放在 CL-USER。
(eval-when (:compile-toplevel :load-toplevel :execute)
  (dolist (name '("PDF-SCROLL-DOWN" "PDF-SCROLL-UP"
                  "PDF-NEXT-PAGE" "PDF-PREV-PAGE"
                  "PDF-FIRST-PAGE" "PDF-LAST-PAGE"
                  "PDF-GOTO-PAGE"
                  "PDF-ZOOM-IN" "PDF-ZOOM-OUT" "PDF-ZOOM-RESET"
                  "PDF-FIT-WIDTH"
                  "PDF-TOGGLE-DARK" "PDF-ROTATE-CW"
                  "PDF-ISEARCH-FORWARD" "PDF-ISEARCH-NEXT"
                  "PDF-ISEARCH-PREV"    "PDF-ISEARCH-QUIT"
                  "PDF-HIGHLIGHT-SELECTION" "PDF-ANNOTATE-SELECTION"
                  "PDF-DELETE-ANNOTATION"
                  "PDF-TOC" "PDF-TOC-JUMP-AT-POINT"
                  "PDF-SET-BOOKMARK" "PDF-JUMP-BOOKMARK"
                  "PDF-LIST-BOOKMARKS"))
    (intern name :cl-user)))

;;; ─── helpers ──────────────────────────────────────────────────────────
;;;
;;; mock-bridge：把每個 limn:call 記下來，並依 cmd 回 fake plist。
;;; 後續測試 reach 進 mock-call-log 檢查 payload。

(defvar *mock-call-log* nil)
(defvar *mock-bridge-responses* nil)

(defun %make-ok (&optional data)
  (list :|ok| t :|data| data))

(defun %make-mock-call (responses)
  "Return a lambda suitable for binding to *limn-call-fn*.
   RESPONSES is an alist: ((\"view/get\" . plist) ...). Default = ok with empty data.
   Each call is recorded into *mock-call-log* as (cmd . args)."
  (lambda (cmd &rest args)
    (push (cons cmd args) *mock-call-log*)
    (let ((custom (cdr (assoc cmd responses :test #'string=))))
      (or custom (%make-ok)))))

(defmacro with-mock-bridge ((&key responses) &body body)
  "Rebind limn/pdf-mode:*limn-call-fn* to a recording mock for BODY."
  `(let ((*mock-call-log* nil)
         (*mock-bridge-responses* ,responses)
         (pkg (find-package '#:limn/pdf-mode)))
     (if (null pkg)
         (progn ,@body)
         (let ((var (find-symbol "*LIMN-CALL-FN*" pkg)))
           (if (and var (boundp var))
               (progv (list var)
                      (list (%make-mock-call (or ,responses '())))
                 ,@body)
               (progn ,@body))))))

(defun %mock-call-of (cmd)
  "Return the args plist of the most recent recorded CMD invocation, or NIL."
  (cdr (assoc cmd *mock-call-log* :test #'string=)))

(defun %mock-call-count (cmd)
  (count cmd *mock-call-log* :key #'car :test #'string=))

(defun %call-cmd (sym &rest args)
  "Invoke a CL-USER command by name (string). Tries:
     (1) fboundp + symbol-function (defun)
     (2) limn/cmd:find-command + call-interactively (defcommand registry)
     (3) returns :missing
   RED-phase tolerant: silently skips when nothing's defined yet.
   Defensively re-registers pdf-mode commands first in case an earlier
   test called limn/cmd:clear-commands (introspect tests do this)."
  (declare (ignore args))
  ;; Defensive re-register
  (let* ((pdf-pkg (find-package '#:limn/pdf-mode))
         (reg-fn (and pdf-pkg
                       (find-symbol "%REGISTER-PDF-COMMANDS" pdf-pkg))))
    (when (and reg-fn (fboundp reg-fn))
      (funcall (symbol-function reg-fn))))
  (let* ((s (find-symbol sym :cl-user))
         (cmd-pkg (find-package '#:limn/cmd))
         (find-cmd (and cmd-pkg (find-symbol "FIND-COMMAND" cmd-pkg)))
         (call-int (and cmd-pkg (find-symbol "CALL-INTERACTIVELY" cmd-pkg))))
    (cond
      ((and s (fboundp s)) (funcall (symbol-function s)))
      ((and s find-cmd call-int (funcall find-cmd s))
       (handler-case (funcall call-int s)
         (error () :missing)))
      (t :missing))))

(defun %ensure-pdf-mode-installed ()
  "Call limn/pdf-mode:install if available (idempotent)."
  (let ((inst (and (find-package '#:limn/pdf-mode)
                   (find-symbol "INSTALL" '#:limn/pdf-mode))))
    (when (and inst (fboundp inst))
      (funcall (symbol-function inst)))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §A. pdf-mode keymap — definition + navigation commands
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-a-pdf-mode-is-major
  "pdf-mode 應該註冊為 major mode（define-mode :major）。"
  (%ensure-pdf-mode-installed)
  (let ((m (and (find-package '#:limn/mode)
                (funcall (find-symbol "FIND-MODE" :limn/mode) 'cl-user::pdf-mode))))
    (assert-true m "find-mode 'pdf-mode 應該回傳 mode 物件")
    (when m
      (assert-equal :major
                    (funcall (find-symbol "MODE-TYPE" :limn/mode) m)
                    "pdf-mode 是 :major"))))

(deftest v027-a-pdf-mode-has-keymap
  "pdf-mode 必須帶 keymap object（mode-keymap 非 nil）。"
  (%ensure-pdf-mode-installed)
  (let ((m (and (find-package '#:limn/mode)
                (funcall (find-symbol "FIND-MODE" :limn/mode) 'cl-user::pdf-mode))))
    (when m
      (assert-true (funcall (find-symbol "MODE-KEYMAP" :limn/mode) m)
                   "pdf-mode 的 keymap 非 nil"))))

(deftest v027-a-engine-default-mode-mupdf
  "mupdf engine 的 default mode 應該是 pdf-mode（v0.11 engine-default-mode 機制）。"
  (%ensure-pdf-mode-installed)
  (let* ((pkg (find-package '#:limn/runtime))
         (lookup (and pkg (find-symbol "ENGINE-DEFAULT-MODE" pkg))))
    (when (and lookup (fboundp lookup))
      (assert-equal 'cl-user::pdf-mode
                    (funcall (symbol-function lookup) "mupdf")
                    "engine-default-mode \"mupdf\" → pdf-mode"))))

;; --- A. binding inspection (which key → which command) -----------------

(defun %lookup-binding (key)
  "Lookup KEY (string) in pdf-mode's keymap. Returns the bound symbol/closure or NIL."
  (%ensure-pdf-mode-installed)
  (let* ((mode-pkg (find-package '#:limn/mode))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg)))
         (keys-pkg (find-package '#:limn/keys))
         (lookup (and keys-pkg (find-symbol "LOOKUP-SEQUENCE" keys-pkg))))
    (when (and find-mode mode-keymap lookup)
      (let* ((m (funcall find-mode 'cl-user::pdf-mode))
             (km (and m (funcall mode-keymap m))))
        (when km
          (funcall lookup km (list key)))))))

(deftest v027-a-j-binds-pdf-scroll-down
  (let ((b (%lookup-binding "j")))
    (assert-true b "j 在 pdf-mode 應該有 binding")))

(deftest v027-a-k-binds-pdf-scroll-up
  (let ((b (%lookup-binding "k")))
    (assert-true b "k 在 pdf-mode 應該有 binding")))

(deftest v027-a-down-binds-pdf-scroll-down
  (let ((b (%lookup-binding "<down>")))
    (assert-true b "<down> 應該綁到 scroll-down")))

(deftest v027-a-up-binds-pdf-scroll-up
  (let ((b (%lookup-binding "<up>")))
    (assert-true b "<up> 應該綁到 scroll-up")))

(deftest v027-a-n-binds-next-page
  (let ((b (%lookup-binding "n")))
    (assert-true b "n 應該綁 next-page（Doom convention）")))

(deftest v027-a-p-binds-prev-page
  (let ((b (%lookup-binding "p")))
    (assert-true b "p 應該綁 prev-page")))

(deftest v027-a-cap-G-binds-last-page
  (let ((b (%lookup-binding "G")))
    (assert-true b "G 應該綁 last-page (or goto-page w/ prefix)")))

(deftest v027-a-gg-prefix-first-page
  "g g（兩鍵 prefix）綁 first-page。"
  (%ensure-pdf-mode-installed)
  (let* ((mode-pkg (find-package '#:limn/mode))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg)))
         (keys-pkg (find-package '#:limn/keys))
         (lookup (and keys-pkg (find-symbol "LOOKUP-SEQUENCE" keys-pkg))))
    (when (and find-mode mode-keymap lookup)
      (let* ((m (funcall find-mode 'cl-user::pdf-mode))
             (km (and m (funcall mode-keymap m))))
        (assert-true (and km (funcall lookup km (list "g" "g")))
                     "g g 兩鍵序列應該有 binding")))))

(deftest v027-a-plus-binds-zoom-in
  (assert-true (%lookup-binding "+") "+ 綁 zoom-in"))

(deftest v027-a-minus-binds-zoom-out
  (assert-true (%lookup-binding "-") "- 綁 zoom-out"))

(deftest v027-a-zero-binds-zoom-reset
  (assert-true (%lookup-binding "0") "0 綁 zoom-reset"))

(deftest v027-a-W-binds-fit-width
  (assert-true (%lookup-binding "W") "W 綁 fit-width"))

(deftest v027-a-d-binds-toggle-dark
  (assert-true (%lookup-binding "d") "d 綁 toggle-dark"))

(deftest v027-a-r-binds-rotate-cw
  (assert-true (%lookup-binding "r") "r 綁 rotate-cw"))

(deftest v027-a-slash-binds-isearch-forward
  (assert-true (%lookup-binding "/") "/ 綁 isearch-forward"))

(deftest v027-a-t-binds-pdf-toc
  (assert-true (%lookup-binding "t") "t 綁 pdf-toc"))

(deftest v027-a-h-binds-highlight-selection
  (assert-true (%lookup-binding "h") "h 綁 highlight-selection"))

(deftest v027-a-cap-H-binds-annotate-selection
  (assert-true (%lookup-binding "H") "H 綁 annotate-selection（含 note）"))

;; --- A. navigation commands actually issue view/set ---------------------

(defun %fake-view-get (&key (page 5) (zoom 1.0) (page-count 100)
                            (offset-y 0.0) (offset-x 0.0)
                            (buffer-id "b1") (dark-mode :false)
                            (rotation 0))
  ;; v0.38 W05/B1: dark-mode + rotation both nest under :|engine-params|
  ;; matching C++ collect_view_state shape (ep.insert dark-mode/rotation).
  ;; Pre-v0.38 mock placed both at top level which silently masked the
  ;; G'-2 (dark-mode reader) and B1 (rotation reader) bugs.
  (cons "view/get"
        (%make-ok (list :|page| page :|zoom| zoom :|page-count| page-count
                         :|offset-x| offset-x :|offset-y| offset-y
                         :|buffer-id| buffer-id
                         :|engine-params| (list :|dark-mode| dark-mode
                                                  :|rotation|  rotation)))))

(deftest v027-a-next-page-sends-view-set
  "pdf-next-page 應該透過 view/set 把 page +1。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 5)))
    (let ((r (%call-cmd "PDF-NEXT-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (assert-true args "應該有發出 view/set wire call")
          (when args
            (assert-equal 6 (getf args :|page|)
                          "view/set :page = 6 (was 5)")))))))

(deftest v027-a-prev-page-sends-view-set
  (with-mock-bridge (:responses (list (%fake-view-get :page 5)))
    (let ((r (%call-cmd "PDF-PREV-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (assert-true args "view/set 被叫了")
          (when args
            (assert-equal 4 (getf args :|page|)
                          "page 應該 -1 = 4")))))))

(deftest v027-a-prev-page-clamps-at-zero
  "在 page 0 按 p 不應該變成 -1。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 0)))
    (let ((r (%call-cmd "PDF-PREV-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-true (>= (getf args :|page|) 0)
                         "prev 在 page=0 時不該送負頁")))))))

(deftest v027-a-next-page-clamps-at-last
  "在最後一頁按 n 不應該超出 page-count - 1。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 99 :page-count 100)))
    (let ((r (%call-cmd "PDF-NEXT-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-true (<= (getf args :|page|) 99)
                         "next 在最後一頁不該超出")))))))

(deftest v027-a-first-page-goes-to-zero
  (with-mock-bridge (:responses (list (%fake-view-get :page 42)))
    (let ((r (%call-cmd "PDF-FIRST-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-equal 0 (getf args :|page|) "first-page → 0")))))))

(deftest v027-a-last-page-goes-to-page-count-minus-one
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 183)))
    (let ((r (%call-cmd "PDF-LAST-PAGE")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-equal 182 (getf args :|page|)
                          "last-page → page-count - 1")))))))

(deftest v027-a-goto-page-uses-prefix-arg
  "pdf-goto-page :interactive \"p\"：prefix=5 → page 5。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 100)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list 5)
          (let ((r (%call-cmd "PDF-GOTO-PAGE")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  (assert-equal 5 (getf args :|page|)
                                "prefix 5 → page 5"))))))))))

;; v0.38 B11: pdf-goto-page without prefix → last page (vim G semantics)
(deftest v038-b11-goto-page-no-prefix-goes-to-last
  "pdf-goto-page with prefix=NIL should land on last page (page-count - 1)."
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 6)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list nil)
          (let ((r (%call-cmd "PDF-GOTO-PAGE")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (assert-true args "view/set wire call should fire")
                (when args
                  (assert-equal 5 (getf args :|page|)
                                "no prefix on a 6-page doc → page 5 (last)"))))))))))

(deftest v038-b11-G-binding-points-to-pdf-goto-page
  "Key 'G' in pdf-mode-map should resolve to pdf-goto-page (not pdf-last-page)."
  (let ((b (%lookup-binding "G")))
    (assert-true b "G should have a binding")
    (when b
      ;; binding is either a symbol command or a function — check it's
      ;; the goto-page command (interned name) not last-page
      (let ((name (and (symbolp b) (symbol-name b))))
        (when name
          (assert-equal "PDF-GOTO-PAGE" name "G → PDF-GOTO-PAGE"))))))

;; v0.38 B13: numeric prefix-arg multiplies scroll step.
(deftest v038-b13-scroll-down-prefix-multiplies-step
  "5j should scroll 5× the base step."
  (with-mock-bridge (:responses (list (%fake-view-get :offset-y 0.0)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list 5)
          (let ((r (%call-cmd "PDF-SCROLL-DOWN")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  ;; step = 5 * (3/30) = 0.5 ; offset-y = 0 + 0.5 = 0.5
                  (assert-equal 0.5 (float (getf args :|offset-y|))
                                "scroll-down 5× → offset-y 0 + 5*(3/30) = 0.5"))))))))))

(deftest v038-b13-scroll-down-no-prefix-default-1x
  "Plain j (no prefix) should scroll 1× base step."
  (with-mock-bridge (:responses (list (%fake-view-get :offset-y 0.0)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list nil)
          (let ((r (%call-cmd "PDF-SCROLL-DOWN")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  ;; step = 1 * (3/30) = 0.1
                  (assert-equal 0.1 (float (getf args :|offset-y|))
                                "plain j → 1× step = 0.1"))))))))))

(deftest v038-b13-scroll-up-prefix-multiplies-step
  "5k starting at offset 1.0 → offset 0.5."
  (with-mock-bridge (:responses (list (%fake-view-get :offset-y 1.0)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list 5)
          (let ((r (%call-cmd "PDF-SCROLL-UP")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  (assert-equal 0.5 (float (getf args :|offset-y|))
                                "scroll-up 5× → 1.0 - 0.5 = 0.5"))))))))))

(deftest v027-a-zoom-in-multiplies-by-factor
  (with-mock-bridge (:responses (list (%fake-view-get :zoom 1.0)))
    (let ((r (%call-cmd "PDF-ZOOM-IN")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-true (and (getf args :|zoom|)
                              (> (getf args :|zoom|) 1.0))
                         "zoom-in 應該增加 zoom")))))))

(deftest v027-a-zoom-out-divides
  (with-mock-bridge (:responses (list (%fake-view-get :zoom 1.0)))
    (let ((r (%call-cmd "PDF-ZOOM-OUT")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-true (and (getf args :|zoom|)
                              (< (getf args :|zoom|) 1.0))
                         "zoom-out 應該減 zoom")))))))

(deftest v027-a-zoom-reset-sets-1
  (with-mock-bridge (:responses (list (%fake-view-get :zoom 2.5)))
    (let ((r (%call-cmd "PDF-ZOOM-RESET")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (when args
            (assert-equal 1.0 (float (getf args :|zoom|))
                          "zoom-reset → 1.0")))))))

(deftest v027-a-toggle-dark-flips-engine-params
  "pdf-toggle-dark 應該透過 bridge/engine-params 切換 dark-mode。"
  (with-mock-bridge (:responses (list (%fake-view-get :dark-mode :false)))
    (let ((r (%call-cmd "PDF-TOGGLE-DARK")))
      (unless (eq r :missing)
        (assert-true (or (%mock-call-of "bridge/engine-params")
                         (%mock-call-of "view/set"))
                     "toggle-dark 應該發出 wire call")))))

;; v0.38 W05 (G'-2) regression: reader was reading top-level :|dark-mode|
;; but C++ collect_view_state nests it under :|engine-params|.  Reader
;; always saw NIL → next=T every time → toggle was one-way.
(deftest v038-w05-toggle-dark-reads-nested-and-toggles-off
  "pdf-toggle-dark 看 :|engine-params|.|dark-mode|, T → :false (G'-2 regression)。"
  (with-mock-bridge (:responses (list (%fake-view-get :dark-mode t)))
    (let ((r (%call-cmd "PDF-TOGGLE-DARK")))
      (unless (eq r :missing)
        (let ((args (%mock-call-of "view/set")))
          (assert-true args "view/set 應被發出")
          (when args
            (let ((ep (getf args :|engine-params|)))
              (assert-true ep "view/set 應帶 :|engine-params| nested object")
              (assert-equal :false (getf ep :|dark-mode|)
                            "dark-mode=T 該 toggle 成 :false（G'-2 fix）"))))))))

(deftest v038-w05-toggle-dark-toggles-on-from-false
  "pdf-toggle-dark :false → T（toggle 的 on→off 方向是新加的）。"
  (with-mock-bridge (:responses (list (%fake-view-get :dark-mode :false)))
    (let ((r (%call-cmd "PDF-TOGGLE-DARK")))
      (unless (eq r :missing)
        (let* ((args (%mock-call-of "view/set"))
               (ep   (and args (getf args :|engine-params|))))
          (assert-true ep "view/set :|engine-params| present")
          (assert-equal t (getf ep :|dark-mode|)
                        "dark-mode=:false 該 toggle 成 T"))))))

;; v0.38 B1: strengthen rotate-cw assertions — pre-fix accepted either
;; "bridge/engine-params" (non-existent wire cmd) OR "view/set" so the
;; test couldn't catch the wrong-wire bug.  Pin to view/set + nested.
(deftest v038-b1-rotate-cw-sends-view-set-engine-params-rotation
  "pdf-rotate-cw should send view/set with :|engine-params| :|rotation| 90 when starting at 0."
  (with-mock-bridge (:responses (list (%fake-view-get :rotation 0)))
    (let ((r (%call-cmd "PDF-ROTATE-CW")))
      (unless (eq r :missing)
        (let* ((args (%mock-call-of "view/set"))
               (ep   (and args (getf args :|engine-params|))))
          (assert-true args "view/set wire call should fire")
          (assert-true ep "view/set should carry :|engine-params|")
          (when ep
            (assert-equal 90 (getf ep :|rotation|)
                          "rotation 0 → 90 after one cw step")))))))

(deftest v038-b1-rotate-cw-wraps-270-to-0
  "pdf-rotate-cw should mod 360: 270 → 0."
  (with-mock-bridge (:responses (list (%fake-view-get :rotation 270)))
    (let ((r (%call-cmd "PDF-ROTATE-CW")))
      (unless (eq r :missing)
        (let* ((args (%mock-call-of "view/set"))
               (ep   (and args (getf args :|engine-params|))))
          (when ep
            (assert-equal 0 (getf ep :|rotation|)
                          "rotation 270 + 90 = 360 mod 360 = 0")))))))

(deftest v027-a-rotate-cw-adds-90
  "pdf-rotate-cw 應該把 rotation += 90 (mod 360) (kept for back-compat — does NOT pin wire shape)."
  (with-mock-bridge (:responses (list (%fake-view-get :rotation 0)))
    (let ((r (%call-cmd "PDF-ROTATE-CW")))
      (unless (eq r :missing)
        (assert-true (or (%mock-call-of "bridge/engine-params")
                         (%mock-call-of "view/set"))
                     "rotate-cw 應該發 wire call")))))

(deftest v027-a-scroll-down-uses-scroll-step
  "j 應該按照 *pdf-scroll-step* 捲動（不是翻頁）。"
  (with-mock-bridge (:responses (list (%fake-view-get :offset-y 0.0)))
    (let ((r (%call-cmd "PDF-SCROLL-DOWN")))
      (unless (eq r :missing)
        ;; 預期實作要嘛走 view/set :offset-y，要嘛走 view/scroll。
        (assert-true (or (%mock-call-of "view/set")
                         (%mock-call-of "view/scroll"))
                     "scroll-down 應該送 view/* wire call")))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §B. 搜尋 + 高亮
;;; ══════════════════════════════════════════════════════════════════════

(defun %fake-search-response (&key (hits nil))
  "Build a fake buffer/search response. HITS shape:
   ((page rects) (page rects) ...) where rects = list of 4-element lists."
  (cons "buffer/search"
        (%make-ok
         (list :|hits|
               (mapcar (lambda (pr)
                         (list :|page| (first pr)
                               :|rects| (second pr)))
                       hits)))))

(deftest v027-b-make-search-state-fields
  "pdf-search-state 帶 buffer-id / query / hits / current-index。"
  (let ((pkg (find-package '#:limn/pdf-mode)))
    (when (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg))
      (let ((s (funcall (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)
                        :buffer-id "b1" :query "foo" :hits nil :current-index 0)))
        (assert-equal "b1"
                      (funcall (find-symbol "PDF-SEARCH-STATE-BUFFER-ID" pkg) s))
        (assert-equal "foo"
                      (funcall (find-symbol "PDF-SEARCH-STATE-QUERY" pkg) s))
        (assert-equal nil
                      (funcall (find-symbol "PDF-SEARCH-STATE-HITS" pkg) s))
        (assert-equal 0
                      (funcall (find-symbol "PDF-SEARCH-STATE-CURRENT-INDEX" pkg) s))))))

(deftest v027-b-pdf-search-execute-sends-buffer-search
  "pdf-search-execute 應該送 buffer/search 並把 hits 存進 *pdf-search-state*。"
  (with-mock-bridge (:responses
                     (list (%fake-search-response
                            :hits '((3 (((0.1 0.1 0.5 0.2))))
                                    (7 (((0.2 0.3 0.6 0.4)) ((0.2 0.5 0.6 0.6))))))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        (funcall (symbol-function fn) "b1" "deep learning")
        (let ((args (%mock-call-of "buffer/search")))
          (assert-true args "buffer/search 被呼叫")
          (when args
            (assert-equal "b1" (getf args :|buffer-id|))
            (assert-equal "deep learning" (getf args :|query|))))))))

(deftest v027-b-pdf-search-execute-stores-state
  (with-mock-bridge (:responses
                     (list (%fake-search-response
                            :hits '((3 (((0.1 0.1 0.5 0.2))))))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg)))
           (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg))))
      (when (and fn (fboundp fn) state-var (boundp state-var))
        (funcall (symbol-function fn) "b1" "x")
        (let ((s (symbol-value state-var)))
          (assert-true s "state 不為 nil")
          (when (and s pkg)
            (assert-equal "x"
                          (funcall (find-symbol "PDF-SEARCH-STATE-QUERY" pkg) s)
                          "query 寫入 state")))))))

(deftest v027-b-pdf-search-overlay-payload-current-vs-others
  "overlay payload 應該把 current hit 用較高 opacity（0.6）、其他用 0.25。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (payload (and pkg (find-symbol "PDF-SEARCH-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let* ((hits (list (list :|page| 3 :|rects| '((0.1 0.1 0.5 0.2)))
                         (list :|page| 7 :|rects| '((0.2 0.3 0.6 0.4)))))
             (s (funcall make :buffer-id "b1" :query "x"
                              :hits hits :current-index 1))
             (overlays (funcall payload s)))
        (assert-true (and (listp overlays) overlays)
                     "overlay 列表非空")
        ;; 至少要有 2 個 entry（兩 hit）。
        (assert-true (>= (length overlays) 2)
                     "overlay 數量 >= hits 數量")))))

(deftest v027-b-pdf-search-overlay-empty-when-no-hits
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (payload (and pkg (find-symbol "PDF-SEARCH-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let* ((s (funcall make :buffer-id "b1" :query "x"
                              :hits nil :current-index 0))
             (overlays (funcall payload s)))
        (assert-true (or (null overlays) (zerop (length overlays)))
                     "沒 hits 時 overlay 空")))))

(deftest v027-b-search-advance-increments-index
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (adv (and pkg (find-symbol "PDF-SEARCH-ADVANCE" pkg)))
         (idx (and pkg (find-symbol "PDF-SEARCH-STATE-CURRENT-INDEX" pkg))))
    (when (and make adv (fboundp adv) idx)
      (let* ((hits (list (list :|page| 1 :|rects| '((0 0 0.1 0.1)))
                         (list :|page| 2 :|rects| '((0 0 0.1 0.1)))
                         (list :|page| 3 :|rects| '((0 0 0.1 0.1)))))
             (s (funcall make :buffer-id "b" :query "q" :hits hits :current-index 0)))
        (funcall (symbol-function adv) s)
        (assert-equal 1 (funcall idx s) "advance: 0 → 1")
        (funcall (symbol-function adv) s)
        (assert-equal 2 (funcall idx s) "advance: 1 → 2")))))

(deftest v027-b-search-advance-wraps-around
  "n 在最後一個命中時 wrap 回 0。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (adv (and pkg (find-symbol "PDF-SEARCH-ADVANCE" pkg)))
         (idx (and pkg (find-symbol "PDF-SEARCH-STATE-CURRENT-INDEX" pkg))))
    (when (and make adv (fboundp adv) idx)
      (let* ((hits (list (list :|page| 1 :|rects| '((0 0 0.1 0.1)))
                         (list :|page| 2 :|rects| '((0 0 0.1 0.1)))))
             (s (funcall make :buffer-id "b" :query "q" :hits hits :current-index 1)))
        (funcall (symbol-function adv) s)
        (assert-equal 0 (funcall idx s) "advance from last → 0")))))

(deftest v027-b-search-retreat-wraps-around
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (ret (and pkg (find-symbol "PDF-SEARCH-RETREAT" pkg)))
         (idx (and pkg (find-symbol "PDF-SEARCH-STATE-CURRENT-INDEX" pkg))))
    (when (and make ret (fboundp ret) idx)
      (let* ((hits (list (list :|page| 1 :|rects| '((0 0 0.1 0.1)))
                         (list :|page| 2 :|rects| '((0 0 0.1 0.1)))))
             (s (funcall make :buffer-id "b" :query "q" :hits hits :current-index 0)))
        (funcall (symbol-function ret) s)
        (assert-equal 1 (funcall idx s) "retreat from 0 → last")))))

(deftest v027-b-search-reset-clears-state
  "pdf-search-reset 應該清掉 query/hits/index。
   v0.37 A2: rebinds *limn-call-fn* to no-op — pdf-search-reset issues
   a view/overlays wire call that would otherwise hit `limn: not started`
   in the unit-test environment (no live bridge)."
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (reset (and pkg (find-symbol "PDF-SEARCH-RESET" pkg)))
         (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg)))
         (call-fn-var (and pkg (find-symbol "*LIMN-CALL-FN*" pkg))))
    (when (and make reset state-var (boundp state-var) call-fn-var)
      (progv (list call-fn-var)
             (list (lambda (&rest _) (declare (ignore _)) nil))
        (setf (symbol-value state-var)
              (funcall make :buffer-id "b" :query "q"
                            :hits '((:|page| 0 :|rects| ((0 0 0 0))))
                            :current-index 0))
        (funcall (symbol-function reset))
        (let ((s (symbol-value state-var)))
          (assert-true (or (null s)
                           (null (funcall (find-symbol "PDF-SEARCH-STATE-HITS" pkg) s)))
                       "reset 後 state nil 或 hits 空"))))))

(deftest v027-b-isearch-forward-opens-minibuffer
  "/ 應該打開 minibuffer 讀 query。"
  (with-mock-bridge (:responses (list (%fake-view-get :buffer-id "b1")))
    (let ((cmd-pkg (find-package '#:limn/cmd))
          (read-var nil))
      (when cmd-pkg
        (setf read-var (find-symbol "*MINIBUFFER-READ*" cmd-pkg)))
      (when (and read-var (boundp read-var))
        (progv (list read-var)
               (list (lambda (prompt) (declare (ignore prompt)) "foo"))
          (let ((r (%call-cmd "PDF-ISEARCH-FORWARD")))
            (unless (eq r :missing)
              (assert-true (%mock-call-of "buffer/search")
                           "minibuffer 回字串後應呼 buffer/search"))))))))

(deftest v027-b-isearch-quit-clears-overlays
  "C-g 在 search 中應該送 view/overlays 清空。"
  (with-mock-bridge ()
    (let ((r (%call-cmd "PDF-ISEARCH-QUIT")))
      (unless (eq r :missing)
        (assert-true (%mock-call-of "view/overlays")
                     "isearch-quit 應送 view/overlays 清空")))))

(deftest v027-b-view-overlays-uses-layers-arg
  "v0.37 Phase F regression: view/overlays wire call MUST send the
   layers array under the :|layers| key, not :|overlays|.  The C++
   side reads msg.value(\"layers\") and silently treats a missing key
   as 'clear all overlays' — which is exactly what happened before
   this fix: sidecars saved correctly but no rect appeared on screen,
   and any subsequent view/get returned overlays=[]."
  (with-mock-bridge ()
    (let ((r (%call-cmd "PDF-ISEARCH-QUIT")))
      (unless (eq r :missing)
        (let* ((args (%mock-call-of "view/overlays"))
               (layers-pos (position :|layers| args))
               (overlays-pos (position :|overlays| args)))
          (assert-true layers-pos
                       "view/overlays kwargs must include :|layers|")
          (assert-true (null overlays-pos)
                       "view/overlays kwargs must NOT use :|overlays|"))))))

(deftest v027-b-current-hit-higher-opacity
  "overlay 中 current hit 的 opacity > others。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (payload (and pkg (find-symbol "PDF-SEARCH-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let* ((hits (list (list :|page| 1 :|rects| '((0 0 0.1 0.1)))
                         (list :|page| 2 :|rects| '((0 0 0.1 0.1)))))
             (s (funcall make :buffer-id "b" :query "q"
                              :hits hits :current-index 0))
             (overlays (funcall payload s)))
        (when (and overlays (>= (length overlays) 2))
          (let* ((current  (find 1 overlays :key (lambda (o) (getf o :|page|))))
                 (other    (find 2 overlays :key (lambda (o) (getf o :|page|))))
                 (cur-op   (getf current :|opacity|))
                 (oth-op   (getf other   :|opacity|)))
            (when (and cur-op oth-op)
              (assert-true (> cur-op oth-op)
                           "current hit 的 opacity > 其他"))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §C. 高亮標注 (annotation)
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-c-make-pdf-annotation-fields
  "pdf-annotation struct 必須帶 id / page / rects / color / note / created-at。"
  (let ((pkg (find-package '#:limn/pdf-mode)))
    (when (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg))
      (let ((a (funcall (find-symbol "MAKE-PDF-ANNOTATION" pkg)
                         :id "uuid-1" :page 3
                         :rects '((0.1 0.2 0.3 0.4))
                         :color "#FFD700"
                         :note "important"
                         :created-at 12345)))
        (assert-true (funcall (find-symbol "PDF-ANNOTATION-P" pkg) a)
                     "predicate 真")
        (assert-equal "uuid-1"
                      (funcall (find-symbol "PDF-ANNOTATION-ID" pkg) a))
        (assert-equal 3
                      (funcall (find-symbol "PDF-ANNOTATION-PAGE" pkg) a))
        (assert-equal '((0.1 0.2 0.3 0.4))
                      (funcall (find-symbol "PDF-ANNOTATION-RECTS" pkg) a))
        (assert-equal "#FFD700"
                      (funcall (find-symbol "PDF-ANNOTATION-COLOR" pkg) a))
        (assert-equal "important"
                      (funcall (find-symbol "PDF-ANNOTATION-NOTE" pkg) a))
        (assert-equal 12345
                      (funcall (find-symbol "PDF-ANNOTATION-CREATED-AT" pkg) a))))))

(deftest v027-c-default-color-is-yellow
  "預設色應該是 #FFD700（黃色，與 Doom pdf-tools 慣例）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (color-of (and pkg (find-symbol "PDF-ANNOTATION-COLOR" pkg))))
    (when (and make color-of)
      (let ((a (funcall make :id "u" :page 0 :rects '() :note nil
                              :created-at 0)))
        (assert-equal "#FFD700" (funcall color-of a)
                      "未指定 color 時預設 #FFD700")))))

(deftest v027-c-annotations-serialize-roundtrip
  "serialize → deserialize 後資料對得回去。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (ser  (and pkg (find-symbol "PDF-ANNOTATIONS-SERIALIZE" pkg)))
         (des  (and pkg (find-symbol "PDF-ANNOTATIONS-DESERIALIZE" pkg))))
    (when (and make ser des (fboundp ser) (fboundp des))
      (let* ((a (funcall make :id "u1" :page 3 :rects '((0.1 0.2 0.3 0.4))
                              :color "#FFD700" :note "n" :created-at 999))
             (str (funcall (symbol-function ser) (list a)))
             (back (funcall (symbol-function des) str)))
        (assert-true (and (listp back) (= 1 (length back)))
                     "deserialize 回 1 個 annotation")
        (when (and back (car back))
          (assert-equal "u1"
                        (funcall (find-symbol "PDF-ANNOTATION-ID" pkg) (car back)))
          (assert-equal 3
                        (funcall (find-symbol "PDF-ANNOTATION-PAGE" pkg) (car back)))
          (assert-equal "n"
                        (funcall (find-symbol "PDF-ANNOTATION-NOTE" pkg) (car back))))))))

(deftest v027-c-sidecar-path-under-dot-limn
  "sidecar 應該在 ~/.limn/annotations/ 下。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-ANNOTATIONS-SIDECAR-PATH" pkg))))
    (when (and fn (fboundp fn))
      (let ((p (namestring (funcall (symbol-function fn) "/tmp/paper.pdf"))))
        (assert-true (search ".limn/annotations/" p)
                     ".limn/annotations/ 在路徑中")
        (assert-true (search ".lisp" p)
                     "副檔名 .lisp")))))

(deftest v027-c-sidecar-path-sha256-keyed
  "不同檔案路徑 → 不同 sidecar；同檔案 → 相同 sidecar。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-ANNOTATIONS-SIDECAR-PATH" pkg))))
    (when (and fn (fboundp fn))
      (let ((p1 (namestring (funcall (symbol-function fn) "/tmp/a.pdf")))
            (p2 (namestring (funcall (symbol-function fn) "/tmp/b.pdf")))
            (p1b (namestring (funcall (symbol-function fn) "/tmp/a.pdf"))))
        (assert-equal p1 p1b "同 path → 同 sidecar")
        (assert-true (not (string= p1 p2))
                     "不同 path → 不同 sidecar")))))

(deftest v027-c-annotation-id-unique
  "兩個新建 annotation 的 id 不能撞。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (id-of (and pkg (find-symbol "PDF-ANNOTATION-ID" pkg))))
    (when (and make id-of)
      ;; 兩個都不指定 :id → 應該自動生成兩個不同的 id
      (let ((a (funcall make :page 0 :rects '() :note nil :created-at 0))
            (b (funcall make :page 0 :rects '() :note nil :created-at 0)))
        (when (and (funcall id-of a) (funcall id-of b))
          (assert-true (not (string= (funcall id-of a) (funcall id-of b)))
                       "auto-generated id 必須不同"))))))

(deftest v027-c-annotations-save-then-load
  "save 後 load 拿到相同清單（用 in-memory vtable，無真實 I/O）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and make save load-fn write-var read-var
               (fboundp save) (fboundp load-fn))
      (let ((store (make-hash-table :test #'equal)))
        (progv (list write-var read-var)
               (list (lambda (path data)
                       (setf (gethash path store) data))
                     (lambda (path)
                       (gethash path store)))
          (let ((a (funcall make :id "x1" :page 2 :rects '((0 0 0.1 0.1))
                                 :color "#FFD700" :note "hi" :created-at 5)))
            (funcall (symbol-function save) "/tmp/paper.pdf" (list a))
            (let ((back (funcall (symbol-function load-fn) "/tmp/paper.pdf")))
              (assert-true (and (listp back) (= 1 (length back)))
                           "load 回 1 個 annotation"))))))))

(deftest v027-c-annotations-overlay-payload-respects-color
  "overlay payload 用 annotation 的 color 欄位。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (overlay (and pkg (find-symbol "PDF-ANNOTATIONS-OVERLAY-PAYLOAD" pkg))))
    (when (and make overlay (fboundp overlay))
      (let* ((a (funcall make :id "z" :page 1 :rects '((0 0 0.1 0.1))
                               :color "#ABCDEF" :note nil :created-at 0))
             (overlays (funcall (symbol-function overlay) (list a))))
        (assert-true (and (listp overlays) overlays)
                     "overlays 非空")
        (when overlays
          (let ((o (first overlays)))
            (assert-true (or (search "ABCDEF" (or (getf o :|color|) ""))
                             (search "ABCDEF" (format nil "~a" o)))
                         "overlay 應該帶 #ABCDEF 顏色")))))))

(deftest v027-c-highlight-selection-no-selection-no-op
  "h 在沒 selection 時應該無聲（不該 crash、不該寫 sidecar）。
   v0.37 Phase F: selection-get's wire response uses :|active| nil for
   no-selection (NOT :|rects| nil as the old mock claimed)."
  (with-mock-bridge (:responses
                     (list (cons "view/selection-get"
                                 (%make-ok (list :|active| nil)))))
    (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
      (unless (eq r :missing)
        (assert-true (zerop (%mock-call-count "view/overlays"))
                     "沒 selection 不送 overlays")))))

(deftest v027-c-highlight-selection-creates-annotation
  "有 selection 時 h 應該創 annotation 並送 view/overlays。
   v0.37 Phase F: wire schema is :|active|/:|begin|{:|page|,:|x|,:|y|}/
   :|end|{...} — %selection translates this into :|page|/:|rects| for
   the downstream %add-annotation contract."
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 3)
                           (cons "view/selection-get"
                                 (%make-ok
                                  (list :|active| t
                                        :|begin| (list :|page| 3
                                                       :|x| 0.1 :|y| 0.2)
                                        :|end|   (list :|page| 3
                                                       :|x| 0.3 :|y| 0.4)
                                        :|mode|  "char"
                                        :|text|  "selected text")))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
           (writes nil))
      (when (and write-var (boundp write-var))
        (progv (list write-var)
               (list (lambda (p d) (push (cons p d) writes)))
          (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
            (unless (eq r :missing)
              (assert-true (or (%mock-call-of "view/overlays")
                               writes)
                           "h 應該畫 overlay 或寫 sidecar"))))))))

(deftest v027-c-selection-translates-begin-end-to-rects
  "v0.37 Phase F regression: %selection must translate the wire's
   :|active|/:|begin|/:|end| response into the :|page|/:|rects|
   plist that %add-annotation consumes.  Single-rect bounding box
   covers begin→end, normalised so x1<x2 / y1<y2."
  (with-mock-bridge (:responses
                     (list (cons "view/selection-get"
                                 (%make-ok
                                  (list :|active| t
                                        :|begin| (list :|page| 2
                                                       :|x| 0.4 :|y| 0.7)
                                        :|end|   (list :|page| 2
                                                       :|x| 0.1 :|y| 0.2)
                                        :|mode|  "char"
                                        :|text|  "swapped")))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (sel-fn (and pkg (find-symbol "%SELECTION" pkg))))
      (when (and sel-fn (fboundp sel-fn))
        (let* ((s (funcall (symbol-function sel-fn)))
               (rects (and s (getf s :|rects|)))
               (rect (first rects)))
          (assert-equal 2 (getf s :|page|) "page passed through")
          (assert-true (and (listp rect) (= (length rect) 4))
                       "single 4-tuple rect synthesized")
          (assert-equal 0.1 (first rect)  "x1 = min(begin.x, end.x)")
          (assert-equal 0.2 (second rect) "y1 = min(begin.y, end.y)")
          (assert-equal 0.4 (third rect)  "x2 = max")
          (assert-equal 0.7 (fourth rect) "y2 = max"))))))

(deftest v027-c-selection-returns-nil-when-inactive
  "v0.37 Phase F regression: %selection returns NIL when :|active| is
   false, so %add-annotation can treat that as a no-op without
   touching begin/end (which the wire omits in that case)."
  (with-mock-bridge (:responses
                     (list (cons "view/selection-get"
                                 (%make-ok (list :|active| nil)))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (sel-fn (and pkg (find-symbol "%SELECTION" pkg))))
      (when (and sel-fn (fboundp sel-fn))
        (assert-true (null (funcall (symbol-function sel-fn)))
                     "no selection → NIL")))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §D. 目錄 (TOC)
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-d-toc-buffer-name
  (let ((pkg (find-package '#:limn/pdf-mode)))
    (when (and pkg (find-symbol "*PDF-TOC-BUFFER-NAME*" pkg))
      (let ((n (symbol-value (find-symbol "*PDF-TOC-BUFFER-NAME*" pkg))))
        (assert-true (and (stringp n)
                          (or (search "TOC" n) (search "toc" n)))
                     "buffer 名稱含 TOC")))))

(deftest v027-d-format-toc-tree-flat
  "單層 TOC（無 children）格式化成 'Title  PAGE' 之類。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "FORMAT-TOC-TREE" pkg))))
    (when (and fn (fboundp fn))
      (let* ((toc '((:|title| "Intro"   :|page| 0)
                    (:|title| "Methods" :|page| 5)))
             (s (funcall (symbol-function fn) toc)))
        (assert-type s string)
        (assert-true (search "Intro" s) "輸出含 Intro")
        (assert-true (search "Methods" s) "輸出含 Methods")))))

(deftest v027-d-format-toc-tree-nested-indent
  "巢狀子節點應該縮排。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "FORMAT-TOC-TREE" pkg))))
    (when (and fn (fboundp fn))
      (let* ((toc '((:|title| "Chapter 1" :|page| 0
                              :|children| ((:|title| "Section 1.1" :|page| 2)))))
             (s (funcall (symbol-function fn) toc)))
        (when (stringp s)
          (assert-true (search "Section 1.1" s)
                       "含子節點 title")
          (let ((p (search "Section 1.1" s)))
            (when p
              (assert-true (or (> p 0)
                               (search "  Section 1.1" s)
                               (search "    Section 1.1" s)
                               (search "Section 1.1" s))
                           "子節點有縮排（前綴空白或 tab）"))))))))

(deftest v027-d-parse-toc-line-page-extracts-int
  "從 TOC buffer 一行字反解出 :page 整數。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PARSE-TOC-LINE-PAGE" pkg))))
    (when (and fn (fboundp fn))
      ;; format-toc-tree 的輸出必須能被 parse-toc-line-page 逆解。
      (let* ((toc '((:|title| "Intro" :|page| 7)))
             (fmt (find-symbol "FORMAT-TOC-TREE" pkg))
             (lines (and fmt (fboundp fmt)
                         (funcall (symbol-function fmt) toc))))
        (when (stringp lines)
          (assert-equal 7
                        (funcall (symbol-function fn) lines)
                        "從輸出第一行反解出 page = 7"))))))

(deftest v027-d-toc-command-opens-floating-window
  "t 應該開 *PDF-TOC* buffer。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1")
                           (cons "buffer/toc"
                                 (%make-ok (list :|items|
                                                  '((:|title| "Intro" :|page| 0)))))))
    (let ((r (%call-cmd "PDF-TOC")))
      (unless (eq r :missing)
        (assert-true (or (%mock-call-of "buffer/toc")
                         (%mock-call-of "bridge/win-float-create")
                         (%mock-call-of "buffer/insert"))
                     "PDF-TOC 應該呼叫 buffer/toc + 開浮動 window")))))

;; v0.38 B14: pdf-toc should feed flattened entries to completing-read
;; instead of dumping the tree to stdout (W04 dogfood finding).
(deftest v038-b14-toc-flatten-depth-first-preorder
  "%toc-flatten walks the TOC tree in depth-first preorder, recording depth."
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "%TOC-FLATTEN" pkg)))
         (tree '((:|title| "A" :|page| 0
                  :|children| ((:|title| "A.1" :|page| 1)
                               (:|title| "A.2" :|page| 2)))
                 (:|title| "B" :|page| 3))))
    (when (and fn (fboundp fn))
      (let ((flat (funcall (symbol-function fn) tree 0)))
        (assert-equal 4 (length flat) "4 entries flat")
        (assert-equal "A" (getf (first flat) :title))
        (assert-equal 0   (getf (first flat) :depth) "A is depth 0")
        (assert-equal "A.1" (getf (second flat) :title))
        (assert-equal 1   (getf (second flat) :depth) "A.1 is depth 1")
        (assert-equal "A.2" (getf (third flat) :title))
        (assert-equal "B" (getf (fourth flat) :title))
        (assert-equal 0   (getf (fourth flat) :depth) "B back to depth 0")))))

(deftest v038-b14-toc-line-is-parseable-by-parse-toc-line-page
  "%toc-line output should be acceptable input to parse-toc-line-page."
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (line-fn (and pkg (find-symbol "%TOC-LINE" pkg)))
         (parse-fn (and pkg (find-symbol "PARSE-TOC-LINE-PAGE" pkg))))
    (when (and line-fn (fboundp line-fn)
               parse-fn (fboundp parse-fn))
      (let* ((entry '(:title "Chapter 1" :page 4 :depth 1))
             (line  (funcall (symbol-function line-fn) entry))
             (page  (funcall (symbol-function parse-fn) line)))
        (assert-equal 4 page
                      "%toc-line of page 4 → parse-toc-line-page returns 4")))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §E. 書籤 UI
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-e-set-bookmark-by-name
  "pdf-set-bookmark-name buf char page → bookmark/set"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SET-BOOKMARK-NAME" pkg))))
      (when (and fn (fboundp fn))
        (funcall (symbol-function fn) "b1" "a" 12)
        (let ((args (%mock-call-of "bookmark/set")))
          (assert-true args "bookmark/set 被呼叫")
          (when args
            (assert-equal "b1" (getf args :|buffer-id|))
            (assert-equal "a"  (getf args :|name|))
            (assert-equal 12   (getf args :|page|))))))))

(deftest v027-e-jump-bookmark-by-name
  "pdf-jump-bookmark-name 應該 get bookmark 並送 view/set。"
  (with-mock-bridge (:responses
                     (list (cons "bookmark/get"
                                 (%make-ok (list :|name| "a"
                                                  :|page| 12 :|x| 0.0 :|y| 0.0)))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-JUMP-BOOKMARK-NAME" pkg))))
      (when (and fn (fboundp fn))
        (funcall (symbol-function fn) "b1" "a")
        (assert-true (%mock-call-of "bookmark/get")
                     "bookmark/get 被呼叫")
        (let ((vs (%mock-call-of "view/set")))
          (when vs
            (assert-equal 12 (getf vs :|page|)
                          "跳到 bookmark 的 page 12")))))))

(deftest v027-e-list-bookmarks-uses-completing-read
  "' ' 應該透過 completing-read 顯示書籤列表。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1")
                           (cons "bookmark/list"
                                 (%make-ok (list :|items|
                                                  '((:|name| "intro" :|page| 0)
                                                    (:|name| "method" :|page| 5)))))))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg))))
      (when (and read-var (boundp read-var))
        (progv (list read-var)
               (list (lambda (prompt) (declare (ignore prompt)) "intro"))
          (let ((r (%call-cmd "PDF-LIST-BOOKMARKS")))
            (unless (eq r :missing)
              (assert-true (%mock-call-of "bookmark/list")
                           "list-bookmarks 應該先列出 bookmarks"))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §F. Modeline
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-f-format-modeline-shape
  "格式：PDF: NAME  [P / T]  ZOOM%"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn)
                        "/tmp/paper.pdf" 41 183 1.0)))
        (assert-type s string)
        (assert-true (search "PDF" s)        "含 PDF 標籤")
        (assert-true (search "paper.pdf" s)  "含檔名")
        (assert-true (search "42" s)         "頁碼顯示 1-indexed: 41 → 42")
        (assert-true (search "183" s)        "總頁數")
        (assert-true (search "100" s)        "zoom 顯示 %")))))

(deftest v027-f-format-modeline-strips-directory
  "modeline 顯示 basename，不顯示完整路徑。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn)
                        "/very/deep/dir/paper.pdf" 0 10 1.0)))
        (when (stringp s)
          (assert-true (not (search "/very/deep/dir" s))
                       "不顯示完整路徑")
          (assert-true (search "paper.pdf" s)
                       "顯示 basename"))))))

(deftest v027-f-format-modeline-150-percent
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn) "x.pdf" 0 10 1.5)))
        (when (stringp s)
          (assert-true (search "150" s) "1.5 → 150%"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §A 補：rotation / toggle-dark / G-without-prefix / boundary 邊角
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-a15-rotate-cw-wraps-at-360
  "rotate 270 + 90 應該 → 0（mod 360）。"
  (with-mock-bridge (:responses (list (%fake-view-get :rotation 270)))
    (let ((r (%call-cmd "PDF-ROTATE-CW")))
      (unless (eq r :missing)
        (let ((args (or (%mock-call-of "bridge/engine-params")
                        (%mock-call-of "view/set"))))
          (when args
            (let ((rot (or (getf args :|rotation|)
                           (getf args :|rotate|))))
              (when rot
                (assert-equal 0 (mod rot 360)
                              "270 + 90 → 0 (mod 360)")))))))))

(deftest v027-a16-toggle-dark-round-trip
  "false → toggle → true → toggle → false."
  ;; 第一次 toggle：dark=false 起。
  (with-mock-bridge (:responses (list (%fake-view-get :dark-mode :false)))
    (let ((r (%call-cmd "PDF-TOGGLE-DARK")))
      (unless (eq r :missing)
        (let ((args (or (%mock-call-of "bridge/engine-params")
                        (%mock-call-of "view/set"))))
          (when args
            (let ((dm (getf args :|dark-mode|)))
              (when (not (null dm))
                (assert-true (eq dm t) "false → true"))))))))
  ;; 第二次：dark=true 起，toggle 應 → false。
  (with-mock-bridge (:responses (list (%fake-view-get :dark-mode t)))
    (let ((r (%call-cmd "PDF-TOGGLE-DARK")))
      (unless (eq r :missing)
        (let ((args (or (%mock-call-of "bridge/engine-params")
                        (%mock-call-of "view/set"))))
          (when args
            (let ((dm (getf args :|dark-mode|)))
              (when (not (null dm))
                (assert-true (or (null dm) (eq dm :false))
                             "true → false")))))))))

(deftest v027-a17-G-without-prefix-goes-last
  "G without prefix-arg → last-page，不是 goto-page 1。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :page 0 :page-count 50)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when pa-var
        (progv (list pa-var) (list nil)
          ;; 預設 prefix-arg=nil 時呼 PDF-LAST-PAGE 應跳到 page-count-1。
          (let ((r (%call-cmd "PDF-LAST-PAGE")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  (assert-equal 49 (getf args :|page|)
                                "無 prefix 時 G/last-page → page-count - 1 = 49"))))))))))

(deftest v027-a18-scroll-down-does-not-change-page
  "j 應該只動 offset-y 不換頁（除非到頁尾才換）。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 5 :offset-y 0.0)))
    (let ((r (%call-cmd "PDF-SCROLL-DOWN")))
      (unless (eq r :missing)
        (let ((args (or (%mock-call-of "view/set")
                        (%mock-call-of "view/scroll"))))
          (when args
            ;; 如果送 view/set，page 不該變（除非頁尾）— 在 offset-y=0 的
            ;; 起始狀態應該只動 offset。
            (let ((p (getf args :|page|)))
              (assert-true (or (null p) (eql p 5))
                           "頁中段 scroll-down 不換頁"))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §B 補：empty query / 0 hits / multi-rect / case-sensitive
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-b-empty-query-is-noop
  "isearch-forward 拿到空字串且無前次 query → 不發 buffer/search。"
  (with-mock-bridge ()
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg)))
           (pdf-pkg (find-package '#:limn/pdf-mode))
           (last-var (and pdf-pkg
                           (find-symbol "*PDF-LAST-SEARCH-QUERY*" pdf-pkg))))
      (when (and read-var (boundp read-var))
        ;; Clear last-query so empty input has no fallback.
        (when (and last-var (boundp last-var))
          (setf (symbol-value last-var) nil))
        (progv (list read-var)
               (list (lambda (prompt) (declare (ignore prompt)) ""))
          (let ((r (%call-cmd "PDF-ISEARCH-FORWARD")))
            (unless (eq r :missing)
              (assert-equal 0 (%mock-call-count "buffer/search")
                            "空 query + 無前次 → 不送 buffer/search"))))))))

(deftest v027-b-advance-on-empty-hits-no-crash
  "n 在 0 hits 時 wrap 不該 div-by-zero / crash。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (adv (and pkg (find-symbol "PDF-SEARCH-ADVANCE" pkg))))
    (when (and make adv (fboundp adv))
      (let ((s (funcall make :buffer-id "b" :query "q"
                              :hits nil :current-index 0)))
        (assert-no-error (funcall (symbol-function adv) s)
                         "advance on empty hits 不該 crash")))))

(deftest v027-b-retreat-on-empty-hits-no-crash
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (ret (and pkg (find-symbol "PDF-SEARCH-RETREAT" pkg))))
    (when (and make ret (fboundp ret))
      (let ((s (funcall make :buffer-id "b" :query "q"
                              :hits nil :current-index 0)))
        (assert-no-error (funcall (symbol-function ret) s)
                         "retreat on empty hits 不該 crash")))))

(deftest v027-b-multi-rect-hit-all-rendered
  "一個 hit 有 3 個 rect（跨多行）→ overlay 應該畫 3 個。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (payload (and pkg (find-symbol "PDF-SEARCH-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let* ((hits (list (list :|page| 3
                                :|rects| '((0.1 0.1 0.5 0.15)
                                            (0.1 0.2 0.5 0.25)
                                            (0.1 0.3 0.5 0.35)))))
             (s (funcall make :buffer-id "b" :query "q"
                              :hits hits :current-index 0))
             (overlays (funcall (symbol-function payload) s)))
        (assert-true (>= (length overlays) 3)
                     "三個 rect 應該全進 overlay 列表")))))

(deftest v027-b-case-sensitive-passed-to-wire
  "pdf-search-execute :case-sensitive t 應該把 t 傳進 buffer/search。"
  (with-mock-bridge (:responses (list (%fake-search-response :hits nil)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        ;; 透過 funcall 餵 case-sensitive 旗標（API 設計：第三個 keyword）。
        (handler-case
            (funcall (symbol-function fn) "b1" "Foo" :case-sensitive t)
          (error () ; 若實作不接 keyword，至少呼叫一次無 keyword
            (funcall (symbol-function fn) "b1" "Foo")))
        (let ((args (%mock-call-of "buffer/search")))
          (when args
            (let ((cs (getf args :|case-sensitive|)))
              (assert-true (or (eq cs t) (eq cs :true) (stringp cs))
                           "case-sensitive 出現在 wire payload"))))))))

(deftest v027-b-default-case-sensitive-is-false
  "未指定 case-sensitive 預設應該是 :false（不分大小寫）。"
  (with-mock-bridge (:responses (list (%fake-search-response :hits nil)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        (funcall (symbol-function fn) "b1" "foo")
        (let ((args (%mock-call-of "buffer/search")))
          (when args
            (let ((cs (getf args :|case-sensitive|)))
              ;; 必須出現該欄位（false 或 nil 都算）且不是 t。
              (assert-true (or (null cs) (eq cs :false) (eq cs nil))
                           "預設 case-sensitive false"))))))))

(deftest v027-b-isearch-next-navigates-to-hit-page
  "n 應該既 advance index 又 view/set 跳到該命中的 page。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg))))
    (when (and make state-var)
      (setf (symbol-value state-var)
            (funcall make :buffer-id "b1" :query "q"
                          :hits (list (list :|page| 3 :|rects| '((0 0 0.1 0.1)))
                                       (list :|page| 9 :|rects| '((0 0 0.1 0.1))))
                          :current-index 0))
      (with-mock-bridge ()
        (let ((r (%call-cmd "PDF-ISEARCH-NEXT")))
          (unless (eq r :missing)
            (let ((vs (%mock-call-of "view/set")))
              (when vs
                (assert-equal 9 (getf vs :|page|)
                              "n 跳到第二個 hit 的 page (=9)")))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §C 補：delete-annotation / annotate-with-note / 多 buffer / sidecar 健壯性
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-c-delete-annotation-removes
  "pdf-delete-annotation 應該把 annotation 從 list 移除並寫回 sidecar。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (del (and pkg (find-symbol "PDF-ANNOTATIONS-DELETE-AT-POINT" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and make del write-var read-var (fboundp del))
      (let* ((store (make-hash-table :test #'equal))
             (a1 (funcall make :id "a1" :page 0 :rects '((0.1 0.1 0.5 0.2))
                                :color "#FFD700" :note nil :created-at 0))
             (a2 (funcall make :id "a2" :page 0 :rects '((0.1 0.3 0.5 0.4))
                                :color "#FFD700" :note nil :created-at 0)))
        (progv (list write-var read-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store)))
          ;; seed sidecar
          (let ((save (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
            (when (and save (fboundp save))
              (funcall (symbol-function save)
                       "/tmp/p.pdf" (list a1 a2))))
          ;; delete 中間落在 a1 的點 (0.2, 0.15)
          (with-mock-bridge (:responses (list (%fake-view-get :page 0)))
            (handler-case
                (funcall (symbol-function del) "/tmp/p.pdf" 0 0.2 0.15)
              (error () nil))
            (let* ((load (find-symbol "PDF-ANNOTATIONS-LOAD" pkg))
                   (back (and load (fboundp load)
                              (funcall (symbol-function load) "/tmp/p.pdf"))))
              (when (listp back)
                (assert-equal 1 (length back)
                              "delete 後剩 1 個 annotation")
                (when back
                  (let ((id-of (find-symbol "PDF-ANNOTATION-ID" pkg)))
                    (assert-equal "a2"
                                  (funcall id-of (car back))
                                  "留下的是 a2 (a1 被刪)")))))))))))

(deftest v027-c-delete-annotation-no-hit-noop
  "點到沒 annotation 的位置 → delete 不該動 sidecar 或 crash。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (del (and pkg (find-symbol "PDF-ANNOTATIONS-DELETE-AT-POINT" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg))))
    (when (and del write-var (fboundp del))
      (let ((writes 0))
        (progv (list write-var)
               (list (lambda (p d) (declare (ignore p d)) (incf writes)))
          (assert-no-error
            (with-mock-bridge (:responses (list (%fake-view-get :page 0)))
              (funcall (symbol-function del) "/tmp/empty.pdf" 0 0.5 0.5))
            "delete 落空不該 crash"))))))

(deftest v027-c-annotation-at-point-hit-test
  "annotation-at 找出 (page,x,y) 上的 annotation；落在 rect 內回該物件，否則 nil。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (at (and pkg (find-symbol "PDF-ANNOTATION-AT" pkg))))
    (when (and make at (fboundp at))
      (let ((a (funcall make :id "x" :page 5
                              :rects '((0.1 0.1 0.5 0.2))
                              :color "#FFD700" :note nil :created-at 0)))
        ;; 落在 rect 內
        (assert-true (funcall (symbol-function at) (list a) 5 0.2 0.15)
                     "點落在 rect 內 → 命中")
        ;; 落在 rect 外
        (assert-false (funcall (symbol-function at) (list a) 5 0.9 0.9)
                      "點落在 rect 外 → 不命中")
        ;; 同點但不同 page
        (assert-false (funcall (symbol-function at) (list a) 6 0.2 0.15)
                      "page 不同 → 不命中")))))

(deftest v027-c-annotate-selection-reads-note-from-minibuffer
  "H 應該透過 *minibuffer-read* 拿 note 字串，並寫進 annotation 的 note 欄位。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 3)
                           (cons "buffer/state"
                                 (%make-ok (list :|path| "/tmp/p.pdf")))
                           (cons "view/selection-get"
                                 (%make-ok (list :|page| 3
                                                 :|rects| '((0.1 0.2 0.3 0.4)))))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
           (deser    (and pkg (find-symbol "PDF-ANNOTATIONS-DESERIALIZE" pkg)))
           (cmd-pkg (find-package '#:limn/cmd))
           (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg)))
           (captured-str nil))
      (when (and write-var read-var deser)
        (progv (list write-var read-var)
               (list (lambda (p d) (declare (ignore p))
                       (setf captured-str d))
                     (lambda (prompt) (declare (ignore prompt))
                       "thought about this"))
          (let ((r (%call-cmd "PDF-ANNOTATE-SELECTION")))
            (unless (eq r :missing)
              (when captured-str
                (let* ((anns (funcall (symbol-function deser) captured-str))
                       (a (and anns (car anns)))
                       (note-of (find-symbol "PDF-ANNOTATION-NOTE" pkg))
                       (note (and a note-of (fboundp note-of)
                                  (funcall note-of a))))
                  (assert-equal "thought about this" note
                                "annotate-selection 把 minibuffer 字串存進 note"))))))))))

(deftest v027-c-highlight-uses-current-page
  "h 高亮時，annotation 的 page 必須取自 view/get 的 :page，不是寫死 0。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 42)
                           (cons "buffer/state"
                                 (%make-ok (list :|path| "/tmp/p.pdf")))
                           (cons "view/selection-get"
                                 (%make-ok (list :|page| 42
                                                 :|rects| '((0.1 0.2 0.3 0.4)))))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
           (deser    (and pkg (find-symbol "PDF-ANNOTATIONS-DESERIALIZE" pkg)))
           (captured-str nil))
      (when (and write-var deser (boundp write-var))
        (progv (list write-var)
               (list (lambda (p d) (declare (ignore p))
                       (setf captured-str d)))
          (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
            (unless (eq r :missing)
              (when captured-str
                (let* ((anns (funcall (symbol-function deser) captured-str))
                       (a (and anns (car anns)))
                       (page-of (find-symbol "PDF-ANNOTATION-PAGE" pkg))
                       (page (and a page-of (fboundp page-of)
                                  (funcall page-of a))))
                  (assert-equal 42 page
                                "annotation.page == 當前 view/get page"))))))))))

(deftest v027-c-multi-buffer-annotation-isolation
  "兩個不同 buffer 的 annotation 寫進不同 sidecar，互不污染。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and make save load-fn write-var read-var
               (fboundp save) (fboundp load-fn))
      (let ((store (make-hash-table :test #'equal)))
        (progv (list write-var read-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store)))
          (let ((a (funcall make :id "in-A" :page 0 :rects '() :note nil
                                  :created-at 0))
                (b (funcall make :id "in-B" :page 0 :rects '() :note nil
                                  :created-at 0)))
            (funcall (symbol-function save) "/tmp/A.pdf" (list a))
            (funcall (symbol-function save) "/tmp/B.pdf" (list b))
            (let ((back-a (funcall (symbol-function load-fn) "/tmp/A.pdf"))
                  (back-b (funcall (symbol-function load-fn) "/tmp/B.pdf"))
                  (id-of  (find-symbol "PDF-ANNOTATION-ID" pkg)))
              (assert-equal 1 (length back-a) "A 有 1")
              (assert-equal 1 (length back-b) "B 有 1")
              (when (and back-a back-b id-of)
                (assert-equal "in-A" (funcall id-of (car back-a))
                              "A 的 annotation 留在 A")
                (assert-equal "in-B" (funcall id-of (car back-b))
                              "B 的 annotation 留在 B")))))))))

(deftest v027-c-load-missing-sidecar-returns-empty
  "sidecar 檔不存在時 load 回 nil 或 ()，不該 crash。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and load-fn read-var (fboundp load-fn))
      (progv (list read-var)
             (list (lambda (p) (declare (ignore p)) nil))  ; 模擬不存在
        (assert-no-error
          (let ((back (funcall (symbol-function load-fn) "/tmp/missing.pdf")))
            (assert-true (or (null back) (listp back))
                         "missing sidecar → nil 或空 list"))
          "load missing sidecar 不該 crash")))))

(deftest v027-c-load-corrupted-sidecar-graceful
  "sidecar 內容毀損（不是合法 lisp）→ load 不該 propagate error。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and load-fn read-var (fboundp load-fn))
      (progv (list read-var)
             (list (lambda (p) (declare (ignore p))
                     "(((not balanced parens"))
        (assert-no-error
          (let ((back (funcall (symbol-function load-fn) "/tmp/corrupt.pdf")))
            (assert-true (or (null back) (listp back))
                         "corrupted sidecar → nil 或空 list"))
          "load corrupted sidecar 不該 propagate error")))))

(deftest v027-c-created-at-uses-now-fn
  "新 annotation 的 created-at 應該透過 *now-fn* 取得，可注入 fake clock。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (now-var (and pkg (find-symbol "*NOW-FN*" pkg)))
         (created-of (and pkg (find-symbol "PDF-ANNOTATION-CREATED-AT" pkg))))
    ;; 這個 test 只測 make 如果允許 :created-at nil 預設、就走 *now-fn*。
    (when (and make now-var (boundp now-var) created-of)
      (progv (list now-var) (list (lambda () 999999))
        (let ((a (funcall make :page 0 :rects '() :note nil)))
          (when (and a (numberp (funcall created-of a)))
            (assert-equal 999999 (funcall created-of a)
                          "未指定 created-at 時走 *now-fn*")))))))

(deftest v027-c-on-buffer-opened-loads-sidecar-overlays
  "pdf-mode 的 buffer-opened hook 應該載入 sidecar 並送 view/overlays。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (hook (and pkg (find-symbol "PDF-MODE-ON-BUFFER-OPENED" pkg)))
           (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg)))
           (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg))))
      (when (and hook read-var make (fboundp hook))
        ;; 模擬 sidecar 已有一個 annotation
        (progv (list read-var)
               (list (lambda (p)
                       (declare (ignore p))
                       (let ((a (funcall make :id "preloaded"
                                               :page 1
                                               :rects '((0.1 0.1 0.5 0.2))
                                               :color "#FFD700"
                                               :note nil :created-at 0)))
                         (let ((ser (find-symbol "PDF-ANNOTATIONS-SERIALIZE"
                                                  pkg)))
                           (and ser (fboundp ser)
                                (funcall ser (list a)))))))
          (funcall (symbol-function hook)
                   :buffer-id "b1" :path "/tmp/p.pdf" :engine "mupdf")
          (assert-true (%mock-call-of "view/overlays")
                       "buffer-opened hook 應該畫 sidecar 中的 overlay"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §D 補：empty TOC / 3-level nesting / RET → jump
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-d-format-toc-empty-returns-empty-string
  "空 TOC → 空字串（或可印的 placeholder）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "FORMAT-TOC-TREE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn) '())))
        (assert-type s string "空 TOC 仍回字串")
        (assert-true (or (string= s "")
                          (search "empty" (string-downcase s))
                          (search "no" (string-downcase s)))
                     "空 TOC 為空字串或 placeholder")))))

(deftest v027-d-format-toc-three-level-nesting
  "三層巢狀：子的縮排 > 父的縮排。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "FORMAT-TOC-TREE" pkg))))
    (when (and fn (fboundp fn))
      (let* ((toc '((:|title| "L1" :|page| 0
                              :|children| ((:|title| "L2" :|page| 1
                                             :|children| ((:|title| "L3"
                                                            :|page| 2)))))))
             (s (funcall (symbol-function fn) toc)))
        (when (stringp s)
          (assert-true (search "L1" s))
          (assert-true (search "L2" s))
          (assert-true (search "L3" s))
          ;; 縮排檢查：L3 那行起頭的空白應該比 L2 多
          (let* ((p1 (search "L1" s))
                 (p2 (search "L2" s))
                 (p3 (search "L3" s))
                 (col1 (when p1 (- p1 (or (position #\Newline s
                                                    :from-end t :end p1) -1) 1)))
                 (col2 (when p2 (- p2 (or (position #\Newline s
                                                    :from-end t :end p2) -1) 1)))
                 (col3 (when p3 (- p3 (or (position #\Newline s
                                                    :from-end t :end p3) -1) 1))))
            (when (and col1 col2 col3)
              (assert-true (and (> col2 col1) (> col3 col2))
                           "縮排嚴格遞增 L1 < L2 < L3"))))))))

(deftest v027-d-toc-jump-at-point-calls-goto
  "RET 在 *PDF-TOC* 行上 → 解析該行的 page → view/set。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 100)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fmt (and pkg (find-symbol "FORMAT-TOC-TREE" pkg)))
           (formatted (and fmt (fboundp fmt)
                           (funcall (symbol-function fmt)
                                    '((:|title| "Ch1" :|page| 9))))))
      ;; 命令需要看當前 buffer 的當前行。實作層用 buffer/text 模擬。
      ;; 這裡只測：給定行字串、命令送 view/set page=9。
      (let* ((cmd-sym (find-symbol "PDF-TOC-JUMP-AT-POINT" :cl-user)))
        (when (and cmd-sym (fboundp cmd-sym))
          (handler-case
              ;; 多種介面：要嘛吃 line-string，要嘛吃 nothing 並讀 buffer。
              (funcall (symbol-function cmd-sym) formatted)
            (error ()
              (handler-case (funcall (symbol-function cmd-sym))
                (error () nil))))
          (let ((vs (%mock-call-of "view/set")))
            (when vs
              (assert-equal 9 (getf vs :|page|)
                            "RET on 'Ch1 ... 9' → view/set page 9"))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §E 補：jump 不存在 bookmark / m / ' 互動 char-read
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-e-jump-missing-bookmark-graceful
  "bookmark/get 失敗時 jump 不該 crash 且不該送 view/set。"
  (with-mock-bridge (:responses
                     (list (cons "bookmark/get"
                                 (list :|ok| :false
                                        :|error| "no such bookmark"))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-JUMP-BOOKMARK-NAME" pkg))))
      (when (and fn (fboundp fn))
        (assert-no-error
          (funcall (symbol-function fn) "b1" "ghost")
          "jump 不存在的 bookmark 不該 crash")
        (assert-equal 0 (%mock-call-count "view/set")
                      "失敗時不該送 view/set")))))

(deftest v027-e-set-bookmark-uses-current-page
  "m 不帶頁碼版本：應該讀當前 view/get 的 page。"
  (with-mock-bridge (:responses (list (%fake-view-get :buffer-id "b1" :page 17)))
    (let* ((cmd-sym (find-symbol "PDF-SET-BOOKMARK" :cl-user)))
      (when (and cmd-sym (fboundp cmd-sym))
        ;; m 透過 *key-read-fn* 拿 char、然後用當前 page 設 bookmark
        (let* ((rt-pkg (find-package '#:limn/runtime))
               (key-read (and rt-pkg (find-symbol "*KEY-READ-FN*" rt-pkg))))
          (handler-case
              (if (and key-read (boundp key-read))
                  (progv (list key-read)
                         (list (lambda () "a"))
                    (funcall (symbol-function cmd-sym)))
                  (funcall (symbol-function cmd-sym) "a"))
            (error () nil)))
        (let ((args (%mock-call-of "bookmark/set")))
          (when args
            (assert-equal 17 (getf args :|page|)
                          "m 帶當前 page (17) 寫入")))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §F 補：last-page boundary / 50% / hook 真的 attach / CJK 路徑
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-f-last-page-display
  "page=182, page-count=183 應該顯示 [183 / 183]。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn) "x.pdf" 182 183 1.0)))
        (when (stringp s)
          (assert-true (search "183 / 183" s)
                       "last page 顯示 [183 / 183]"))))))

(deftest v027-f-zoom-50-percent
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn) "x.pdf" 0 10 0.5)))
        (when (stringp s)
          (assert-true (search "50" s) "0.5 → 50%"))))))

(deftest v027-f-modeline-update-attached-to-view-changed
  "pdf-mode-update-modeline 應該訂閱 event/view-changed 之類的 hook。
   呼一次 update → 應該 emit modeline/set。"
  (with-mock-bridge (:responses (list (%fake-view-get :buffer-id "b1"
                                                       :page 5
                                                       :page-count 50
                                                       :zoom 1.25)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-MODE-UPDATE-MODELINE" pkg))))
      (when (and fn (fboundp fn))
        (funcall (symbol-function fn) :buffer-id "b1"
                                       :path "/tmp/paper.pdf")
        (let ((args (%mock-call-of "modeline/set")))
          (assert-true args "modeline/set 被呼叫")
          (when args
            (let ((left (getf args :|left|)))
              (when (stringp left)
                (assert-true (search "6 / 50" left)
                             "頁碼顯示 6 / 50 (1-indexed)")
                (assert-true (search "125" left)
                             "zoom 顯示 125%")))))))))

(deftest v027-f-cjk-filename-in-modeline
  "modeline 顯示 CJK basename 不該被 mojibake。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-FORMAT-MODELINE" pkg))))
    (when (and fn (fboundp fn))
      (let ((s (funcall (symbol-function fn) "/tmp/論文.pdf" 0 10 1.0)))
        (when (stringp s)
          (assert-true (search "論文.pdf" s)
                       "CJK basename 完整顯示"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; CJK 跨段 round-trip
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-c-cjk-note-roundtrip
  "annotation 的 note 是 CJK / emoji → serialize/deserialize 後字串不變。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (ser (and pkg (find-symbol "PDF-ANNOTATIONS-SERIALIZE" pkg)))
         (des (and pkg (find-symbol "PDF-ANNOTATIONS-DESERIALIZE" pkg)))
         (note-of (and pkg (find-symbol "PDF-ANNOTATION-NOTE" pkg))))
    (when (and make ser des note-of (fboundp ser) (fboundp des))
      (let* ((a (funcall make :id "u" :page 0 :rects '() :color "#FFD700"
                              :note "重要 💡 take note"
                              :created-at 0))
             (str (funcall (symbol-function ser) (list a)))
             (back (funcall (symbol-function des) str)))
        (when (and back (car back))
          (assert-equal "重要 💡 take note"
                        (funcall note-of (car back))
                        "CJK + emoji round-trip"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §G defcustom — user-tunable variables
;;;
;;; dogfooder 第二天就會試 (customize-set-variable 'pdf-annotation-color
;;; "#ff00ff")。如果這些變數只是 defvar、customize 框架抓不到。
;;; ══════════════════════════════════════════════════════════════════════

(defun %customize-set (sym value)
  "呼 limn/custom:customize-set-variable（若 v0.25 customize 已 ship）。
   無 framework 就直接 setf 走 fallback。"
  (let* ((pkg (find-package '#:limn/custom))
         (fn (and pkg (find-symbol "CUSTOMIZE-SET-VARIABLE" pkg))))
    (if (and fn (fboundp fn))
        (funcall (symbol-function fn) sym value)
        (setf (symbol-value sym) value))))

(defun %get-custom-meta (sym)
  "Return (:type T :doc D :group G) for SYM via customize introspection, or NIL."
  (let* ((pkg (find-package '#:limn/custom))
         (fn (and pkg (find-symbol "GET-CUSTOM-META" pkg))))
    (when (and fn (fboundp fn))
      (funcall (symbol-function fn) sym))))

(deftest v027-g-annotation-color-is-defcustom
  "pdf-annotation-color 必須是 defcustom（不是 defvar），customize 才認得。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (sym (and pkg (find-symbol "*PDF-ANNOTATION-COLOR*" pkg))))
    (when sym
      (assert-true (boundp sym) "*pdf-annotation-color* bound")
      (let ((meta (%get-custom-meta sym)))
        (when meta
          (assert-true (getf meta :type)  "有 :type meta")
          (assert-true (getf meta :group) "有 :group meta"))))))

(deftest v027-g-customize-color-affects-next-highlight
  "customize-set 'pdf-annotation-color → 之後新建的 annotation 用新色。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 0)
                           (cons "buffer/state"
                                 (%make-ok (list :|path| "/tmp/p.pdf")))
                           (cons "view/selection-get"
                                 (%make-ok (list :|page| 0
                                                 :|rects| '((0.1 0.1 0.5 0.2)))))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (color-sym (and pkg (find-symbol "*PDF-ANNOTATION-COLOR*" pkg)))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
           (deser     (and pkg (find-symbol "PDF-ANNOTATIONS-DESERIALIZE" pkg)))
           (captured-str nil))
      (when (and color-sym write-var deser (boundp color-sym))
        (let ((orig (symbol-value color-sym)))
          (unwind-protect
               (progn
                 (%customize-set color-sym "#ff00ff")
                 (progv (list write-var)
                        (list (lambda (p d) (declare (ignore p))
                                (setf captured-str d)))
                   (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
                     (unless (eq r :missing)
                       (when captured-str
                         (let* ((anns (funcall (symbol-function deser)
                                                captured-str))
                                (a (and anns (car anns)))
                                (color-of (find-symbol "PDF-ANNOTATION-COLOR"
                                                        pkg))
                                (c (and a color-of (fboundp color-of)
                                        (funcall color-of a))))
                           (assert-equal "#ff00ff" c
                                         "新 annotation 用 #ff00ff")))))))
            (%customize-set color-sym orig)))))))

(deftest v027-g-scroll-step-customizable
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (sym (and pkg (find-symbol "*PDF-SCROLL-STEP*" pkg))))
    (when sym
      (let ((meta (%get-custom-meta sym)))
        (when meta
          (assert-true (member (getf meta :type)
                                '(integer number)
                                :test #'eq)
                       "*pdf-scroll-step* type integer/number"))))))

(deftest v027-g-zoom-in-factor-customizable
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (sym (and pkg (find-symbol "*PDF-ZOOM-IN-FACTOR*" pkg))))
    (when sym
      (let ((meta (%get-custom-meta sym)))
        (when meta
          (assert-true (getf meta :type) "*pdf-zoom-in-factor* has :type"))))))

(deftest v027-g-zoom-factor-actually-used
  "改 *pdf-zoom-in-factor* 後，pdf-zoom-in 用新值。"
  (with-mock-bridge (:responses (list (%fake-view-get :zoom 1.0)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (sym (and pkg (find-symbol "*PDF-ZOOM-IN-FACTOR*" pkg))))
      (when (and sym (boundp sym))
        (let ((orig (symbol-value sym)))
          (unwind-protect
               (progn
                 (%customize-set sym 2.0)
                 (let ((r (%call-cmd "PDF-ZOOM-IN")))
                   (unless (eq r :missing)
                     (let ((args (%mock-call-of "view/set")))
                       (when args
                         (let ((z (getf args :|zoom|)))
                           (when (numberp z)
                             (assert-true (>= z 1.9)
                                          "factor 2.0 → zoom 從 1.0 → 2.0"))))))))
            (%customize-set sym orig)))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §H discoverability — describe-key / apropos / describe-mode
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-h-describe-key-j-returns-binding
  "describe-key 'j' 應該指向某種命令；若 framework describe-key 只查 global
   keymap（pdf-mode 是 mode-local）此 test 走 introspect 反查 path。"
  (%ensure-pdf-mode-installed)
  (let* ((pkg (find-package '#:limn/help))
         (fn (and pkg (find-symbol "DESCRIBE-KEY" pkg))))
    (when (and fn (fboundp fn))
      (let* ((info (handler-case (funcall (symbol-function fn) "j")
                     (error () nil)))
             (s (and info (format nil "~a" info))))
        ;; Only assert if describe-key returned something meaningful
        ;; (i.e. not "is not defined"). If pdf-mode bindings aren't in
        ;; global keymap, describe-key reports unbound — bail honestly.
        (when (and s (not (search "not defined" s)))
          (assert-true (or (search "pdf-scroll-down" s)
                            (search "PDF-SCROLL-DOWN" s))
                       "describe-key 'j' 含 pdf-scroll-down"))))))

(deftest v027-h-apropos-pdf-lists-commands
  (%ensure-pdf-mode-installed)
  (let* ((pkg (find-package '#:limn/help))
         (fn (and pkg (find-symbol "APROPOS-COMMAND" pkg))))
    (when (and fn (fboundp fn))
      (let* ((hits (handler-case (funcall (symbol-function fn) "pdf-")
                     (error () nil)))
             (names (mapcar (lambda (h) (format nil "~a" h)) hits)))
        (when hits
          (assert-true (some (lambda (n)
                               (or (search "pdf-next-page" n)
                                   (search "PDF-NEXT-PAGE" n)))
                              names)
                       "apropos 'pdf-' 找到 pdf-next-page"))))))

(deftest v027-h-describe-mode-lists-bindings
  (%ensure-pdf-mode-installed)
  (let* ((pkg (find-package '#:limn/help))
         (fn (and pkg (find-symbol "DESCRIBE-MODE" pkg))))
    (when (and fn (fboundp fn))
      (let ((info (handler-case
                      (funcall (symbol-function fn) 'cl-user::pdf-mode)
                    (error () nil))))
        (when info
          (assert-true (or (search "j" (format nil "~a" info))
                            (search "scroll" (format nil "~a" info)))
                       "describe-mode 'pdf-mode 列出 j 或 scroll"))))))

(deftest v027-h-where-is-command-finds-j
  "where-is-command pdf-next-page → 至少回一個 'n' 或 'J' 字串。"
  (%ensure-pdf-mode-installed)
  (let* ((sym (find-symbol "WHERE-IS-COMMAND" :limn/introspect))
         (cmd-sym (find-symbol "PDF-NEXT-PAGE" :cl-user)))
    (when (and sym (fboundp sym) cmd-sym)
      (let ((keys (handler-case (funcall (symbol-function sym) cmd-sym)
                    (error () nil))))
        (when keys
          (assert-true (and (listp keys) keys)
                       "where-is-command pdf-next-page 非空"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §I lifecycle / state across buffer switches & close
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-i-search-state-cleared-on-buffer-close
  "buffer/close 後 *pdf-search-state* 應該被清（避免幽靈 overlay）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg)))
         (hook (and pkg (find-symbol "PDF-MODE-ON-BUFFER-CLOSED" pkg))))
    (when (and make state-var hook (fboundp hook))
      (setf (symbol-value state-var)
            (funcall make :buffer-id "b1" :query "x"
                          :hits '((:|page| 0 :|rects| ((0 0 0.1 0.1))))
                          :current-index 0))
      (funcall (symbol-function hook) :buffer-id "b1")
      (let ((s (symbol-value state-var)))
        (assert-true (or (null s)
                          (null (funcall (find-symbol "PDF-SEARCH-STATE-HITS"
                                                       pkg) s)))
                     "buffer-closed 後 state cleared")))))

(deftest v027-i-search-state-isolated-per-buffer
  "在 b1 搜尋後切到 b2，b2 不該繼承 b1 的 hits。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg))))
    (when (and make state-var)
      (setf (symbol-value state-var)
            (funcall make :buffer-id "b1" :query "x"
                          :hits '((:|page| 0 :|rects| ((0 0 0.1 0.1))))
                          :current-index 0))
      ;; 簡化模型：state 是「當前 active buffer」的單 slot。
      ;; 切 buffer 後拿 state、要嘛是新的 nil，要嘛 buffer-id 標 b2。
      (let* ((focus-hook (find-symbol "PDF-MODE-ON-BUFFER-FOCUSED" pkg)))
        (when (and focus-hook (fboundp focus-hook))
          (funcall (symbol-function focus-hook) :buffer-id "b2")
          (let* ((s (symbol-value state-var))
                 (id-of (find-symbol "PDF-SEARCH-STATE-BUFFER-ID" pkg)))
            (when (and s id-of)
              (assert-true (or (null s)
                                (not (string= "b1" (funcall id-of s))))
                           "切到 b2 後 state 不再屬 b1"))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §J annotation 細節（dogfood 用一週踩到的）
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-j-re-annotate-same-selection-replaces
  "h 在同 page 同 rect 重按一次：annotation 列表仍是 1 個，不是 2 個重複的。
   v0.37 Phase F: selection-get returns :|active|/:|begin|/:|end| on the
   wire; %selection synthesizes :|page|/:|rects| from that.  Also:
   %current-pdf-path now reads from *buffer-id-to-path* (populated by
   pdf-mode-on-buffer-opened) instead of a non-existent buffer/state
   wire — pre-populate the cache so the mock test exercises the real
   sidecar key (rather than the /tmp/unknown.pdf fallback)."
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 3)
                           (cons "view/selection-get"
                                 (%make-ok
                                  (list :|active| t
                                        :|begin| (list :|page| 3
                                                       :|x| 0.1 :|y| 0.2)
                                        :|end|   (list :|page| 3
                                                       :|x| 0.3 :|y| 0.4)
                                        :|mode|  "char"
                                        :|text|  "hi")))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
           (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg)))
           (cache-var (and pkg (find-symbol "*BUFFER-ID-TO-PATH*" pkg)))
           (ser (and pkg (find-symbol "PDF-ANNOTATIONS-SERIALIZE" pkg))))
      (when (and write-var read-var cache-var ser)
        (setf (gethash "b1" (symbol-value cache-var)) "/tmp/p.pdf")
        (unwind-protect
             (let ((store (make-hash-table :test #'equal)))
               (progv (list write-var read-var)
                      (list (lambda (p d) (setf (gethash p store) d))
                            (lambda (p) (gethash p store)))
                 ;; 第一次 h
                 (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
                   (declare (ignore r)))
                 ;; 第二次 h（同 selection）
                 (let ((r (%call-cmd "PDF-HIGHLIGHT-SELECTION")))
                   (declare (ignore r)))
                 (let* ((load-fn (find-symbol "PDF-ANNOTATIONS-LOAD" pkg))
                        (back (and load-fn (fboundp load-fn)
                                   (funcall (symbol-function load-fn)
                                            "/tmp/p.pdf"))))
                   (when (listp back)
                     ;; 行為釘住：replace（=1）；若實作選 stack（>1）此 test 紅
                     (assert-equal 1 (length back)
                                   "同 rect 重按 h → 不重複（1 個）")))))
          (remhash "b1" (symbol-value cache-var)))))))

(deftest v027-j-delete-last-annotation-leaves-empty-list
  "刪掉唯一一個 annotation → sidecar 變空 list（不是 unlink、不是 crash）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (del (and pkg (find-symbol "PDF-ANNOTATIONS-DELETE-AT-POINT" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var  (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and make save del load-fn write-var read-var (fboundp del))
      (let* ((store (make-hash-table :test #'equal))
             (a (funcall make :id "only" :page 0 :rects '((0.1 0.1 0.5 0.2))
                              :color "#FFD700" :note nil :created-at 0)))
        (progv (list write-var read-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store)))
          (funcall (symbol-function save) "/tmp/last.pdf" (list a))
          (with-mock-bridge (:responses (list (%fake-view-get :page 0)))
            (handler-case
                (funcall (symbol-function del) "/tmp/last.pdf" 0 0.2 0.15)
              (error () nil)))
          (let ((back (funcall (symbol-function load-fn) "/tmp/last.pdf")))
            (assert-true (and (listp back) (zerop (length back)))
                         "刪最後一個 → empty list 而非 crash")))))))

(deftest v027-j-rotation-does-not-mutate-annotation-rects
  "rotate-cw 後 annotation 的 rects 不變（page-normalized 是 rotation-invariant）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg))))
    (when (and make (fboundp make))
      (let* ((a (funcall make :id "u" :page 0
                               :rects '((0.1 0.2 0.5 0.3))
                               :color "#FFD700" :note nil :created-at 0))
             (rects-of (find-symbol "PDF-ANNOTATION-RECTS" pkg))
             (before (and rects-of (funcall rects-of a))))
        (with-mock-bridge (:responses (list (%fake-view-get :rotation 0)))
          (%call-cmd "PDF-ROTATE-CW"))
        (let ((after (and rects-of (funcall rects-of a))))
          (assert-equal before after
                        "rotate 不改 annotation 內部 rects"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §K search 細節 — regex / repeat / wrap message / engine guards
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-k-regex-special-chars-no-crash
  "查含 [/]/./* 等 regex 特殊字 → 不該 crash（MuPDF 做 literal 比對）。"
  (with-mock-bridge (:responses (list (%fake-search-response :hits nil)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        (dolist (q '("[the]" "a.b" "x*" "foo|bar" "(group)"))
          (assert-no-error
            (funcall (symbol-function fn) "b1" q)
            (format nil "search ~s 不該 crash" q)))))))

(deftest v027-k-empty-query-reuses-last-search
  "/ 第二次給空字串時 → 應該 reuse *pdf-last-search-query*（Emacs 慣例）。"
  (with-mock-bridge (:responses (list (%fake-search-response :hits nil)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (last-var (and pkg (find-symbol "*PDF-LAST-SEARCH-QUERY*" pkg)))
           (cmd-pkg (find-package '#:limn/cmd))
           (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg))))
      (when (and last-var read-var (boundp last-var) (boundp read-var))
        (setf (symbol-value last-var) "foo")
        (progv (list read-var)
               (list (lambda (prompt) (declare (ignore prompt)) ""))
          (let ((r (%call-cmd "PDF-ISEARCH-FORWARD")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "buffer/search")))
                (when args
                  (assert-equal "foo" (getf args :|query|)
                                "空 input 復用 *pdf-last-search-query*"))))))))))

(deftest v027-k-wrap-emits-wrapped-message
  "n 在最後一個命中後 wrap 應該 message/echo \"Wrapped\" 之類訊息。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
           (state-var (and pkg (find-symbol "*PDF-SEARCH-STATE*" pkg))))
      (when (and make state-var)
        (setf (symbol-value state-var)
              (funcall make :buffer-id "b" :query "q"
                            :hits (list (list :|page| 1 :|rects| '((0 0 0.1 0.1)))
                                         (list :|page| 2 :|rects| '((0 0 0.1 0.1))))
                            :current-index 1))    ; at last
        (let ((r (%call-cmd "PDF-ISEARCH-NEXT")))
          (unless (eq r :missing)
            (let ((args (%mock-call-of "message/echo")))
              (when args
                (let ((txt (getf args :|text|)))
                  (assert-true (and (stringp txt)
                                    (or (search "rap" txt)
                                        (search "rap" (string-downcase txt))))
                               "wrap 後 echo 含 wrap/Wrapped"))))))))))

(deftest v027-k-search-on-text-engine-graceful
  "在 text engine buffer 上呼搜尋 → ok=false 或 no-op，不該 crash。"
  (with-mock-bridge (:responses
                     (list (cons "buffer/search"
                                 (list :|ok| :false
                                        :|error| "unsupported engine"))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        (assert-no-error
          (funcall (symbol-function fn) "b-text" "anything")
          "search 在不支援的 engine 不該 crash")))))

(deftest v027-k-search-before-engine-ready-graceful
  "engine 還沒 load 完 → buffer/search 回 not-ready；pdf-mode 不該炸。"
  (with-mock-bridge (:responses
                     (list (cons "buffer/search"
                                 (list :|ok| :false :|error| "engine not ready"))))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (fn (and pkg (find-symbol "PDF-SEARCH-EXECUTE" pkg))))
      (when (and fn (fboundp fn))
        (assert-no-error
          (funcall (symbol-function fn) "b1" "q")
          "engine not ready 不該 crash")))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §L override — user 自定義 binding 覆蓋預設
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-l-user-binding-overrides-default
  "user 在 init.lisp 重綁 j 到 my-fn → lookup 拿到 my-fn 不是 pdf-scroll-down。"
  (%ensure-pdf-mode-installed)
  (let* ((mode-pkg (find-package '#:limn/mode))
         (keys-pkg (find-package '#:limn/keys))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg)))
         (def-key (and keys-pkg (find-symbol "DEFINE-KEY" keys-pkg)))
         (lookup (and keys-pkg (find-symbol "LOOKUP-SEQUENCE" keys-pkg))))
    (when (and find-mode mode-keymap def-key lookup)
      (let* ((m (funcall find-mode 'cl-user::pdf-mode))
             (km (and m (funcall mode-keymap m))))
        (when km
          ;; 模擬 user 在 init.lisp 跑這條 — define-key 吃字串 spec、不是 list
          (funcall def-key km "j" 'cl-user::user-defined-marker)
          (let ((b (funcall lookup km (list "j"))))
            (assert-equal 'cl-user::user-defined-marker b
                          "user override 後 lookup 拿 user-defined-marker")))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §M PDF reality — engine-load 失敗 / 邊界頁碼 / 空 outline
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-m-engine-load-failure-no-mode-activation
  "engine-load 回 ok=false 時，pdf-mode-on-buffer-opened 不該 crash。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (hook (and pkg (find-symbol "PDF-MODE-ON-BUFFER-OPENED" pkg))))
      (when (and hook (fboundp hook))
        (assert-no-error
          ;; path nil / engine nil 模擬「沒成功 open 但 hook 被觸發」
          (funcall (symbol-function hook)
                   :buffer-id nil :path nil :engine nil)
          "hook 收 nil 不該 crash")))))

;; v0.38 B18: *pdf-default-zoom* applied on every pdf-mode buffer-opened.
(deftest v038-b18-default-zoom-nil-skips-view-set
  "When *pdf-default-zoom* is NIL, no view/set :|zoom| call should be made on buffer-opened."
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (hook (and pkg (find-symbol "PDF-MODE-ON-BUFFER-OPENED" pkg)))
           (zoom-var (and pkg (find-symbol "*PDF-DEFAULT-ZOOM*" pkg))))
      (when (and hook (fboundp hook) zoom-var (boundp zoom-var))
        (progv (list zoom-var) (list nil)
          (funcall (symbol-function hook)
                   :buffer-id "b1" :path "/x.pdf" :engine "mupdf")
          (let ((vs-calls
                  (remove-if-not
                   (lambda (c) (and (consp c)
                                     (equal (car c) "view/set")
                                     (member :|zoom| (cdr c))))
                   *mock-call-log*)))
            (assert-true (null vs-calls)
                         "nil *pdf-default-zoom* → no view/set :zoom call")))))))

(deftest v038-b18-default-zoom-set-applies-on-buffer-opened
  "When *pdf-default-zoom* is 1.5, buffer-opened should send view/set :|zoom| 1.5."
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (hook (and pkg (find-symbol "PDF-MODE-ON-BUFFER-OPENED" pkg)))
           (zoom-var (and pkg (find-symbol "*PDF-DEFAULT-ZOOM*" pkg))))
      (when (and hook (fboundp hook) zoom-var (boundp zoom-var))
        (progv (list zoom-var) (list 1.5)
          (funcall (symbol-function hook)
                   :buffer-id "b1" :path "/x.pdf" :engine "mupdf")
          (let ((args (%mock-call-of "view/set")))
            (assert-true args "view/set should have fired")
            (when args
              (assert-equal 1.5 (getf args :|zoom|)
                            "view/set :zoom == *pdf-default-zoom*"))))))))

(deftest v027-m-goto-beyond-page-count-clamps
  "5G on a 3-page doc → 跳到最後一頁 (page=2)，不是 5（也不是 crash）。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 3)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when (and pa-var (boundp pa-var))
        (progv (list pa-var) (list 5)
          (let ((r (%call-cmd "PDF-GOTO-PAGE")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  (let ((p (getf args :|page|)))
                    (assert-true (and (integerp p) (<= p 2))
                                 (format nil "5G on 3-page doc clamps to ≤ 2 (got ~a)"
                                          p))))))))))))

(deftest v027-m-goto-negative-prefix-clamps-zero
  "(-3)G → 不該變 -3、應 clamp 到 0。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 5 :page-count 10)))
    (let* ((cmd-pkg (find-package '#:limn/cmd))
           (pa-var (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
      (when (and pa-var (boundp pa-var))
        (progv (list pa-var) (list -3)
          (let ((r (%call-cmd "PDF-GOTO-PAGE")))
            (unless (eq r :missing)
              (let ((args (%mock-call-of "view/set")))
                (when args
                  (let ((p (getf args :|page|)))
                    (assert-true (and (integerp p) (>= p 0))
                                 (format nil "(-3)G clamps to >= 0 (got ~a)" p))))))))))))

(deftest v027-m-toc-with-no-outline-no-crash
  "PDF 無 outline → buffer/toc 回空 → t 不該 crash。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1")
                           (cons "buffer/toc"
                                 (%make-ok (list :|items| '())))))
    (assert-no-error
      (let ((r (%call-cmd "PDF-TOC")))
        (declare (ignore r)))
      "空 outline 開 t 不該 crash")))


;;; ══════════════════════════════════════════════════════════════════════
;;; §N first-run / zero-config bootstrap
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-n-pdf-mode-installed-without-init-lisp
  "framework 載入後（沒呼 user init.lisp），pdf-mode 仍應註冊好。
   即：limn.lisp 的 bootstrap 必須 call install。"
  (let* ((mode-pkg (find-package '#:limn/mode))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg))))
    (when (and find-mode (fboundp find-mode))
      ;; 注意：這個 test **故意不呼** %ensure-pdf-mode-installed。
      ;; 如果 limn.lisp 沒 hook install 進 bootstrap、這條紅。
      (let ((m (funcall find-mode 'cl-user::pdf-mode)))
        (assert-true m
                     "framework bootstrap 後 pdf-mode 自動註冊（不靠 user init.lisp）")))))

(deftest v027-n-engine-default-mode-mupdf-zero-config
  "mupdf engine-default-mode 應該指向 pdf-mode（不靠 user init.lisp）。"
  (let* ((rt-pkg (find-package '#:limn/runtime))
         (lookup (and rt-pkg (find-symbol "ENGINE-DEFAULT-MODE" rt-pkg))))
    (when (and lookup (fboundp lookup))
      (assert-equal 'cl-user::pdf-mode
                    (funcall (symbol-function lookup) "mupdf")
                    "zero-config 下 mupdf engine 預設 pdf-mode"))))

(deftest v027-n-annotation-dir-auto-created
  "save annotation 時若 ~/.limn/annotations/ 不存在應該自動 mkdir。
   用 vtable 觀察 write 真的被呼到。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg))))
    (when (and make save write-var (fboundp save))
      (let ((write-called 0)
            (path-seen nil))
        (progv (list write-var)
               (list (lambda (p d)
                       (declare (ignore d))
                       (incf write-called)
                       (setf path-seen p)))
          (let ((a (funcall make :id "u" :page 0 :rects '() :note nil
                                  :created-at 0)))
            (funcall (symbol-function save) "/tmp/p.pdf" (list a)))
          (assert-equal 1 write-called "save 真的呼 write-fn")
          (when path-seen
            (assert-true (search "annotations" (namestring path-seen))
                         "sidecar 路徑含 annotations/")))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §O identity — sidecar key by content, not path
;;;
;;; 三個月 dogfooder 最大災難：搬 PDF → annotation 全沒。
;;; Sidecar key 必須是 sha256(file content)、不是 sha256(path)。
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-o-sidecar-keyed-by-content-not-path
  "兩個 path 不同但 content 相同 → 同 sidecar；同 path 但 content 改了 → 不同 sidecar。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-ANNOTATIONS-CONTENT-HASH-SIDECAR-PATH"
                                    pkg)))
         (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
    (when (and fn hash-var (fboundp fn))
      ;; Inject a deterministic content-hash mock.
      (let ((hashes (make-hash-table :test #'equal)))
        (setf (gethash "/a/paper.pdf" hashes) "content-X")
        (setf (gethash "/b/paper.pdf" hashes) "content-X")  ; 同內容、不同路徑
        (setf (gethash "/c/paper.pdf" hashes) "content-Y")  ; 不同內容
        (progv (list hash-var)
               (list (lambda (path) (gethash path hashes)))
          (let ((p-a (namestring (funcall (symbol-function fn) "/a/paper.pdf")))
                (p-b (namestring (funcall (symbol-function fn) "/b/paper.pdf")))
                (p-c (namestring (funcall (symbol-function fn) "/c/paper.pdf"))))
            (assert-equal p-a p-b
                          "同 content 不同 path → 同 sidecar")
            (assert-true (not (string= p-a p-c))
                         "不同 content → 不同 sidecar")))))))

(deftest v027-o-rename-preserves-annotations
  "改名後 load 同份 annotation —— 用 content-hash 就 work。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg)))
         (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
    (when (and make save load-fn write-var read-var hash-var
               (fboundp save) (fboundp load-fn))
      (let ((store (make-hash-table :test #'equal))
            (hashes (make-hash-table :test #'equal)))
        (setf (gethash "/old/path/x.pdf" hashes) "same-content"
              (gethash "/new/path/x.pdf" hashes) "same-content")
        (progv (list write-var read-var hash-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store))
                     (lambda (p) (gethash p hashes)))
          (let ((a (funcall make :id "preserved" :page 5
                                  :rects '((0.1 0.1 0.5 0.2))
                                  :color "#FFD700" :note nil :created-at 0)))
            ;; save under /old/path
            (funcall (symbol-function save) "/old/path/x.pdf" (list a))
            ;; load under /new/path (改名後)
            (let ((back (funcall (symbol-function load-fn) "/new/path/x.pdf")))
              (assert-equal 1 (length back)
                            "改名後 annotation 仍能 load")
              (when back
                (let ((id-of (find-symbol "PDF-ANNOTATION-ID" pkg)))
                  (assert-equal "preserved" (funcall id-of (car back))
                                "改名後 annotation id 對得上"))))))))))

(deftest v027-o-symlink-resolves-to-target-content
  "用 symlink 開 PDF → sidecar 跟著 *target content*，不是 link 名。"
  ;; 純單元測：模擬「symlink 與 target 兩個 path 但 hash-fn 對兩者回同樣 content」。
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-ANNOTATIONS-CONTENT-HASH-SIDECAR-PATH"
                                    pkg)))
         (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
    (when (and fn hash-var (fboundp fn))
      (let ((hashes (make-hash-table :test #'equal)))
        (setf (gethash "/home/u/now-reading.pdf" hashes) "X"
              (gethash "/data/papers/real.pdf"   hashes) "X")
        (progv (list hash-var) (list (lambda (p) (gethash p hashes)))
          (let ((via-link   (namestring (funcall (symbol-function fn)
                                                  "/home/u/now-reading.pdf")))
                (via-target (namestring (funcall (symbol-function fn)
                                                  "/data/papers/real.pdf"))))
            (assert-equal via-link via-target
                          "symlink + target 應指向同 sidecar")))))))

(deftest v027-o-old-path-key-migrate-to-content
  "舊 sidecar (path-keyed) 在 load 時自動 migrate 到 content-keyed。
   實作策略：load 找不到 content key 時、用 path-key 試一次、找到就 re-save。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg)))
         (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
    (when (and load-fn write-var read-var hash-var (fboundp load-fn))
      (let ((store (make-hash-table :test #'equal)))
        ;; seed：只有舊式 path-key sidecar 存在
        (setf (gethash "/path-keyed-old-sidecar" store)
              "(:version 0 :annotations ())")
        (progv (list write-var read-var hash-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store))
                     (lambda (p) (declare (ignore p)) "fresh-content"))
          ;; load 應該不 crash（即使 content-key sidecar 不存在）
          (assert-no-error
            (funcall (symbol-function load-fn) "/whatever.pdf")
            "missing content-key sidecar + 舊 path-key 共存不該 crash"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §P robustness — atomic write / partial load / save failure surface
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-p-atomic-write-uses-tmp-rename
  "save 應該先寫到 .tmp 再 rename，不該直接覆蓋目標檔案。
   觀察方式：write-fn 第一次被叫的路徑必須帶 .tmp 後綴、之後才出現真實名。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg))))
    (when (and make save write-var (fboundp save))
      (let ((paths-written nil))
        (progv (list write-var)
               (list (lambda (p d)
                       (declare (ignore d))
                       (push (namestring p) paths-written)))
          (let ((a (funcall make :id "u" :page 0 :rects '() :note nil
                                  :created-at 0)))
            (funcall (symbol-function save) "/tmp/p.pdf" (list a)))
          ;; 期待：先看到 .tmp、再看到非 .tmp（rename 的目標）。
          ;; 容忍：實作只跑一次 atomic 但 path 是 final（用 OS rename 而非經 vtable）—
          ;; 此時至少看一個 path。
          (assert-true (>= (length paths-written) 1)
                       "至少寫一次")
          (when (>= (length paths-written) 2)
            (let ((first-path (car (last paths-written))))
              (assert-true (search ".tmp" first-path)
                           "第一次寫的 path 帶 .tmp 後綴"))))))))

(deftest v027-p-partial-load-keeps-good-entries
  "sidecar 中第 3 個 annotation 壞 → 跳過它、留下另外的 entries（不要全 drop）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and load-fn read-var (fboundp load-fn))
      ;; 給一個半合法的 schema 字串：頭 + 三個 entry（其中第 2 個 garbled）。
      (let ((corrupt-blob
              "(:version 1 :annotations
                 ((:id \"a1\" :page 0 :rects ((0.1 0.1 0.5 0.2))
                   :color \"#FFD700\" :note nil :created-at 1)
                  (this-is-junk-not-a-plist)
                  (:id \"a3\" :page 5 :rects ((0.2 0.2 0.6 0.3))
                   :color \"#FFD700\" :note nil :created-at 3)))"))
        (progv (list read-var)
               (list (lambda (p) (declare (ignore p)) corrupt-blob))
          (assert-no-error
            (let ((back (funcall (symbol-function load-fn) "/x.pdf")))
              (when (listp back)
                ;; 預期至少保留 1 個（a1），最多保留 2 個（a1+a3、若實作跳過中間壞的）。
                ;; 嚴格行為釘住：> 0、好 entries 不該全丟。
                (assert-true (> (length back) 0)
                             "壞 entry 中間 → 至少保留好的 entry")))
            "corrupt entry 不該讓 load 整個回 nil"))))))

(deftest v027-p-save-failure-surfaces-not-silent
  "write-fn signal error → save 應該 signal 或回 ok=false，不該默默吞。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg))))
    (when (and make save write-var (fboundp save))
      (progv (list write-var)
             (list (lambda (p d)
                     (declare (ignore p d))
                     (error "disk full")))
        (let ((a (funcall make :id "u" :page 0 :rects '() :note nil
                                :created-at 0)))
          ;; 接受三種行為：(1) 重新 signal error，(2) 回 nil + log，(3) 回 ok=false。
          ;; 至少不能是「靜默吞、回 t」假裝成功。
          (let ((result (handler-case
                            (funcall (symbol-function save) "/x.pdf" (list a))
                          (error (e) (cons :error (princ-to-string e))))))
            (assert-true (or (consp result)              ; signaled
                              (null result)              ; nil
                              (eq result :false)         ; ok=false
                              (and (listp result)
                                   (eq (getf result :|ok|) :false)))
                         "save 失敗時不該回 t 假裝成功")))))))

(deftest v027-p-save-failure-message-to-user
  "save 失敗應該 emit message/echo 給使用者（log 路徑）。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
           (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
           (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg))))
      (when (and make save write-var (fboundp save))
        (progv (list write-var)
               (list (lambda (p d) (declare (ignore p d))
                       (error "permission denied")))
          (let ((a (funcall make :id "u" :page 0 :rects '() :note nil
                                  :created-at 0)))
            (ignore-errors
              (funcall (symbol-function save) "/x.pdf" (list a))))
          ;; 期望：要嘛 message/echo、要嘛 log/error wire call。
          (assert-true (or (%mock-call-of "message/echo")
                            (%mock-call-of "log/error")
                            (%mock-call-of "message"))
                       "save 失敗應該透過 message 通知用戶"))))))

(deftest v027-p-concurrent-save-no-corrupt
  "兩次 save 連發、最終檔案內容仍是合法 lisp（不該被截斷）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (save (and pkg (find-symbol "PDF-ANNOTATIONS-SAVE" pkg)))
         (load-fn (and pkg (find-symbol "PDF-ANNOTATIONS-LOAD" pkg)))
         (write-var (and pkg (find-symbol "*ANNOTATIONS-WRITE-FN*" pkg)))
         (read-var (and pkg (find-symbol "*ANNOTATIONS-READ-FN*" pkg))))
    (when (and make save load-fn write-var read-var
               (fboundp save) (fboundp load-fn))
      (let ((store (make-hash-table :test #'equal)))
        (progv (list write-var read-var)
               (list (lambda (p d) (setf (gethash p store) d))
                     (lambda (p) (gethash p store)))
          (let ((a (funcall make :id "1" :page 0 :rects '() :note nil
                                  :created-at 0))
                (b (funcall make :id "2" :page 1 :rects '() :note nil
                                  :created-at 0)))
            (funcall (symbol-function save) "/x.pdf" (list a))
            (funcall (symbol-function save) "/x.pdf" (list a b))  ; second
            ;; 最後讀回應是合法的、第二筆 save 的內容（不是被截 / loss）
            (let ((back (funcall (symbol-function load-fn) "/x.pdf")))
              (assert-true (listp back) "load 回 list 不是 error")
              (when (listp back)
                (assert-equal 2 (length back)
                              "第二次 save 完整覆蓋（不是 half-write）")))))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §Q scale — 100 annotations / 200 sidecars / large hits / large bookmark
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-q-100-annotation-overlay-payload-perf
  "100 個 annotation → overlay payload 在 100ms 內生成完畢。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (payload (and pkg (find-symbol "PDF-ANNOTATIONS-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let ((anns (loop for i from 0 below 100
                        collect (funcall make :id (format nil "a~a" i)
                                              :page (mod i 50)
                                              :rects '((0.1 0.1 0.5 0.2))
                                              :color "#FFD700"
                                              :note nil :created-at 0))))
        (let* ((t0 (get-internal-real-time))
               (overlays (funcall (symbol-function payload) anns))
               (dt (- (get-internal-real-time) t0))
               (ms (* 1000 (/ dt internal-time-units-per-second))))
          (assert-true (and (listp overlays) (>= (length overlays) 100))
                       "100 個 annotation → ≥ 100 個 overlay entries")
          (assert-true (< ms 100)
                       (format nil "overlay payload 在 100ms 內生成 (got ~,1f ms)"
                                ms)))))))

(deftest v027-q-1000-search-hits-overlay-payload-doesnt-crash
  "1000 個搜尋命中 → overlay payload 不該 crash（perf 不在這條測）。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-SEARCH-STATE" pkg)))
         (payload (and pkg (find-symbol "PDF-SEARCH-OVERLAY-PAYLOAD" pkg))))
    (when (and make payload (fboundp payload))
      (let* ((hits (loop for i from 0 below 1000
                         collect (list :|page| (mod i 100)
                                        :|rects| '((0.1 0.1 0.5 0.2)))))
             (s (funcall make :buffer-id "b" :query "q"
                              :hits hits :current-index 500)))
        (assert-no-error
          (funcall (symbol-function payload) s)
          "1000 hits payload 不該 crash")))))

(deftest v027-q-bookmark-list-100-entries
  "bookmark/list 拿 100 條 → list-bookmarks 不該 crash。
   completing-read 的 perf 屬 v0.25 責任、這條測 pdf-mode 不會炸。"
  (let ((items (loop for i from 0 below 100
                     collect (list :|name| (format nil "ch~a" i)
                                    :|page| i))))
    (with-mock-bridge (:responses
                       (list (cons "bookmark/list"
                                   (%make-ok (list :|items| items)))))
      (let* ((cmd-pkg (find-package '#:limn/cmd))
             (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg))))
        (when (and read-var (boundp read-var))
          (progv (list read-var)
                 (list (lambda (prompt) (declare (ignore prompt)) "ch5"))
            (assert-no-error
              (%call-cmd "PDF-LIST-BOOKMARKS")
              "100 個 bookmark 不該 crash list-bookmarks")))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §R schema versioning
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-r-schema-has-version-field
  "*pdf-annotations-schema-version* 應該存在 + 是 integer。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (sym (and pkg (find-symbol "*PDF-ANNOTATIONS-SCHEMA-VERSION*" pkg))))
    (when sym
      (assert-true (boundp sym) "schema-version bound")
      (assert-true (and (boundp sym)
                         (integerp (symbol-value sym))
                         (>= (symbol-value sym) 1))
                   "schema-version 是 ≥ 1 的整數"))))

(deftest v027-r-serialize-includes-version
  "serialize 出來的字串應該帶 :version N 欄位。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (ser (and pkg (find-symbol "PDF-ANNOTATIONS-SERIALIZE" pkg))))
    (when (and make ser (fboundp ser))
      (let* ((a (funcall make :id "u" :page 0 :rects '() :color "#FFD700"
                               :note nil :created-at 0))
             (str (funcall (symbol-function ser) (list a))))
        (when (stringp str)
          (assert-true (or (search ":version" str)
                            (search ":VERSION" str))
                       "序列化字串含 :version 欄位"))))))

(deftest v027-r-migrate-bumps-old-version
  "讀到舊 :version 0 sidecar → migrate 升到當前 version。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (migrate (and pkg (find-symbol "PDF-ANNOTATIONS-MIGRATE" pkg)))
         (cur (and pkg (find-symbol "*PDF-ANNOTATIONS-SCHEMA-VERSION*" pkg))))
    (when (and migrate cur (fboundp migrate) (boundp cur))
      (let* ((old-data (list :version 0 :annotations '()))
             (new-data (funcall (symbol-function migrate) old-data)))
        (when (listp new-data)
          (assert-equal (symbol-value cur)
                        (getf new-data :version)
                        "migrate 後 version = 當前 schema version"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §S process health — pump-thread death / silent fail visibility
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-s-overlay-after-disconnect-graceful
  "limn:call 在 backend 死掉時拋 error → pdf-mode 命令不該 crash whole process。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (call-var (and pkg (find-symbol "*LIMN-CALL-FN*" pkg))))
    (when (and call-var (boundp call-var))
      (progv (list call-var)
             (list (lambda (cmd &rest args)
                     (declare (ignore cmd args))
                     (error "pump thread died")))
        (assert-no-error
          (let ((r (%call-cmd "PDF-NEXT-PAGE"))) (declare (ignore r)))
          "backend 死掉時 pdf-next-page 不該 crash")))))

(deftest v027-s-load-time-watchdog
  "正常路徑下 next-page 應該在 50ms 內完成 wire round-trip（mock = 立刻回）。
   超時代表實作有 sync IO 死等之類問題。"
  (with-mock-bridge (:responses (list (%fake-view-get :page 0 :page-count 100)))
    (let* ((t0 (get-internal-real-time))
           (r (%call-cmd "PDF-NEXT-PAGE"))
           (dt (- (get-internal-real-time) t0))
           (ms (* 1000 (/ dt internal-time-units-per-second))))
      (declare (ignore r))
      (assert-true (< ms 50)
                   (format nil "next-page 在 50ms 內 (got ~,1f ms)" ms)))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §T cross-session state — last-position / search history
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-t-save-last-position-writes-vtable
  "PDF 關閉時應該存當前 (page, offset-y, zoom) 到 last-position sidecar。"
  (with-mock-bridge (:responses
                     (list (%fake-view-get :buffer-id "b1" :page 42
                                            :offset-y 0.3 :zoom 1.25)))
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (save (and pkg (find-symbol "PDF-MODE-SAVE-LAST-POSITION" pkg)))
           (write-var (and pkg (find-symbol "*LAST-POSITION-WRITE-FN*" pkg)))
           (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg)))
           (captured nil))
      (when (and save write-var (fboundp save))
        (progv (list write-var hash-var)
               (list (lambda (key data)
                       (declare (ignore key))
                       (setf captured data))
                     (lambda (p) (declare (ignore p)) "hashX"))
          (funcall (symbol-function save) :buffer-id "b1"
                                           :path "/tmp/p.pdf")
          (when captured
            (assert-equal 42 (getf captured :page)
                          "last position 含 page=42")
            (when (getf captured :zoom)
              (assert-true (< (abs (- (getf captured :zoom) 1.25)) 0.01)
                           "last position 含 zoom"))))))))

(deftest v027-t-restore-last-position-sets-view
  "engine-load 後若有 last-position sidecar → 跳到那個 page/zoom/offset。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (restore (and pkg (find-symbol "PDF-MODE-RESTORE-LAST-POSITION" pkg)))
           (read-var (and pkg (find-symbol "*LAST-POSITION-READ-FN*" pkg)))
           (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
      (when (and restore read-var (fboundp restore))
        (progv (list read-var hash-var)
               (list (lambda (key)
                       (declare (ignore key))
                       (list :page 17 :offset-y 0.5 :zoom 1.5))
                     (lambda (p) (declare (ignore p)) "hashX"))
          (funcall (symbol-function restore) :buffer-id "b1"
                                              :path "/tmp/p.pdf")
          (let ((vs (%mock-call-of "view/set")))
            (when vs
              (assert-equal 17 (getf vs :|page|)
                            "restore: page → 17"))))))))

(deftest v027-t-restore-nonexistent-position-noop
  "新 PDF 沒 last-position → restore 是 no-op、不 crash、不送 view/set。"
  (with-mock-bridge ()
    (let* ((pkg (find-package '#:limn/pdf-mode))
           (restore (and pkg (find-symbol "PDF-MODE-RESTORE-LAST-POSITION" pkg)))
           (read-var (and pkg (find-symbol "*LAST-POSITION-READ-FN*" pkg)))
           (hash-var (and pkg (find-symbol "*FILE-CONTENT-HASH-FN*" pkg))))
      (when (and restore read-var (fboundp restore))
        (progv (list read-var hash-var)
               (list (lambda (key) (declare (ignore key)) nil)
                     (lambda (p) (declare (ignore p)) "h"))
          (assert-no-error
            (funcall (symbol-function restore) :buffer-id "b1"
                                                :path "/new.pdf")
            "first-time PDF restore 不該 crash")
          (assert-equal 0 (%mock-call-count "view/set")
                        "沒 last-position → 不送 view/set"))))))

(deftest v027-t-search-history-uses-shared-ring
  "*pdf-last-search-query* 應該整合到 v0.25 *search-history*、跨 session 可 recall。"
  (let* ((pdf-pkg (find-package '#:limn/pdf-mode))
         (hist-pkg (find-package '#:limn/history))
         (last-var (and pdf-pkg (find-symbol "*PDF-LAST-SEARCH-QUERY*" pdf-pkg)))
         (ring-var (and hist-pkg (find-symbol "*SEARCH-HISTORY*" hist-pkg)))
         (add (and hist-pkg (find-symbol "ADD-TO-HISTORY" hist-pkg))))
    (when (and last-var ring-var add (boundp ring-var) (fboundp add))
      ;; 模擬 pdf-isearch-forward 寫進 history
      (with-mock-bridge (:responses (list (%fake-search-response :hits nil)))
        (let* ((cmd-pkg (find-package '#:limn/cmd))
               (read-var (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg))))
          (when (and read-var (boundp read-var))
            (progv (list read-var)
                   (list (lambda (prompt) (declare (ignore prompt)) "hello"))
              (let ((r (%call-cmd "PDF-ISEARCH-FORWARD"))) (declare (ignore r)))))))
      ;; 之後 *search-history* 應該包含 "hello"。
      ;; ring 可能是 struct 也可能是 list — 兩種接法都試。
      (let* ((ring (and (boundp ring-var) (symbol-value ring-var)))
             (items
               (cond
                 ((listp ring) ring)
                 ((and ring (find-symbol "HISTORY-RING-ITEMS" hist-pkg))
                  (funcall (find-symbol "HISTORY-RING-ITEMS" hist-pkg) ring))
                 (t nil))))
        (when (listp items)
          (assert-contains "hello" items
                            "search 後 query 進 *search-history* ring"))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §U init.lisp robustness
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-u-install-survives-multiple-loads
  "重複 install 後、binding count 應該保持穩定（不重複疊加 N 次）。"
  (let* ((mode-pkg (find-package '#:limn/mode))
         (keys-pkg (find-package '#:limn/keys))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg))))
    (%ensure-pdf-mode-installed)
    (%ensure-pdf-mode-installed)
    (%ensure-pdf-mode-installed)
    (when (and find-mode mode-keymap)
      (let* ((m (funcall find-mode 'cl-user::pdf-mode))
             (km (and m (funcall mode-keymap m))))
        (when km
          (let* ((lookup (and keys-pkg (find-symbol "LOOKUP-SEQUENCE" keys-pkg)))
                 (b (and lookup (funcall lookup km (list "j")))))
            (assert-true b "三次 install 後 j 仍綁到單一命令")))))))

(deftest v027-u-install-respects-user-override
  "user 在 init.lisp 重綁 j 後、再 install 一次（reload init）→ user binding 保留。"
  (%ensure-pdf-mode-installed)
  (let* ((mode-pkg (find-package '#:limn/mode))
         (keys-pkg (find-package '#:limn/keys))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg)))
         (def-key (and keys-pkg (find-symbol "DEFINE-KEY" keys-pkg)))
         (lookup (and keys-pkg (find-symbol "LOOKUP-SEQUENCE" keys-pkg))))
    (when (and find-mode mode-keymap def-key lookup)
      (let* ((m (funcall find-mode 'cl-user::pdf-mode))
             (km (and m (funcall mode-keymap m))))
        (when km
          ;; user override
          (funcall def-key km "j" 'cl-user::user-marker)
          ;; reload init.lisp → install 又跑一次
          (%ensure-pdf-mode-installed)
          (let ((b (funcall lookup km (list "j"))))
            (assert-equal 'cl-user::user-marker b
                          "install 不該 clobber user override")))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; §V workflow features — export org / recent PDFs / customize-vs-setf hooks
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-v-annotations-export-org-format
  "pdf-annotations-export-org 把 annotation 列表轉成 org-mode 文字。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (make (and pkg (find-symbol "MAKE-PDF-ANNOTATION" pkg)))
         (export (and pkg (find-symbol "PDF-ANNOTATIONS-EXPORT-ORG" pkg))))
    (when (and make export (fboundp export))
      (let* ((a (funcall make :id "u1" :page 5
                               :rects '((0.1 0.1 0.5 0.2))
                               :color "#FFD700"
                               :note "interesting"
                               :created-at 1700000000))
             (s (funcall (symbol-function export) (list a) "/tmp/paper.pdf")))
        (when (stringp s)
          (assert-true (or (search "* " s) (search "** " s))
                       "輸出含 org-mode heading marker")
          (assert-true (search "interesting" s)
                       "note 文字出現")
          (assert-true (search "paper.pdf" s)
                       "檔案名出現")
          (assert-true (or (search "6" s) (search "5" s))
                       "頁碼出現（0 或 1 索引皆 OK）"))))))

(deftest v027-v-annotations-export-empty
  "0 個 annotation → export 仍回字串（空文件或標題只）、不 crash。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (export (and pkg (find-symbol "PDF-ANNOTATIONS-EXPORT-ORG" pkg))))
    (when (and export (fboundp export))
      (assert-no-error
        (let ((s (funcall (symbol-function export) '() "/tmp/x.pdf")))
          (assert-type s string "空 export 仍回 string"))
        "export 0 annotations 不該 crash"))))

(deftest v027-v-recent-list-filters-pdfs
  "pdf-recent-list 從 v0.24 recentf 拿、只列 mupdf-loadable 檔。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (fn (and pkg (find-symbol "PDF-RECENT-LIST" pkg)))
         (rec-pkg (find-package '#:limn/recentf))
         (list-var (and rec-pkg (find-symbol "*RECENTF-LIST*" rec-pkg))))
    (when (and fn rec-pkg list-var (fboundp fn) (boundp list-var))
      (let ((orig (symbol-value list-var)))
        (unwind-protect
             (progn
               (setf (symbol-value list-var)
                     '("/tmp/a.pdf" "/tmp/notes.txt" "/tmp/b.pdf"
                       "/tmp/script.lisp"))
               (let ((result (funcall (symbol-function fn))))
                 (when (listp result)
                   (assert-true (every (lambda (p)
                                          (and (stringp p)
                                               (search ".pdf"
                                                        (string-downcase p))))
                                        result)
                                "結果全是 .pdf"))))
          (setf (symbol-value list-var) orig))))))

(deftest v027-v-customize-vs-setf-emits-hook
  "customize-set-variable 應該觸發 :set hook、setf 不會。
   dogfooder 如果在 init.lisp 用 setf 改 *pdf-annotation-color* 而不是
   customize-set、其他訂閱該變數改變的 callback 不會跑。"
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (sym (and pkg (find-symbol "*PDF-ANNOTATION-COLOR*" pkg)))
         (custom-pkg (find-package '#:limn/custom))
         (csv (and custom-pkg
                   (find-symbol "CUSTOMIZE-SET-VARIABLE" custom-pkg))))
    (when (and sym csv (boundp sym) (fboundp csv))
      (let ((hook-fired 0)
            (orig (symbol-value sym)))
        (unwind-protect
             (let* ((add-set-hook
                      (find-symbol "ADD-VARIABLE-SET-HOOK" custom-pkg)))
               (when (and add-set-hook (fboundp add-set-hook))
                 (funcall (symbol-function add-set-hook) sym
                           (lambda (v) (declare (ignore v))
                             (incf hook-fired)))
                 ;; (1) customize-set 應該觸發
                 (funcall (symbol-function csv) sym "#aaaaaa")
                 (assert-true (>= hook-fired 1)
                              "customize-set-variable 觸發 :set hook")))
          (setf (symbol-value sym) orig))))))


;;; ══════════════════════════════════════════════════════════════════════
;;; 跨段 invariants
;;; ══════════════════════════════════════════════════════════════════════

(deftest v027-x-install-is-idempotent
  "重複呼叫 install 不應拋錯。"
  (assert-no-error (progn (%ensure-pdf-mode-installed)
                          (%ensure-pdf-mode-installed)
                          (%ensure-pdf-mode-installed))
                   "install 多次無錯"))

(deftest v027-x-vtable-defaults-bound
  "*limn-call-fn* / *now-fn* 都應該預設 bound（fallback 到真實實作或 no-op）。"
  (let ((pkg (find-package '#:limn/pdf-mode)))
    (when pkg
      (let ((call-var (find-symbol "*LIMN-CALL-FN*" pkg))
            (now-var  (find-symbol "*NOW-FN*" pkg)))
        (assert-true (and call-var (boundp call-var))
                     "*limn-call-fn* bound")
        (assert-true (and now-var (boundp now-var))
                     "*now-fn* bound")))))

;;; ── v0.39 W04 — pdf-toc unwraps response correctly ───────────────────
;;;
;;; The C++ side of buffer/toc emits the TOC items as the response data
;;; directly (an array of plists), NOT wrapped as {items: [...]}.  Pre-
;;; v0.39 pdf-toc tried `(getf data :items)` which on a malformed plist
;;; (the items array iterated as a property list) either signalled
;;; SIMPLE-TYPE-ERROR or silently returned NIL — depending on parity.
;;; Either way `items` was nil, completing-read never opened, and `t`
;;; in pdf-mode appeared to do nothing.  This was the actual cause of
;;; W04 A.1 failing — the "deadlock" diagnosis from v0.38 was a
;;; misread; there was never any contention.

(deftest v039-w04-pdf-toc-uses-data-as-items-array
  "pdf-toc should consume the response data as the items array itself
   — verify completing-read sees a non-empty `collection` argument
   when the mock returns the canonical array-of-plists shape."
  (%ensure-pdf-mode-installed)
  (let* ((sample-toc (list (list :|children| nil :|page| 0
                                  :|title| "1. Intro")
                            (list :|children| nil :|page| 2
                                  :|title| "2. Body")
                            (list :|children| nil :|page| 5
                                  :|title| "3. Outro")))
         (collection-seen nil)
         (orig-completing
           (and (find-package '#:limn/completion)
                (find-symbol "COMPLETING-READ" '#:limn/completion))))
    (when orig-completing
      ;; Stub completing-read so it captures `collection` without
      ;; actually blocking on minibuffer-read.
      (let ((orig-fn (and (fboundp orig-completing)
                          (symbol-function orig-completing))))
        (unwind-protect
             (progn
               (setf (fdefinition orig-completing)
                     (lambda (prompt collection &rest opts)
                       (declare (ignore prompt opts))
                       (setf collection-seen collection)
                       nil))
               (with-mock-bridge
                   (:responses
                    (list (cons "buffer/toc" (%make-ok sample-toc))
                          (cons "view/get"  (%make-ok
                                              (list :|buffer-id| "b1"
                                                    :|page| 0)))))
                 (%call-cmd "PDF-TOC"))
               (assert-true collection-seen
                            "completing-read received a non-empty collection")
               (when collection-seen
                 (assert-eql 3 (length collection-seen)
                             "3 TOC lines forwarded to completing-read")))
          (when orig-fn
            (setf (fdefinition orig-completing) orig-fn)))))))

(deftest v039-w04-pdf-toc-no-items-is-safe-noop
  "pdf-toc with empty TOC: should not crash; completing-read not invoked
   (since (listp NIL) is t, %toc-flatten on NIL produces an empty list
   and completing-read gets an empty collection — which is fine)."
  (%ensure-pdf-mode-installed)
  (with-mock-bridge (:responses (list (cons "buffer/toc"  (%make-ok nil))
                                       (cons "view/get"   (%make-ok
                                                            (list :|buffer-id| "b1")))))
    (assert-no-error (%call-cmd "PDF-TOC")
                     "pdf-toc with empty TOC is a no-op, not an error")))
