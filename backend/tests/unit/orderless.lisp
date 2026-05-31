;;;; orderless.lisp — Orderless 比對引擎的 unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — component 切割（%split-components）
;;;;   §2 — 詞邊界偵測（%word-boundary-positions）
;;;;   §3 — 單一 style 比對（literal / flex / initialism / regexp / prefixes）
;;;;   §4 — orderless-match-p（任意順序多 component）
;;;;   §5 — orderless-filter（過濾 + 排序）
;;;;   §6 — orderless-filter-with-positions（含命中位置）
;;;;   §7 — 邊界情況（空輸入、大小寫、特殊字元）
;;;;
;;;; limn-orderless 已納入 ASDF（limn.asd），此處透過 run-unit.lisp 的
;;;; asdf:load-system 載入，不需手動 load。

(in-package #:limn/unit-test)

;;; ─── §1 component 切割 ──────────────────────────────────────────────

(deftest orderless-s1-split-simple
  "空白分隔的簡單切割。"
  (let ((parts (limn/orderless::%split-components "foo bar baz")))
    (assert-equal 3 (length parts))
    (assert-equal "foo" (first parts))
    (assert-equal "bar" (second parts))
    (assert-equal "baz" (third parts))))

(deftest orderless-s1-split-single
  "單一 component（無空白）。"
  (let ((parts (limn/orderless::%split-components "hello")))
    (assert-equal 1 (length parts))
    (assert-equal "hello" (first parts))))

(deftest orderless-s1-split-empty
  "空字串應回傳 nil。"
  (let ((parts (limn/orderless::%split-components "")))
    (assert-true (null parts) "空字串 → nil")))

(deftest orderless-s1-split-whitespace-only
  "純空白字串應回傳 nil。"
  (let ((parts (limn/orderless::%split-components "   ")))
    (assert-true (null parts) "純空白 → nil")))

(deftest orderless-s1-split-leading-trailing-spaces
  "前後空白應被忽略。"
  (let ((parts (limn/orderless::%split-components "  hello  world  ")))
    (assert-equal 2 (length parts))
    (assert-equal "hello" (first parts))
    (assert-equal "world" (second parts))))

;;; ─── §2 詞邊界偵測 ─────────────────────────────────────────────────

(deftest orderless-s2-boundaries-simple
  "簡單字串：開頭永遠是邊界。"
  (let ((b (limn/orderless::%word-boundary-positions "hello")))
    (assert-equal '(0) b)))

(deftest orderless-s2-boundaries-camel-case
  "camelCase：大寫字母開頭為新詞邊界。"
  (let ((b (limn/orderless::%word-boundary-positions "queryReplaceRegexp")))
    (assert-contains 0 b)
    (assert-contains 5 b)  ;; 'R' 位置
    (assert-contains 12 b))) ;; 第二個 'R' 位置

(deftest orderless-s2-boundaries-snake-case
  "snake_case：底線後為新詞邊界。"
  (let ((b (limn/orderless::%word-boundary-positions "query_replace_regexp")))
    (assert-contains 0 b)
    (assert-contains 6 b)  ;; 'r' after '_'
    (assert-contains 14 b))) ;; 'r' after '_'

(deftest orderless-s2-boundaries-kebab-case
  "kebab-case：連字號後為新詞邊界。"
  (let ((b (limn/orderless::%word-boundary-positions "query-replace-regexp")))
    (assert-contains 0 b)
    (assert-contains 6 b)  ;; 'r' after '-'
    (assert-contains 14 b))) ;; 'r' after '-'

(deftest orderless-s2-boundaries-empty
  "空字串回傳 nil。"
  (let ((b (limn/orderless::%word-boundary-positions "")))
    (assert-true (null b) "空字串 → nil")))

;;; ─── §3 單一 style 比對 ─────────────────────────────────────────────

;;; §3a — literal（子字串）

(deftest orderless-s3a-literal-basic
  "Literal：子字串匹配（大小寫無關）。"
  (let ((result (limn/orderless::%match-literal "bar" "foobar")))
    (assert-true result "bar 匹配 foobar")
    (assert-equal 3 (car result))
    (assert-equal 6 (cdr result))))

(deftest orderless-s3a-literal-case-insensitive
  "Literal：大小寫無關。"
  (let ((result (limn/orderless::%match-literal "BAR" "foobar")))
    (assert-true result "BAR 匹配 foobar（case-insensitive）")))

(deftest orderless-s3a-literal-no-match
  "Literal：無匹配應回傳 nil。"
  (let ((result (limn/orderless::%match-literal "xyz" "foobar")))
    (assert-false result "xyz 不匹配 foobar")))

;;; §3b — flex（字元依序）

(deftest orderless-s3b-flex-basic
  "Flex：字元依序出現。"
  (let ((result (limn/orderless::%match-flex "fb" "foobar")))
    (assert-true result "fb flex-matches foobar")
    (assert-equal 2 (length result))
    (assert-equal 0 (first result))   ;; 'f' at 0
    (assert-equal 3 (second result)))) ;; 'b' at 3

(deftest orderless-s3b-flex-adjacent
  "Flex：相鄰字元（= literal 特例）。"
  (let ((result (limn/orderless::%match-flex "foo" "foobar")))
    (assert-true result "foo flex-matches foobar")
    (assert-equal 3 (length result))))

(deftest orderless-s3b-flex-order-sensitive
  "Flex：字元順序重要。"
  (let ((result (limn/orderless::%match-flex "of" "foobar")))
    (assert-false result "of 不按順序匹配 foobar（o 在 f 之後沒有另一個 o→f）"))
  ;; 注意："foobar" 有 o 在 f 之後（位置 1），所以 'o' then 'f' 確實可以：
  ;; o at 1, f at... f 只在 0，沒有之後的 f。所以 of → o=1, f=none → nil
  ;; 正確：of 不匹配 foobar（因為 f 在 o 之前）
  )

(deftest orderless-s3b-flex-case-insensitive
  "Flex：大小寫無關。"
  (let ((result (limn/orderless::%match-flex "FB" "foobar")))
    (assert-true result "FB flex-matches foobar（case-insensitive）")))

(deftest orderless-s3b-flex-gapped
  "Flex：跳躍匹配。"
  (let ((result (limn/orderless::%match-flex "fbr" "foobar")))
    (assert-true result "fbr flex-matches foobar")
    (assert-equal 3 (length result))
    (assert-equal 0 (first result))   ;; 'f'
    (assert-equal 3 (second result))  ;; 'b'
    (assert-equal 5 (third result)))) ;; 'r'

;;; §3c — initialism（詞邊界首字母）

(deftest orderless-s3c-initialism-camel
  "Initialism：camelCase 首字母。"
  (let ((result (limn/orderless::%match-initialism "qrr" "queryReplaceRegexp")))
    (assert-true result "qrr initialism-matches queryReplaceRegexp")
    (assert-equal 3 (length result))))

(deftest orderless-s3c-initialism-snake
  "Initialism：snake_case 首字母。"
  (let ((result (limn/orderless::%match-initialism "qrr" "query_replace_regexp")))
    (assert-true result "qrr initialism-matches query_replace_regexp")
    (assert-equal 3 (length result))))

(deftest orderless-s3c-initialism-kebab
  "Initialism：kebab-case 首字母。"
  (let ((result (limn/orderless::%match-initialism "qrr" "query-replace-regexp")))
    (assert-true result "qrr initialism-matches query-replace-regexp")
    (assert-equal 3 (length result))))

(deftest orderless-s3c-initialism-case-insensitive
  "Initialism：大小寫無關。"
  (let ((result (limn/orderless::%match-initialism "QRR" "query_replace_regexp")))
    (assert-true result "QRR initialism-matches query_replace_regexp")))

(deftest orderless-s3c-initialism-no-match
  "Initialism：非邊界字元不匹配。"
  (let ((result (limn/orderless::%match-initialism "uer" "queryReplaceRegexp")))
    (assert-false result "uer 不作為 initialism 匹配 queryReplaceRegexp（u 是邊界但 e 不是）")))

;;; §3d — regexp

(deftest orderless-s3d-regexp-basic
  "Regexp：基本正則比對。"
  (let ((result (limn/orderless::%match-regexp "f[o]+bar" "foobar")))
    (assert-true result "regexp f[o]+bar 匹配 foobar")))

(deftest orderless-s3d-regexp-no-match
  "Regexp：不匹配。"
  (let ((result (limn/orderless::%match-regexp "^bar" "foobar")))
    (assert-false result "^bar 不匹配 foobar")))

(deftest orderless-s3d-regexp-invalid
  "Regexp：無效 regexp 應回 nil（不 crash）。"
  (let ((result (limn/orderless::%match-regexp "[invalid" "foobar")))
    (assert-false result "無效 regexp → nil")))

;;; §3e — prefixes（詞邊界前綴）

(deftest orderless-s3e-prefixes-basic
  "Prefixes：詞邊界前綴。"
  ;; "re" 是 "replace" 的前綴（在 query-replace-regexp 中位置 6）
  (let ((result (limn/orderless::%match-prefixes "re" "query-replace-regexp")))
    (assert-true result "re 是 replace 的邊界前綴")
    (assert-equal 6 (car result))
    (assert-equal 8 (cdr result))))

(deftest orderless-s3e-prefixes-simple
  "Prefixes：簡單前綴匹配。"
  (let ((result (limn/orderless::%match-prefixes "rep" "query-replace-regexp")))
    (assert-true result "rep 是 replace 的前綴")
    (assert-equal 6 (car result))    ;; 'r' at 6
    (assert-equal 9 (cdr result))))  ;; 'rep' = 6+3

(deftest orderless-s3e-prefixes-no-match
  "Prefixes：非詞邊界前綴不匹配。"
  (let ((result (limn/orderless::%match-prefixes "lace" "query-replace-regexp")))
    (assert-false result "lace 不是任何詞的邊界前綴")))

;;; ─── §4 orderless-match-p（多 component 任意順序）──────────────────

(deftest orderless-s4-single-component
  "單一 component：行為等同單一 style 比對。"
  (assert-true (limn/orderless:orderless-match-p "bar" "foobar"))
  (assert-false (limn/orderless:orderless-match-p "xyz" "foobar")))

(deftest orderless-s4-multi-component-all-match
  "多 component，全部匹配。"
  (assert-true (limn/orderless:orderless-match-p
                "foo bar" "foobar")
               "foo 與 bar 都匹配 foobar"))

(deftest orderless-s4-multi-component-any-order
  "多 component，任意順序都算匹配。"
  (assert-true (limn/orderless:orderless-match-p
                "bar foo" "foobar")
               "bar 與 foo 都匹配 foobar（順序不拘）"))

(deftest orderless-s4-multi-component-partial-fail
  "部分 component 不匹配 → 整體不匹配。"
  (assert-false (limn/orderless:orderless-match-p
                 "foo xyz" "foobar")
                "foo 匹配但 xyz 不匹配 → 整體失敗"))

(deftest orderless-s4-multi-component-none-match
  "全部 component 不匹配。"
  (assert-false (limn/orderless:orderless-match-p
                 "xyz abc" "foobar")
                "兩個都不匹配"))

(deftest orderless-s4-empty-query
  "空查詢匹配所有。"
  (assert-true (limn/orderless:orderless-match-p "" "anything")
               "空查詢匹配任何字串"))

(deftest orderless-s4-flex-multi-component
  "Flex style 多 component。"
  (assert-true (limn/orderless:orderless-match-p
                "fb ob" "foobar"
                :styles '(flex))
               "fb 與 ob 都 flex-match foobar"))

(deftest orderless-s4-mixed-styles
  "多種 style 混用。"
  (assert-true (limn/orderless:orderless-match-p
                "fbr bar" "foobar"
                :styles '(flex literal))
               "fbr flex-match + bar literal-match"))

;;; ─── §5 orderless-filter（過濾 + 排序）──────────────────────────────

(defparameter *sample-candidates*
  '("foobar" "foobaz" "food" "barfoo" "bazqux" "query-replace-regexp"
    "queryReplaceRegexp" "alpha" "alphabet" "alpine"))

(deftest orderless-s5-filter-basic
  "基本過濾：只回傳匹配的候選。"
  (let ((results (limn/orderless:orderless-filter
                  "foo" *sample-candidates*)))
    (assert-contains "foobar" results)
    (assert-contains "foobaz" results)
    (assert-contains "food" results)
    (assert-contains "barfoo" results)
    (assert-false (find "alpha" results :test #'equal))
    (assert-false (find "bazqux" results :test #'equal))))

(deftest orderless-s5-filter-multi-component
  "多 component 過濾。"
  (let ((results (limn/orderless:orderless-filter
                  "foo bar" *sample-candidates*)))
    (assert-contains "foobar" results)
    (assert-contains "barfoo" results)
    (assert-false (find "food" results :test #'equal)
                  "food 不含 bar → 不應出現")))

(deftest orderless-s5-filter-sorted
  "排序：分數高者在前。相同分數時短字串優先。"
  (let ((results (limn/orderless:orderless-filter
                  "foo" '("xfoox" "foobar" "foox" "xfoo"))))
    ;; "foox" 與 "foobar" 分數相同（foo 都在位置 0），
    ;; "foox"（4）比 "foobar"（6）短 → foox 排第一
    (assert-true (> (length results) 0))
    (assert-equal "foox" (first results)
                  "foo 在位置 0 且最短者排最前")))

(deftest orderless-s5-filter-empty-query
  "空查詢回傳所有候選（全部視為匹配）。"
  (let ((results (limn/orderless:orderless-filter
                  "" *sample-candidates*)))
    (assert-equal (length *sample-candidates*) (length results)
                  "空查詢回傳所有候選")))

;;; ─── §6 orderless-filter-with-positions ─────────────────────────────

(deftest orderless-s6-with-positions-basic
  "基本：回傳含位置的結果。"
  (let ((results (limn/orderless:orderless-filter-with-positions
                  "foo" '("foobar" "bazqux"))))
    (assert-equal 1 (length results))
    (let ((entry (first results)))
      (assert-equal "foobar" (getf entry :candidate))
      (assert-true (> (getf entry :score) 0) "分數 > 0")
      (let ((matches (getf entry :matches)))
        (assert-equal 1 (length matches))
        (let ((m (first matches)))
          (assert-equal "foo" (getf m :component))
          (assert-true (getf m :positions) "有位置資訊"))))))

(deftest orderless-s6-with-positions-multi-component
  "多 component：每個 component 都有對應的 match info。"
  (let ((results (limn/orderless:orderless-filter-with-positions
                  "foo bar" '("foobar" "barfoo"))))
    (assert-equal 2 (length results))
    ;; 檢查第一個結果
    (let ((entry (first results)))
      (assert-equal 2 (length (getf entry :matches))
                    "兩個 component 各有 match info"))))

;;; ─── §7 邊界情況 ────────────────────────────────────────────────────

(deftest orderless-s7-case-insensitive
  "大小寫無關（所有 style）。"
  (assert-true (limn/orderless:orderless-match-p "FOO" "foobar"))
  (assert-true (limn/orderless:orderless-match-p "QRR" "queryReplaceRegexp"
                :styles '(initialism)))
  (assert-true (limn/orderless:orderless-match-p "FB" "FooBar"
                :styles '(flex))))

(deftest orderless-s7-unicode-basic
  "基本 Unicode 支援（中文、重音符號）。"
  ;; Literal: 子字串
  (assert-true (limn/orderless:orderless-match-p "é" "café"))
  ;; Flex
  (assert-true (limn/orderless:orderless-match-p "cf" "café"
                :styles '(flex))))

(deftest orderless-s7-special-regex-chars-as-literal
  "特殊 regex 字元在 literal style 下應視為普通字元。"
  (assert-true (limn/orderless:orderless-match-p
                "." "foo.bar" :styles '(literal))
               ". 在 literal style 應匹配 ."))

(deftest orderless-s7-identical-matches
  "相同候選出現多次會各自匹配（orderless 不做 dedup，由 caller 處理）。"
  (let ((results (limn/orderless:orderless-filter
                  "foo" '("foobar" "foobar" "baz"))))
    ;; orderless 不做 dedup：兩個 "foobar" 都會匹配
    (assert-equal 2 (count "foobar" results :test #'equal)
                  "重複候選各自匹配（caller 負責 dedup）")))

;;; ─── §8 整合：與 completion 既有的 complete-with-styles 的對比 ─────

(deftest orderless-s8-vs-completion-styles
  "Orderless 多 component 是 completion single-style 的超集。
   單一 component 的行為應與 complete-with-styles 一致。"
  (let* ((candidates '("foobar" "baz" "rebar"))
         (comp-result (limn/completion:complete-with-styles
                       "bar" candidates '(substring)))
         (orderless-result (limn/orderless:orderless-filter
                            "bar" candidates :styles '(literal))))
    (assert-equal (length comp-result) (length orderless-result)
                  "單一 component literal 應與 substring style 一致")
    (dolist (c comp-result)
      (assert-contains c orderless-result))))

(deftest orderless-s8-flex-vs-completion-flex
  "Orderless flex 單 component 應與 completion flex 一致。"
  (let* ((candidates '("foobar" "baz" "fab"))
         (comp-result (limn/completion:complete-with-styles
                       "fb" candidates '(flex)))
         (orderless-result (limn/orderless:orderless-filter
                            "fb" candidates :styles '(flex))))
    (assert-equal (length comp-result) (length orderless-result)
                  "單一 component flex 應與 completion flex 一致")
    (dolist (c comp-result)
      (assert-contains c orderless-result))))
