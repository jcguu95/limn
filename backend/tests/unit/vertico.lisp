;;;; vertico.lisp — Vertico 補全 UI 狀態機的 unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — make-session 初始狀態正確
;;;;   §2 — session-update-input 過濾行為
;;;;   §3 — session-move 移動與 clamp
;;;;   §4 — session-visible 窗格內容與相對索引
;;;;   §5 — session-current 選中候選
;;;;   §6 — scroll-offset 滑動邏輯
;;;;   §7 — 邊界情況（空候選集、查詢無符合、window-size 大於候選數）
;;;;   §8 — 整合測試：orderless multi-component 過濾
;;;;
;;;; limn-vertico 透過 limn.asd 載入，不需手動 load。

(in-package #:limn/unit-test)

;;; ─── §1 make-session 初始狀態 ──────────────────────────────────────────

(deftest vertico-s1-make-session-basic
  "make-session 應正確初始化所有欄位。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma") :window-size 10)))
    (assert-equal 3 (length (limn/vertico:session-all-candidates s)))
    (assert-equal "" (limn/vertico:session-input s))
    (assert-equal 3 (length (limn/vertico:session-filtered-candidates s))
                  "初始 filtered = all-candidates")
    (assert-equal 0 (limn/vertico:session-index s)
                  "初始 index = 0")
    (assert-equal 0 (limn/vertico:session-scroll-offset s)
                  "初始 scroll-offset = 0")
    (assert-equal 10 (limn/vertico:session-window-size s)
                  "預設 window-size = 10")))

(deftest vertico-s1-make-session-custom-window
  "make-session 應接受自訂 window-size。"
  (let ((s (limn/vertico:make-session '("a" "b") :window-size 5)))
    (assert-equal 5 (limn/vertico:session-window-size s))))

(deftest vertico-s1-make-session-empty
  "make-session 應能處理空的候選集。"
  (let ((s (limn/vertico:make-session '())))
    (assert-equal 0 (length (limn/vertico:session-all-candidates s)))
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s)))
    (assert-equal 0 (limn/vertico:session-index s))))

(deftest vertico-s1-make-session-preserves-original-order
  "make-session 應保留原始候選順序（未過濾時）。"
  (let ((s (limn/vertico:make-session '("gamma" "alpha" "beta"))))
    (assert-equal "gamma" (first (limn/vertico:session-filtered-candidates s)))
    (assert-equal "alpha" (second (limn/vertico:session-filtered-candidates s)))
    (assert-equal "beta"  (third (limn/vertico:session-filtered-candidates s)))))

;;; ─── §2 session-update-input 過濾行為 ─────────────────────────────────

(deftest vertico-s2-update-input-filters
  "update-input('foo') 應過濾出含 'foo' 的候選。"
  (let ((s (limn/vertico:make-session '("foobar" "foobaz" "food" "barfoo" "alpha"))))
    (limn/vertico:session-update-input s "foo")
    (let ((filtered (limn/vertico:session-filtered-candidates s)))
      (assert-contains "foobar" filtered)
      (assert-contains "foobaz" filtered)
      (assert-contains "food"   filtered)
      (assert-contains "barfoo" filtered)
      (assert-false (find "alpha" filtered :test #'equal)
                    "alpha 不含 foo → 不應出現"))))

(deftest vertico-s2-update-input-empty-restores-all
  "update-input('') 應恢復所有候選。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-update-input s "foo") ; 先過濾到無匹配
    (limn/vertico:session-update-input s "")     ; 再清空
    (assert-equal 3 (length (limn/vertico:session-filtered-candidates s)))
    (assert-equal "alpha" (first (limn/vertico:session-filtered-candidates s)))))

(deftest vertico-s2-update-input-no-match-empty-filtered
  "update-input('不存在') 應回傳空 filtered-candidates。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-update-input s "xyzzy")
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s)))))

(deftest vertico-s2-update-input-resets-index
  "update-input 後 index 應重設為 0。"
  (let ((s (limn/vertico:make-session '("foobar" "foobaz" "food" "barfoo" "alpha"))))
    (limn/vertico:session-update-input s "foo")
    ;; 先往下移動
    (limn/vertico:session-move s 2)
    (assert-equal 2 (limn/vertico:session-index s))
    ;; 更新輸入 → index 歸零
    (limn/vertico:session-update-input s "bar")
    (assert-equal 0 (limn/vertico:session-index s))))

(deftest vertico-s2-update-input-resets-scroll
  "update-input 後 scroll-offset 應重設為 0。"
  (let ((s (limn/vertico:make-session
            '("a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9" "a10" "a11" "a12")
            :window-size 3)))
    (limn/vertico:session-update-input s "a")
    ;; 往下移動到 scroll 必須前進
    (limn/vertico:session-move s 11)
    (assert-true (> (limn/vertico:session-scroll-offset s) 0)
                 "scroll-offset 應已前進")
    ;; 更新輸入 → scroll 歸零
    (limn/vertico:session-update-input s "b")
    (assert-equal 0 (limn/vertico:session-scroll-offset s))))

;;; ─── §3 session-move 移動與 clamp ─────────────────────────────────────

(deftest vertico-s3-move-down-basic
  "session-move(+1) 應往下移動 index。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-move s 1)
    (assert-equal 1 (limn/vertico:session-index s))
    (limn/vertico:session-move s 1)
    (assert-equal 2 (limn/vertico:session-index s))))

(deftest vertico-s3-move-up-basic
  "session-move(-1) 應往上移動 index。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-move s 2)
    (assert-equal 2 (limn/vertico:session-index s))
    (limn/vertico:session-move s -1)
    (assert-equal 1 (limn/vertico:session-index s))))

(deftest vertico-s3-move-clamp-bottom
  "session-move(+N) 到底部應 clamp，不超出。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    ;; 嘗試移動超過末尾
    (limn/vertico:session-move s 10)
    (assert-equal 2 (limn/vertico:session-index s)
                  "index 應 clamp 在 len-1 = 2")
    ;; 再移動一次，仍不超出
    (limn/vertico:session-move s 5)
    (assert-equal 2 (limn/vertico:session-index s))))

(deftest vertico-s3-move-clamp-top
  "session-move(-1) 在 index=0 應停在 0，不 wrap。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (assert-equal 0 (limn/vertico:session-index s))
    (limn/vertico:session-move s -1)
    (assert-equal 0 (limn/vertico:session-index s)
                  "index=0 時 move(-1) 應停在 0")
    ;; 再移動一次，仍不變
    (limn/vertico:session-move s -5)
    (assert-equal 0 (limn/vertico:session-index s))))

(deftest vertico-s3-move-on-empty-filtered
  "session-move 在 filtered 為空時不應出錯。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-update-input s "xyzzy")
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s)))
    ;; move 應無作用，不報錯
    (limn/vertico:session-move s 1)
    (assert-equal 0 (limn/vertico:session-index s))
    (limn/vertico:session-move s -1)
    (assert-equal 0 (limn/vertico:session-index s))))

;;; ─── §4 session-visible 窗格內容 ──────────────────────────────────────

(deftest vertico-s4-visible-basic
  "session-visible 應回傳正確的 sublist 與相對索引。"
  (let ((s (limn/vertico:make-session
            '("a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9"
              "a10" "a11" "a12" "a13" "a14")
            :window-size 5)))
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-equal 5 (length visible)
                    "窗格應有 window-size 個項目")
      (assert-equal 0 rel-idx
                    "index=0 時相對索引為 0")
      (assert-equal "a0" (first visible))
      (assert-equal "a4" (fifth visible)))))

(deftest vertico-s4-visible-after-move
  "移動 index 後，visible 應更新相對索引。"
  (let ((s (limn/vertico:make-session
            '("a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9"
              "a10" "a11" "a12" "a13" "a14")
            :window-size 5)))
    (limn/vertico:session-move s 3)
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-equal 3 rel-idx
                    "index=3 時相對索引為 3（仍在第一頁）")
      (assert-equal "a3" (elt visible rel-idx)
                    "相對索引位置應是當前選中項"))))

(deftest vertico-s4-visible-window-smaller-than-filtered
  "當 filtered 數量少於 window-size 時，visible 應回傳全部。"
  (let ((s (limn/vertico:make-session '("alpha" "beta") :window-size 10)))
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-equal 2 (length visible)
                    "只有 2 個候選，窗格應回傳全部")
      (assert-equal 0 rel-idx))))

(deftest vertico-s4-visible-empty-filtered
  "當 filtered 為空時，visible 應回傳 (nil . 0)。"
  (let ((s (limn/vertico:make-session '("alpha" "beta"))))
    (limn/vertico:session-update-input s "xyzzy")
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-true (null visible)
                   "filtered 為空時 visible-candidates 應為 nil")
      (assert-equal 0 rel-idx))))

;;; ─── §5 session-current ───────────────────────────────────────────────

(deftest vertico-s5-current-basic
  "session-current 應回傳目前選中的候選字串。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (assert-equal "alpha" (limn/vertico:session-current s)
                  "初始 current = 第一個候選")
    (limn/vertico:session-move s 2)
    (assert-equal "gamma" (limn/vertico:session-current s))))

(deftest vertico-s5-current-nil-on-empty
  "filtered 為空時 current 應回傳 nil。"
  (let ((s (limn/vertico:make-session '("alpha" "beta"))))
    (limn/vertico:session-update-input s "xyzzy")
    (assert-false (limn/vertico:session-current s)
                  "無匹配時 current 為 nil")))

(deftest vertico-s5-current-after-update-input
  "update-input 後 current 應為排序後的第一個候選。"
  (let ((s (limn/vertico:make-session '("xfoobar" "foobar" "barfoo"))))
    (limn/vertico:session-update-input s "foo")
    (let ((cur (limn/vertico:session-current s)))
      (assert-true cur "應有 current")
      ;; "foobar" 分數最高（foo 在位置 0）→ 排第一
      (assert-equal "foobar" cur
                    "foo 在位置 0 的候選排最前"))))

;;; ─── §6 scroll-offset 滑動邏輯 ────────────────────────────────────────

(deftest vertico-s6-scroll-follows-index-down
  "index 超出窗格底部時，scroll-offset 應跟上。"
  (let ((s (limn/vertico:make-session
            '("a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9"
              "a10" "a11" "a12" "a13" "a14")
            :window-size 5)))
    ;; 初始 scroll=0
    (assert-equal 0 (limn/vertico:session-scroll-offset s))
    ;; 移動到 index=5（窗格 [0..4]，5 超出）
    (limn/vertico:session-move s 5)
    (assert-equal 1 (limn/vertico:session-scroll-offset s)
                  "index=5, window=5 → scroll 應前進到 1（使 index 在窗格最後一行）")
    ;; 移動到 index=9
    (limn/vertico:session-move s 4)
    (assert-equal 5 (limn/vertico:session-scroll-offset s)
                  "index=9, window=5 → scroll 應前進到 5")
    ;; 移動到 index=14（末尾）
    (limn/vertico:session-move s 5)
    (assert-equal 10 (limn/vertico:session-scroll-offset s)
                  "index=14, window=5 → scroll=10（窗格 [10..14]）")))

(deftest vertico-s6-scroll-follows-index-up
  "index 回到窗格前面時，scroll-offset 應減小。"
  (let ((s (limn/vertico:make-session
            '("a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9"
              "a10" "a11" "a12" "a13" "a14")
            :window-size 5)))
    ;; 先移動到 index=10
    (limn/vertico:session-move s 10)
    (assert-equal 6 (limn/vertico:session-scroll-offset s))
    ;; 往回移動到 index=3 → scroll 應跳回 index 位置
    (limn/vertico:session-move s -7)
    (assert-equal 3 (limn/vertico:session-scroll-offset s)
                  "index=3 小於舊 scroll=6 → scroll 應跳回 3")))

(deftest vertico-s6-scroll-stays-when-index-in-window
  "index 在窗格內移動時，scroll-offset 不應改變。"
  (let ((s (limn/vertico:make-session
            '("a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9"
              "a10" "a11" "a12" "a13" "a14")
            :window-size 5)))
    (assert-equal 0 (limn/vertico:session-scroll-offset s))
    (limn/vertico:session-move s 2)
    (assert-equal 0 (limn/vertico:session-scroll-offset s)
                  "index=2 仍在窗格 [0..4] 內，scroll 不動")
    (limn/vertico:session-move s 1)
    (assert-equal 0 (limn/vertico:session-scroll-offset s)
                  "index=3 仍在窗格內，scroll 不動")))

;;; ─── §7 邊界情況 ──────────────────────────────────────────────────────

(deftest vertico-s7-empty-all-candidates
  "空候選集：所有操作不應報錯。"
  (let ((s (limn/vertico:make-session '())))
    ;; 初始狀態
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s)))
    (assert-equal 0 (limn/vertico:session-index s))
    (assert-false (limn/vertico:session-current s))
    ;; update-input 不報錯
    (limn/vertico:session-update-input s "foo")
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s)))
    ;; move 不報錯
    (limn/vertico:session-move s 5)
    (assert-equal 0 (limn/vertico:session-index s))
    ;; visible 不報錯
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-true (null visible))
      (assert-equal 0 rel-idx))))

(deftest vertico-s7-window-larger-than-candidates
  "window-size > filtered 長度時，visible 回傳全部。"
  (let ((s (limn/vertico:make-session '("a" "b" "c") :window-size 100)))
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-equal 3 (length visible))
      (assert-equal 0 rel-idx))))

(deftest vertico-s7-no-match-current-nil
  "查詢無符合時，current 為 nil 且 filtered 為空。"
  (let ((s (limn/vertico:make-session '("one" "two" "three"))))
    (limn/vertico:session-update-input s "does-not-exist")
    (assert-equal 0 (length (limn/vertico:session-filtered-candidates s))
                  "filtered-candidates 應為空")
    (assert-false (limn/vertico:session-current s)
                  "current 應為 nil")))

(deftest vertico-s7-single-candidate
  "單一候選的各種操作。"
  (let ((s (limn/vertico:make-session '("only"))))
    (assert-equal "only" (limn/vertico:session-current s))
    ;; move 不超出
    (limn/vertico:session-move s 10)
    (assert-equal 0 (limn/vertico:session-index s))
    (limn/vertico:session-move s -10)
    (assert-equal 0 (limn/vertico:session-index s))
    ;; visible
    (destructuring-bind (visible . rel-idx) (limn/vertico:session-visible s)
      (assert-equal 1 (length visible))
      (assert-equal "only" (first visible))
      (assert-equal 0 rel-idx))))

(deftest vertico-s7-whitespace-only-input
  "純空白輸入應視為空輸入，回傳所有候選。"
  (let ((s (limn/vertico:make-session '("alpha" "beta" "gamma"))))
    (limn/vertico:session-update-input s "   ")
    (assert-equal 3 (length (limn/vertico:session-filtered-candidates s)))
    (assert-equal "alpha" (limn/vertico:session-current s))))

;;; ─── §8 整合測試：orderless multi-component ──────────────────────────

(deftest vertico-s8-orderless-integration-multi-component
  "orderless multi-component 'foo bar' 正確過濾。"
  (let ((s (limn/vertico:make-session
            '("foobar" "barfoo" "food" "bazqux" "foobaz" "alpha"))))
    (limn/vertico:session-update-input s "foo bar")
    (let ((filtered (limn/vertico:session-filtered-candidates s)))
      ;; 必須同時含 foo 與 bar
      (assert-contains "foobar" filtered
                       "foobar 同時含 foo 與 bar")
      (assert-contains "barfoo" filtered
                       "barfoo 同時含 foo 與 bar")
      ;; 不含 bar 的不應出現
      (assert-false (find "food" filtered :test #'equal)
                    "food 不含 bar → 不應出現")
      (assert-false (find "foobaz" filtered :test #'equal)
                    "foobaz 不含 bar → 不應出現")
      (assert-false (find "bazqux" filtered :test #'equal)
                    "bazqux 不含 foo → 不應出現")
      (assert-false (find "alpha" filtered :test #'equal)
                    "alpha 不含 foo/bar → 不應出現"))))

(deftest vertico-s8-orderless-integration-sorting
  "orderless 過濾後應依分數排序（最佳匹配在前）。"
  (let ((s (limn/vertico:make-session
            '("xfoobar" "foobar" "barxfoo" "barfoo"))))
    (limn/vertico:session-update-input s "foo bar")
    (let ((filtered (limn/vertico:session-filtered-candidates s)))
      (assert-true (> (length filtered) 1)
                   "應有多個匹配")
      ;; "foobar"（foo 在位置 0）應比 "xfoobar"（foo 在位置 1）排更前面
      ;; 因為 position bonus：位置 0 > 位置 1
      (let ((pos-foobar (position "foobar" filtered :test #'equal))
            (pos-xfoobar (position "xfoobar" filtered :test #'equal)))
        (assert-true (and pos-foobar pos-xfoobar)
                     "foobar 與 xfoobar 都應在結果中")
        (assert-true (< pos-foobar pos-xfoobar)
                     "foobar（foo 在 0）應排在 xfoobar（foo 在 1）前面")))))

(deftest vertico-s8-orderless-integration-empty-query-keeps-all
  "空查詢後再輸入，應正確在 orderless 過濾與全候選之間切換。"
  (let ((s (limn/vertico:make-session
            '("alpha" "beta" "gamma" "foobar" "barfoo" "food"))))
    ;; 空輸入 → 全部
    (limn/vertico:session-update-input s "")
    (assert-equal 6 (length (limn/vertico:session-filtered-candidates s)))
    ;; 輸入 'foo' → orderless 過濾
    (limn/vertico:session-update-input s "foo")
    (let ((filtered (limn/vertico:session-filtered-candidates s)))
      (assert-contains "foobar" filtered)
      (assert-contains "barfoo" filtered)
      (assert-contains "food" filtered)
      (assert-false (find "alpha" filtered :test #'equal)))
    ;; 再清空 → 恢復全部
    (limn/vertico:session-update-input s "")
    (assert-equal 6 (length (limn/vertico:session-filtered-candidates s)))))

;;; ─── §9 vertico-completing-read headless wrapper ──────────────────────

(deftest vertico-s9-vcr-basic
  "vertico-completing-read 在 headless 模式回傳最佳匹配。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("alpha" "foobar" "barfoo" "food" "beta")
                 :initial-input "foo")))
    ;; orderless-filter 後，分數高者在前。相同分數時短字串優先。
    ;; "food"（foo 在 0）與 "foobar"（foo 在 0）分數相同，但 "food"（4）比 "foobar"（6）短
    (assert-equal "food" result
                  "vertico-completing-read 回傳 orderless 排序後的第一個（短字串優先）")))

(deftest vertico-s9-vcr-empty-input
  "vertico-completing-read 空輸入回傳第一個候選。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("alpha" "beta" "gamma")
                 :initial-input "")))
    (assert-equal "alpha" result)))

(deftest vertico-s9-vcr-require-match-error
  "vertico-completing-read require-match + 無匹配 → error。"
  (assert-error error
    (limn/vertico:vertico-completing-read
     "Pick: " '("alpha" "beta")
     :initial-input "zzz" :require-match t)
    "require-match 且無匹配應報 error"))

(deftest vertico-s9-vcr-no-match-default
  "vertico-completing-read 無匹配 + default → 回傳 default。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("alpha" "beta")
                 :initial-input "zzz" :default "fallback")))
    (assert-equal "fallback" result)))

(deftest vertico-s9-vcr-predicate
  "vertico-completing-read 應套用 predicate。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("alpha" "apple" "beta")
                 :predicate (lambda (s) (char= (char s 0) #\a))
                 :initial-input "alp")))
    (assert-equal "alpha" result
                  "只有 a 開頭的候選，'alp' 應匹配 alpha")))

(deftest vertico-s9-vcr-no-match-no-require
  "vertico-completing-read 無匹配、不需 require → 回傳輸入本身。"
  (let ((result (limn/vertico:vertico-completing-read
                 "Pick: " '("alpha" "beta")
                 :initial-input "something-else")))
    (assert-equal "something-else" result)))
