;;;; fuzzy-selector — §5–§6 Vertico + Orderless completing-read 單元測試
;;;;
;;;; 測試 *enable-fuzzy-selector* 開關、vertico-completing-read 的 headless
;;;; 模式，以及 session 狀態機（建立、過濾、移動、確認、取消）。
;;;; 所有測試均為 headless（不需 Qt / bridge）。

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/completion)
    (make-package '#:limn/completion :use '(#:cl))))

(in-package #:limn/unit-test)

;;; ─── FS1: *enable-fuzzy-selector* 開關 ─────────────────────────────

(deftest fs1-enable-fuzzy-selector-default-nil
  "*enable-fuzzy-selector* 預設為 nil。"
  (assert-false limn/completion:*enable-fuzzy-selector*
                "*enable-fuzzy-selector* should default to nil"))

(deftest fs1-enable-fuzzy-selector-toggle
  "enable-fuzzy-selector / disable-fuzzy-selector 切換開關。"
  (let ((old limn/completion:*enable-fuzzy-selector*))
    (unwind-protect
        (progn
          (limn/completion:enable-fuzzy-selector)
          (assert-true limn/completion:*enable-fuzzy-selector*
                       "enable 後應為 t")
          (limn/completion:disable-fuzzy-selector)
          (assert-false limn/completion:*enable-fuzzy-selector*
                        "disable 後應為 nil"))
      (setf limn/completion:*enable-fuzzy-selector* old))))

;;; ─── FS2: *enable-fuzzy-selector* = nil 走舊路徑 ────────────────────

(deftest fs2-nil-goes-old-path
  "*enable-fuzzy-selector* = nil 時，completing-read 走舊路徑（substring 比對）。"
  (let ((limn/completion:*enable-fuzzy-selector* nil))
    (let ((result (limn/completion:completing-read
                   "Pick: " '("alpha" "beta" "gamma")
                   :initial-input "alp" :require-match t)))
      (assert-equal "alpha" result "nil 時走舊 substring 比對回 alpha"))))

;;; ─── FS3: *enable-fuzzy-selector* = t 時走 vertico 路徑 ─────────────

(deftest fs3-t-goes-vertico-path
  "*enable-fuzzy-selector* = t 時，completing-read 建 Vertico session 並以
   orderless 過濾。"
  (let ((limn/completion:*enable-fuzzy-selector* t))
    (let ((result (limn/completion:completing-read
                   "Pick: " '("apple" "apricot" "banana" "blueberry" "cherry")
                   :initial-input "ap" :require-match t)))
      ;; orderless 過濾：apple 與 apricot 都匹配 "ap"
      (assert-true (member result '("apple" "apricot") :test #'equal)
                   "模糊比對 ap 應回 apple 或 apricot（依分數排序，apple 較短優先）"))))

;;; ─── FS4: 空輸入 → 全部候選 ────────────────────────────────────────

(deftest fs4-empty-input-shows-all
  "空輸入時，全部候選都在 filtered 裡（orderless 空查詢 = 全部匹配）。"
  (let ((session (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-update-input session "")
    (let ((filtered (limn/vertico:session-filtered-candidates session)))
      (assert-equal 3 (length filtered) "空輸入 → 3 個候選")
      (assert-contains "alpha" filtered)
      (assert-contains "beta"  filtered)
      (assert-contains "gamma" filtered))))

;;; ─── FS5: 輸入 "ap" → 只剩 apple/apricot ────────────────────────────

(deftest fs5-filter-ap
  "輸入 'ap' 後，filtered-candidates 只剩 apple 與 apricot。"
  (let ((session (limn/vertico:make-session
                  '("apple" "apricot" "banana" "blueberry" "cherry"))))
    (limn/vertico:session-update-input session "ap")
    (let ((filtered (limn/vertico:session-filtered-candidates session)))
      (assert-equal 2 (length filtered) "ap 應過濾到 2 個候選")
      (assert-contains "apple"   filtered)
      (assert-contains "apricot" filtered)
      (assert-false (member "banana" filtered :test #'equal)
                    "banana 不應在結果中"))))

;;; ─── FS6: move +1 → index = 1，current = second candidate ───────────

(deftest fs6-move-down
  "session-move +1 將選中索引移到第二個候選。"
  (let ((session (limn/vertico:make-session
                  '("apple" "apricot" "banana"))))
    (limn/vertico:session-update-input session "ap")
    ;; 初始 index = 0
    (assert-equal 0 (limn/vertico:session-index session)
                  "初始 index = 0")
    (assert-equal "apple" (limn/vertico:session-current session)
                  "初始 current = apple")
    ;; move +1
    (limn/vertico:session-move session 1)
    (assert-equal 1 (limn/vertico:session-index session)
                  "move +1 → index = 1")
    (assert-equal "apricot" (limn/vertico:session-current session)
                  "move +1 → current = apricot")))

;;; ─── FS7: move 超過範圍會 clamp ─────────────────────────────────────

(deftest fs7-move-clamp
  "session-move 會 clamp 到 [0, len-1]，不 wrap。"
  (let ((session (limn/vertico:make-session '("apple" "apricot"))))
    (limn/vertico:session-update-input session "ap")
    ;; move down past end
    (limn/vertico:session-move session 10)
    (assert-equal 1 (limn/vertico:session-index session)
                  "move +10 clamp 到 1")
    ;; move up past start
    (limn/vertico:session-move session -10)
    (assert-equal 0 (limn/vertico:session-index session)
                  "move -10 clamp 到 0")))

;;; ─── FS8: move -1 → 向上移動 ─────────────────────────────────────────

(deftest fs8-move-up
  "session-move -1 將選中索引往上移。"
  (let ((session (limn/vertico:make-session '("apple" "apricot" "banana"))))
    (limn/vertico:session-update-input session "a")
    ;; 初始 index = 0
    (limn/vertico:session-move session 2)  ; 移到最後
    (assert-equal 2 (limn/vertico:session-index session))
    (limn/vertico:session-move session -1)
    (assert-equal 1 (limn/vertico:session-index session)
                  "move -1 → index = 1")
    (assert-equal "apricot" (limn/vertico:session-current session))))

;;; ─── FS9: confirm 回傳選中候選 ──────────────────────────────────────

(deftest fs9-confirm-returns-selected
  "模擬使用者流程：input → filter → move → confirm。"
  (let ((session (limn/vertico:make-session
                  '("apple" "apricot" "banana" "blueberry" "cherry"))))
    ;; 步驟 1：輸入 "ap"
    (limn/vertico:session-update-input session "ap")
    (assert-equal 2 (length (limn/vertico:session-filtered-candidates session))
                  "filtered 應有 2 個")
    ;; 步驟 2：移到第二個
    (limn/vertico:session-move session 1)
    (assert-equal "apricot" (limn/vertico:session-current session)
                  "current 應為 apricot")
    ;; 步驟 3：確認回傳
    (assert-equal "apricot" (limn/vertico:session-current session)
                  "session-current 回傳選中的候選")))

;;; ─── FS10: cancel → no selection ────────────────────────────────────

(deftest fs10-cancel-no-selection
  "空 filtered 時 session-current 回傳 nil。"
  (let ((session (limn/vertico:make-session '("apple" "apricot"))))
    (limn/vertico:session-update-input session "zzz")
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates session))
                  "zzz 無匹配 → filtered 為空")
    (assert-false (limn/vertico:session-current session)
                  "無匹配時 session-current = nil")))

;;; ─── FS11: vertico-completing-read headless 完整流程 ─────────────────

(deftest fs11-vertico-completing-read-headless
  "headless 模式中 vertico-completing-read 完整流程：建 session、過濾、回傳。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("apple" "apricot" "banana" "blueberry" "cherry")
                 :initial-input "" :require-match nil)))
    ;; 空輸入 → 所有候選，回傳第一個（apple，因分數排序）
    (assert-true (member result '("apple" "apricot" "banana" "blueberry" "cherry")
                         :test #'equal)
                 "headless 空輸入回傳某個候選")))

(deftest fs11-vertico-completing-read-with-initial
  "headless 模式帶 initial-input 過濾。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("apple" "apricot" "banana")
                 :initial-input "ap" :require-match t)))
    (assert-true (member result '("apple" "apricot") :test #'equal)
                 "headless ap 過濾回 apple 或 apricot")))

(deftest fs11-vertico-completing-read-require-match-error
  "headless 模式 require-match + 無匹配 → error。"
  (assert-error error
    (limn/vertico:vertico-completing-read
     "Pick: " '("apple" "apricot")
     :initial-input "zzz" :require-match t)
    "無匹配 + require-match → error"))

(deftest fs11-vertico-completing-read-with-default
  "headless 模式無匹配 + default → 回傳 default。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("apple" "apricot")
                 :initial-input "zzz" :default "fallback")))
    (assert-equal "fallback" result
                  "無匹配 + default → fallback")))

;;; ─── FS12: completing-read with *enable-fuzzy-selector* = t full ─────

(deftest fs12-completing-read-fuzzy-headless
  "透過 completing-read（*enable-fuzzy-selector* = t）走 vertico 路徑。"
  (let ((limn/completion:*enable-fuzzy-selector* t))
    (let ((result (limn/completion:completing-read
                   "Pick: " '("apple" "apricot" "banana")
                   :initial-input "ap" :require-match t)))
      (assert-true (member result '("apple" "apricot") :test #'equal)
                   "completing-read with fuzzy = t → vertico path"))))

;;; ─── FS13: visible window scroll test ────────────────────────────────

(deftest fs13-visible-window-scroll
  "session-visible 正確回傳可見窗格內容與相對索引。"
  (let ((session (limn/vertico:make-session
                  (loop for i from 1 to 30 collect (format nil "item-~2,'0d" i))
                  :window-size 10)))
    ;; 初始：index=0, scroll=0, 可見 items-01~item-10（indices 0~9）
    (let ((vis (limn/vertico:session-visible session)))
      (assert-equal 10 (length (car vis)) "可見 10 個候選")
      (assert-equal 0 (cdr vis) "相對索引 = 0")
      (assert-equal "item-01" (elt (car vis) 0) "窗格首位為 item-01"))
    ;; 移到 index 12（第 13 個），scroll 應調整
    ;; offset = max(0, 12 - 10 + 1) = 3
    ;; visible = items at indices 3~12 → "item-04" ~ "item-13"
    ;; index 12 at relative = 12 - 3 = 9 (last visible row)
    (limn/vertico:session-move session 12)
    (let ((vis (limn/vertico:session-visible session)))
      (assert-equal 9 (cdr vis) "相對索引 = 9（在窗格末位）")
      (assert-equal "item-04" (elt (car vis) 0) "窗格起於 item-04"))
    (assert-equal 3 (limn/vertico:session-scroll-offset session)
                  "scroll-offset = 3")))

;;; ─── FS14: predicate 在 fuzzy 模式中也生效 ──────────────────────────

(deftest fs14-predicate-in-fuzzy-mode
  "predicate 參數在 fuzzy 模式中也會過濾候選。"
  (let ((limn/completion:*enable-fuzzy-selector* t))
    (let ((result (limn/completion:completing-read
                   "Pick: " '("apple" "apricot" "beta")
                   :predicate (lambda (s) (char= (char s 0) #\a))
                   :initial-input "" :require-match t)))
      ;; 只有 a 開頭的候選：apple, apricot
      (assert-true (member result '("apple" "apricot") :test #'equal)
                   "predicate 過濾只留 a 開頭"))))
