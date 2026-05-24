;;;; v0.28 §B — map! macro RED tests  (~26 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/map-macro : map! macro 展開正確性
;;;;                    :map KEYMAP
;;;;                    :prefix STRING 串聯
;;;;                    :mode SYM 查 keymap
;;;;                    :leader → *leader-keymap*
;;;;                    錯誤情況
;;;;   limn/keys      : *leader-key* / *leader-keymap*（v0.28 新增）
;;;;
;;;; map! 是純 macro sugar，展開成一組 limn/keys:define-key 呼叫。
;;;; 測試不 inspect macro 展開式，而是直接觀察 side effect（keymap 中的 binding）。
;;;;
;;;; 全部 RED — 在 limn-map-macro.lisp 實作前都會 fail。

;; ── package stubs ─────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; limn/map-macro — new module
  (unless (find-package '#:limn/map-macro)
    (make-package '#:limn/map-macro :use '(#:cl)))
  (dolist (sym '("MAP!"))
    (let ((s (intern sym '#:limn/map-macro)))
      (export s '#:limn/map-macro)))

  ;; limn/keys — add v0.28 leader symbols if package exists but lacks them
  (let ((pkg (find-package '#:limn/keys)))
    (when pkg
      (dolist (sym '("*LEADER-KEY*" "*LEADER-KEYMAP*"))
        (unless (find-symbol sym pkg)
          (export (intern sym pkg) pkg))))))

(in-package #:limn/unit-test)

;;; ── helper ───────────────────────────────────────────────────────────────

(defun %keys-lookup (km key-spec)
  "Call limn/keys:lookup on KM with KEY-SPEC.  Returns nil if package absent."
  (let ((pkg (find-package '#:limn/keys)))
    (when pkg
      (let ((lkp (find-symbol "LOOKUP" pkg)))
        (when (and lkp (fboundp lkp))
          (funcall (symbol-function lkp) km key-spec))))))

(defun %split-keys (s)
  "Split a space-separated key sequence into a list of single key strings."
  (let ((parts '()) (start 0))
    (dotimes (i (length s))
      (when (char= (char s i) #\Space)
        (push (subseq s start i) parts)
        (setf start (1+ i))))
    (push (subseq s start) parts)
    (nreverse parts)))

(defun %keys-lookup-seq (km seq)
  "Call limn/keys:lookup-sequence on KM with SEQ string.  Returns nil if absent.
   SEQ is a space-separated key string; it is split before passing on."
  (let ((pkg (find-package '#:limn/keys)))
    (when pkg
      (let ((lkp (find-symbol "LOOKUP-SEQUENCE" pkg)))
        (when (and lkp (fboundp lkp))
          (funcall (symbol-function lkp) km (%split-keys seq)))))))

(defun %make-keymap ()
  "Create a fresh keymap via limn/keys:make-keymap."
  (let ((pkg (find-package '#:limn/keys)))
    (when pkg
      (let ((mk (find-symbol "MAKE-KEYMAP" pkg)))
        (when (and mk (fboundp mk))
          (funcall (symbol-function mk)))))))

;;; ── B1. :map — 基本綁定 ──────────────────────────────────────────────────

(deftest map-b1-single-binding
  "map! :map 把單個 key spec 綁到 command。"
  (let ((km (%make-keymap)))
    (when km
      (let ((cmd (lambda () :scroll-down)))
        (limn/map-macro:map! :map km
          "j" cmd)
        (assert-true (%keys-lookup km "j") "\"j\" should be bound")))))

(deftest map-b1-multiple-bindings
  "map! :map 一次批次綁定多個 key/command 對。"
  (let ((km (%make-keymap)))
    (when km
      (let ((cmd-j (lambda () :j))
            (cmd-k (lambda () :k)))
        (limn/map-macro:map! :map km
          "j" cmd-j
          "k" cmd-k)
        (assert-true (%keys-lookup km "j") "\"j\" bound")
        (assert-true (%keys-lookup km "k") "\"k\" bound")))))

(deftest map-b1-chord-binding
  "map! :map 可綁定多鍵 chord（如 C-x C-s）。"
  (let ((km (%make-keymap)))
    (when km
      (let ((save (lambda () :save)))
        (limn/map-macro:map! :map km
          "C-x C-s" save)
        (assert-true (%keys-lookup-seq km "C-x C-s") "C-x C-s should be bound")))))

(deftest map-b1-symbol-as-command
  "map! :map 接受 function symbol（#'cmd）作為 action。"
  (let ((km (%make-keymap)))
    (when km
      (flet ((my-cmd () :my-cmd))
        (limn/map-macro:map! :map km
          "x" #'my-cmd)
        (assert-true (%keys-lookup km "x") "\"x\" should be bound")))))

(deftest map-b1-binding-replaces-old
  "map! :map 重新綁定同一個 key 會覆蓋舊的 action。"
  (let ((km (%make-keymap)))
    (when km
      (let ((old (lambda () :old))
            (new (lambda () :new)))
        (limn/map-macro:map! :map km "j" old)
        (limn/map-macro:map! :map km "j" new)
        (let ((bound (%keys-lookup km "j")))
          (assert-true (and bound (not (eq bound old)))
                       "new binding should shadow old"))))))

;;; ── B2. :prefix — 前綴串聯 ───────────────────────────────────────────────

(deftest map-b2-prefix-prepends-to-keys
  ":prefix 讓後續 key spec 自動帶前綴。"
  (let ((km (%make-keymap)))
    (when km
      (let ((first  (lambda () :first))
            (last   (lambda () :last)))
        (limn/map-macro:map! :map km :prefix "g"
          "g" first
          "G" last)
        (assert-true (%keys-lookup-seq km "g g") "\"g g\" should be bound")
        (assert-true (%keys-lookup-seq km "g G") "\"g G\" should be bound")))))

(deftest map-b2-prefix-does-not-bind-prefix-key-alone
  ":prefix \"g\" 不應讓 \"g\" 本身有 final binding（只是前綴）。"
  (let ((km (%make-keymap)))
    (when km
      (let ((cmd       (lambda () :cmd))
            (keys-pkg  (find-package '#:limn/keys)))
        (limn/map-macro:map! :map km :prefix "g"
          "g" cmd)
        ;; Bare "g" should be a prefix (sub-keymap), not the cmd itself
        (let* ((result (%keys-lookup km "g"))
               (kmap-p (and keys-pkg (find-symbol "KEYMAP-P" keys-pkg))))
          (assert-true (or (eq result :prefix)
                           (null result)
                           (and kmap-p (funcall (symbol-function kmap-p) result)))
                       "bare \"g\" should be a prefix entry, not the final cmd"))))))

(deftest map-b2-prefix-with-multi-key-specs
  ":prefix 可與多鍵 key spec 組合（前綴 + \"f f\" = \"SPC f f\"）。"
  (let ((km (%make-keymap)))
    (when km
      (let ((ff (lambda () :find-file)))
        (limn/map-macro:map! :map km :prefix "SPC"
          "f f" ff)
        (assert-true (%keys-lookup-seq km "SPC f f") "\"SPC f f\" should be bound")))))

(deftest map-b2-no-prefix-still-works
  "沒有 :prefix 時行為與 v0.28 前相同（直接綁定）。"
  (let ((km (%make-keymap)))
    (when km
      (let ((cmd (lambda () :cmd)))
        (limn/map-macro:map! :map km
          "C-f" cmd)
        (assert-true (%keys-lookup-seq km "C-f") "C-f directly bound")))))

;;; ── B3. :mode — 透過 mode 名查 keymap ───────────────────────────────────

(deftest map-b3-mode-binds-into-mode-keymap
  ":mode 'text-mode 等同 :map <text-mode 的 keymap>。"
  ;; Only runs if limn/mode is loaded and text-mode exists.
  (let ((mode-pkg (find-package '#:limn/mode)))
    (if (null mode-pkg)
        (check t "skipped (limn/mode not loaded)" nil)
        (let* ((find-mode (find-symbol "FIND-MODE"    mode-pkg))
               (mode-km   (find-symbol "MODE-KEYMAP"  mode-pkg))
               (tm-sym    (find-symbol "TEXT-MODE"    :cl-user)))
          (if (or (null find-mode) (null mode-km) (null tm-sym))
              (check t "skipped (mode symbols not found)" nil)
              (let* ((mode-obj (funcall (symbol-function find-mode) tm-sym))
                     (km       (when mode-obj
                                 (funcall (symbol-function mode-km) mode-obj))))
                (if (null km)
                    (check t "skipped (text-mode keymap not found)" nil)
                    (let ((cmd (lambda () :test-cmd)))
                      (limn/map-macro:map! :mode 'cl-user::text-mode
                        "C-t" cmd)
                      (assert-true (%keys-lookup-seq km "C-t")
                                   ":mode should bind into text-mode keymap")))))))))

(deftest map-b3-mode-with-prefix
  ":mode + :prefix 組合正確。"
  (let ((mode-pkg (find-package '#:limn/mode)))
    (if (null mode-pkg)
        (check t "skipped (limn/mode not loaded)" nil)
        (let* ((find-mode (find-symbol "FIND-MODE"   mode-pkg))
               (mode-km   (find-symbol "MODE-KEYMAP" mode-pkg))
               (tm-sym    (find-symbol "TEXT-MODE"   :cl-user)))
          (if (or (null find-mode) (null mode-km) (null tm-sym))
              (check t "skipped" nil)
              (let* ((mode-obj (funcall (symbol-function find-mode) tm-sym))
                     (km       (when mode-obj
                                 (funcall (symbol-function mode-km) mode-obj))))
                (if (null km)
                    (check t "skipped" nil)
                    (let ((cmd (lambda () :prefix-cmd)))
                      (limn/map-macro:map! :mode 'cl-user::text-mode :prefix "C-c"
                        "p" cmd)
                      (assert-true (%keys-lookup-seq km "C-c p")
                                   ":mode + :prefix should bind \"C-c p\"")))))))))

;;; ── B4. :leader — 綁到 *leader-keymap* ──────────────────────────────────

(deftest map-b4-leader-binds-into-leader-keymap
  ":leader 把按鍵綁到 limn/keys:*leader-keymap*。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped (limn/keys not loaded)" nil)
        (let ((lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
          (if (null lkm-sym)
              (check t "skipped (*leader-keymap* not found)" nil)
              (let ((original (when (boundp lkm-sym) (symbol-value lkm-sym)))
                    (fresh-km (%make-keymap)))
                ;; Temporarily set *leader-keymap* to a fresh km for isolation
                (progv (list lkm-sym) (list fresh-km)
                  (let ((cmd (lambda () :leader-cmd)))
                    (limn/map-macro:map! :leader
                      "f f" cmd)
                    (assert-true (%keys-lookup-seq fresh-km "f f")
                                 "\"f f\" should be in *leader-keymap*")))))))))

(deftest map-b4-leader-multiple-bindings
  ":leader 一次批次綁多個。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped" nil)
        (let ((lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
          (if (null lkm-sym)
              (check t "skipped" nil)
              (let ((fresh-km (%make-keymap)))
                (progv (list lkm-sym) (list fresh-km)
                  (let ((ff (lambda () :find-file))
                        (bb (lambda () :switch-buffer)))
                    (limn/map-macro:map! :leader
                      "f f" ff
                      "b b" bb)
                    (assert-true (%keys-lookup-seq fresh-km "f f") "f f bound")
                    (assert-true (%keys-lookup-seq fresh-km "b b") "b b bound")))))))))

(deftest map-b4-leader-key-default-value
  "limn/keys:*leader-key* 預設值是 \"SPC\"。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped (limn/keys not loaded)" nil)
        (let ((lk-sym (find-symbol "*LEADER-KEY*" keys-pkg)))
          (if (null lk-sym)
              (check t "skipped (*leader-key* not found)" nil)
              (assert-equal "SPC" (symbol-value lk-sym)
                            "*leader-key* default should be \"SPC\""))))))

(deftest map-b4-leader-keymap-is-keymap-object
  "limn/keys:*leader-keymap* 是一個 keymap object（limn/keys:keymap-p 為 t）。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped" nil)
        (let ((lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg))
              (kmap-p  (find-symbol "KEYMAP-P"        keys-pkg)))
          (if (or (null lkm-sym) (null kmap-p))
              (check t "skipped" nil)
              (when (boundp lkm-sym)
                (assert-true (funcall (symbol-function kmap-p)
                                      (symbol-value lkm-sym))
                             "*leader-keymap* should satisfy keymap-p")))))))

;;; ── B5. 錯誤情況 ─────────────────────────────────────────────────────────

(deftest map-b5-map-and-leader-exclusive
  ":map 和 :leader 同時指定時 signal error。"
  (let ((km (%make-keymap)))
    (when km
      (assert-error error
        (limn/map-macro:map! :map km :leader
          "j" (lambda () :cmd))
        ":map and :leader together should signal an error"))))

(deftest map-b5-empty-key-list-ok
  "map! :map 帶空的 key 列表時不 error（no-op）。"
  (let ((km (%make-keymap)))
    (when km
      (assert-no-error
        (limn/map-macro:map! :map km)
        "empty key list should be a no-op"))))

(deftest map-b5-nil-keymap-signals-error
  "map! :map nil 時 signal error（nil 不是合法 keymap）。"
  (assert-error error
    (limn/map-macro:map! :map nil
      "j" (lambda () :cmd))
    ":map nil should signal an error"))

;;; ── B6. macro-expansion 冪等性 ───────────────────────────────────────────

(deftest map-b6-repeated-map-same-key-is-idempotent
  "重複 map! 同一個 key 不增加 binding 數量，最後一個 wins。"
  (let ((km (%make-keymap)))
    (when km
      (let ((cmd1 (lambda () :one))
            (cmd2 (lambda () :two)))
        (limn/map-macro:map! :map km "j" cmd1)
        (limn/map-macro:map! :map km "j" cmd2)
        ;; Only one binding for "j"
        (let ((b1 (%keys-lookup km "j")))
          (assert-true b1 "\"j\" should be bound")
          (assert-false (eq b1 cmd1) "old binding should be replaced"))))))

(deftest map-b6-prefix-and-direct-binding-coexist
  ":prefix \"g\" のバインドと直接 \"x\" バインドは共存できる。"
  (let ((km (%make-keymap)))
    (when km
      (let ((g-cmd (lambda () :g-cmd))
            (x-cmd (lambda () :x-cmd)))
        (limn/map-macro:map! :map km :prefix "g"
          "g" g-cmd)
        (limn/map-macro:map! :map km
          "x" x-cmd)
        (assert-true (%keys-lookup-seq km "g g") "\"g g\" bound via prefix")
        (assert-true (%keys-lookup    km "x")    "\"x\" directly bound")))))

;;; ── B7. Dogfood pain points — forward reference / lambda / 邊界 ────────

(deftest map-b7-symbol-as-action-no-fboundp-required
  "用未 fboundp 的 symbol 作為 action 時，map! 不該 error（forward reference）。"
  ;; User init.lisp 常見順序：先 bind 後 defcommand。
  ;; map! 應該接受任何 symbol 而不在 macro time 檢查 fboundp。
  (let ((km (%make-keymap)))
    (when km
      (assert-no-error
        (limn/map-macro:map! :map km
          "j" 'this-command-does-not-exist-yet)
        "binding to non-fboundp symbol should not error at macro time"))))

(deftest map-b7-inline-lambda-as-action
  "inline lambda 作為 action 正常綁定。"
  (let ((km (%make-keymap)))
    (when km
      (limn/map-macro:map! :map km
        "j" (lambda () :inline-lambda))
      (assert-true (%keys-lookup km "j") "lambda should be bound"))))

(deftest map-b7-empty-prefix-no-op
  ":prefix \"\" 等同於沒有 :prefix（直接綁定原 key）。"
  (let ((km (%make-keymap)))
    (when km
      (limn/map-macro:map! :map km :prefix ""
        "j" (lambda () :j))
      (assert-true (%keys-lookup km "j")
                   "with empty prefix, \"j\" should be bound at top level"))))

(deftest map-b7-leader-with-prefix-combined
  ":leader + :prefix 組合：綁到 *leader-keymap* 的 \"f f\" 等。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped" nil)
        (let ((lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
          (if (null lkm-sym)
              (check t "skipped" nil)
              (let ((fresh-km (%make-keymap)))
                (progv (list lkm-sym) (list fresh-km)
                  (limn/map-macro:map! :leader :prefix "f"
                    "f" (lambda () :find-file)
                    "r" (lambda () :recentf))
                  (assert-true (%keys-lookup-seq fresh-km "f f") "\"f f\" bound")
                  (assert-true (%keys-lookup-seq fresh-km "f r") "\"f r\" bound"))))))))

(deftest map-b7-existing-binding-preserved-when-untouched
  "map! 只動到指定的 key；其他既有 binding 不受影響。"
  (let ((km (%make-keymap)))
    (when km
      (let* ((keys-pkg (find-package '#:limn/keys))
             (def-fn   (and keys-pkg (find-symbol "DEFINE-KEY" keys-pkg))))
        (when (and def-fn (fboundp def-fn))
          ;; Pre-existing binding for "z"
          (funcall (symbol-function def-fn) km "z" (lambda () :z))
          ;; map! touches only "j"
          (limn/map-macro:map! :map km
            "j" (lambda () :j))
          (assert-true (%keys-lookup km "z") "\"z\" should still be bound")
          (assert-true (%keys-lookup km "j") "\"j\" should be bound now"))))))

(deftest map-b7-final-binding-overwrites-prefix
  "用 final binding 覆蓋既存的 prefix entry（砍掉 prefix subtree）。"
  ;; Build: km has "g g" via :prefix, then map! :map km "g" #'overwrite
  (let ((km (%make-keymap)))
    (when km
      (limn/map-macro:map! :map km :prefix "g"
        "g" (lambda () :first))
      ;; Now bind "g" directly — should replace the prefix subtree
      (limn/map-macro:map! :map km
        "g" (lambda () :overwrite))
      (let* ((result   (%keys-lookup km "g"))
             (keys-pkg (find-package '#:limn/keys))
             (kmap-p   (and keys-pkg (find-symbol "KEYMAP-P" keys-pkg))))
        (assert-true (functionp result)
                     "\"g\" should resolve to a function (the overwrite cmd)")
        (when kmap-p
          (assert-false (funcall (symbol-function kmap-p) result)
                        "\"g\" should NOT be a sub-keymap after overwrite"))))))

(deftest map-b7-mixed-bare-and-chord-keys
  "map! 一次混合單鍵和 chord（C-x C-s）綁定。"
  (let ((km (%make-keymap)))
    (when km
      (limn/map-macro:map! :map km
        "j"       (lambda () :j)
        "C-x C-s" (lambda () :save)
        "M-f"     (lambda () :forward-word))
      (assert-true (%keys-lookup     km "j")        "\"j\" bound")
      (assert-true (%keys-lookup-seq km "C-x C-s")  "\"C-x C-s\" bound")
      (assert-true (%keys-lookup-seq km "M-f")      "\"M-f\" bound"))))
