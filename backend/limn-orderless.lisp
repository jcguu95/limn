;;;; limn-orderless — Orderless 比對引擎（minad orderless 的 Lisp 等價實作）
;;;;
;;;; 演算法核心（照抄 minad orderless）：
;;;;   1. 把使用者輸入用空白切成 components。
;;;;   2. 每個 component 都必須匹配候選字串（任意順序、全部要中）。
;;;;   3. 每個 component 支援多種 matching style：
;;;;      - literal：子字串
;;;;      - flex：字元依序但可不連續（abc → a.*b.*c）
;;;;      - initialism：每字元對到詞邊界首字母（abc → \<a.*\<b.*\<c）
;;;;      - regexp：當正則（無效就忽略）
;;;;      - prefixes：詞邊界前綴（re-re 匹配 query-replace-regexp）
;;;;
;;;; 輸出：過濾後並排序的候選（含命中位置，供之後高亮）。
;;;; 純後端、headless 可驗。前端垂直渲染（Vertico）留增量。

(defpackage #:limn/orderless
  (:use #:cl)
  (:export #:orderless-match-p
           #:orderless-filter
           #:orderless-filter-with-positions
           #:*orderless-styles*
           #:orderless-score))

(in-package #:limn/orderless)

;;; ─── 可設定的 style 集合 ────────────────────────────────────────────

(defvar *orderless-styles* '(literal flex initialism)
  "預設啟用的 matching style 清單。
   可為 symbol 或 string：literal, flex, initialism, regexp, prefixes。")

;;; ─── 工具函式 ───────────────────────────────────────────────────────

(defun %split-components (query)
  "把 QUERY 用空白字元切開，回傳 component 字串 list。
   多餘空白忽略；空字串回 nil。"
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline) query)))
    (when (plusp (length trimmed))
      (let ((parts '())
            (start 0)
            (len (length trimmed)))
        (loop for i from 0 below len
              when (member (char trimmed i) '(#\Space #\Tab #\Newline))
                do (when (> i start)
                     (push (subseq trimmed start i) parts))
                   (setf start (1+ i)))
        (when (> len start)
          (push (subseq trimmed start len) parts))
        (nreverse parts)))))

(defun %word-boundary-positions (candidate)
  "回傳 CANDIDATE 字串中所有「詞邊界」位置（0-based index）的 list。
   詞邊界定義：
   - 字串開頭（位置 0）
   - 接在非字母數字字元後的第一個字母數字字元
   - 大小寫轉換處（camelCase：小寫→大寫視為新詞開頭）
   - 數字→字母、字母→數字轉換處"
  (let ((positions '(0))
        (len (length candidate)))
    (when (zerop len) (return-from %word-boundary-positions nil))
    (loop for i from 1 below len
          for prev = (char candidate (1- i))
          for curr = (char candidate i)
          when (or ;; 前一個字元不是字母數字
                   (not (alphanumericp prev))
                   ;; 小寫→大寫（camelCase）
                   (and (lower-case-p prev) (upper-case-p curr))
                   ;; 數字→字母
                   (and (digit-char-p prev) (alpha-char-p curr))
                   ;; 字母→數字
                   (and (alpha-char-p prev) (digit-char-p curr)))
            do (when (alphanumericp curr)
                 (push i positions)))
    (nreverse positions)))

;;; ─── 各 style 的 component-level 比對 ───────────────────────────────

(defun %match-literal (component candidate)
  "Literal（子字串）比對：case-insensitive substring search。
   回傳 (start . end) 或 nil。"
  (let ((ci-comp (string-downcase component))
        (ci-cand (string-downcase candidate)))
    (let ((pos (search ci-comp ci-cand)))
      (when pos
        (cons pos (+ pos (length ci-comp)))))))

(defun %match-flex (component candidate)
  "Flex 比對：component 的每個字元依序出現在 candidate 中（可不連續）。
   回傳 positions list（每個對到的位置）或 nil。"
  (let ((pos 0)
        (positions '())
        (ci-comp (string-downcase component))
        (ci-cand (string-downcase candidate)))
    (dolist (ch (coerce ci-comp 'list))
      (let ((found (position ch ci-cand :start pos)))
        (unless found (return-from %match-flex nil))
        (push found positions)
        (setf pos (1+ found))))
    (setf positions (nreverse positions))
    positions))

(defun %match-initialism (component candidate)
  "Initialism 比對：component 的每個字元依序對到 candidate 的詞邊界。
   回傳 positions list 或 nil。"
  (let* ((boundaries (%word-boundary-positions candidate))
         (ci-comp (string-downcase component))
         (ci-cand (string-downcase candidate))
         (boundary-set (make-hash-table :test #'eql)))
    ;; 建立邊界位置集合供快速查詢
    (dolist (b boundaries) (setf (gethash b boundary-set) t))
    (let ((pos 0)
          (positions '()))
      (dolist (ch (coerce ci-comp 'list))
        ;; 從目前位置往後找下一個邊界字元
        (loop
          (when (>= pos (length ci-cand))
            (return-from %match-initialism nil))
          (when (and (gethash pos boundary-set)
                     (char-equal ch (char ci-cand pos)))
            (push pos positions)
            (setf pos (1+ pos))
            (return))
          (incf pos)))
      (nreverse positions))))

(defun %match-regexp (component candidate)
  "Regexp 比對：把 component 當成正則表達式。
   依賴 cl-ppcre；若無效 regexp 則回 nil（忽略）。"
  (let ((ppkg (find-package '#:cl-ppcre)))
    (unless ppkg (return-from %match-regexp nil))
    (let ((scan-sym (find-symbol "SCAN" ppkg)))
      (unless (and scan-sym (fboundp scan-sym))
        (return-from %match-regexp nil))
      (handler-case
          (multiple-value-bind (start end)
              (funcall scan-sym component candidate)
            (when start
              (cons start end)))
        (error () nil)))))

(defun %match-prefixes (component candidate)
  "Prefixes 比對：component 必須是 candidate 中某個詞的前綴。
   在每個詞邊界處檢查 component 是否為該處開始的子字串前綴。
   回傳 (start . end) 或 nil。"
  (let* ((boundaries (%word-boundary-positions candidate))
         (ci-comp (string-downcase component))
         (ci-cand (string-downcase candidate))
         (comp-len (length ci-comp))
         (cand-len (length ci-cand)))
    (dolist (b boundaries)
      (when (and (<= (+ b comp-len) cand-len)
                 (string= ci-comp ci-cand
                          :start2 b :end2 (+ b comp-len)))
        (return-from %match-prefixes (cons b (+ b comp-len)))))
    nil))

;;; ─── component 比對調度 ─────────────────────────────────────────────

(defun %match-component (component candidate styles)
  "用 STYLES 中的任何一個 style 去比對 COMPONENT 與 CANDIDATE。
   回傳 (values positions style-name) 或 nil。"
  (dolist (style styles)
    (let* ((name (string-downcase (if (symbolp style)
                                      (symbol-name style)
                                      (string style))))
           (positions
             (cond
               ((string= name "literal")    (%match-literal component candidate))
               ((string= name "flex")       (%match-flex component candidate))
               ((string= name "initialism") (%match-initialism component candidate))
               ((string= name "regexp")     (%match-regexp component candidate))
               ((string= name "prefixes")   (%match-prefixes component candidate))
               (t nil))))
      (when positions
        (return-from %match-component (values positions style)))))
  nil)

;;; ─── 計分 ───────────────────────────────────────────────────────────

(defun orderless-score (query candidate &key (styles *orderless-styles*))
  "計算 QUERY 對 CANDIDATE 的匹配分數。
   分數愈高表示匹配品質愈好（用於排序）。
   分數計算原則：
   - 每個 component 都必須匹配（否則分數為 0）
   - 連續匹配（literal） > flex > initialism
   - 匹配位置愈集中愈好（gap penalty）
   - 愈早匹配愈好（position bonus）"
  (let ((components (%split-components query)))
    (when (null components)
      (return-from orderless-score 0))
    (let ((total-score 0)
          (all-positions '()))
      (dolist (comp components)
        (multiple-value-bind (positions matched-style)
            (%match-component comp candidate styles)
          (unless positions
            (return-from orderless-score 0))
          ;; 依 style 給基礎分
          (let* ((style-name (string-downcase
                              (if (symbolp matched-style)
                                  (symbol-name matched-style)
                                  (string matched-style))))
                 (base (cond
                         ((string= style-name "literal")    100)
                         ((string= style-name "flex")        60)
                         ((string= style-name "initialism")  40)
                         ((string= style-name "prefixes")    80)
                         ((string= style-name "regexp")      50)
                         (t 30)))
                 ;; gap penalty：連續匹配不扣分，有 gap 才扣
                 ;; positions 可能是 dotted pair (start . end) 或 proper list
                 (flat-positions (if (numberp (cdr positions))
                                     ;; dotted pair: literal/regexp/prefixes
                                     (let ((s (car positions))
                                           (e (cdr positions)))
                                       (loop for i from s below e collect i))
                                     ;; proper list: flex/initialism
                                     positions))
                 (gaps 0))
            (loop for i from 1 below (length flat-positions)
                  for prev = (nth (1- i) flat-positions)
                  for curr = (nth i flat-positions)
                  when (> (- curr prev) 1)
                    do (incf gaps))
            ;; postion bonus：第一個匹配位置愈前面愈好
            (let ((first-pos (first flat-positions)))
              (incf total-score
                    (+ base
                       (* -2 gaps)           ; gap penalty
                       (max 0 (- 20 first-pos)))) ; position bonus（愈前面愈高分）
              ;; 收集所有位置
              (dolist (p flat-positions) (push p all-positions))))))
      ;; 計入匹配長度（component 總長度）：長 query 匹配成功給額外獎勵
      (incf total-score (* 5 (length query)))
      ;; 位置集中度獎勵：所有匹配位置跨度愈小愈好
      (when all-positions
        (let* ((sorted (sort (copy-list all-positions) #'<))
               (span (- (first (last sorted)) (first sorted))))
          (incf total-score (max 0 (- 50 span)))))
      total-score)))

;;; ─── 主要 API ───────────────────────────────────────────────────────

(defun orderless-match-p (query candidate &key (styles *orderless-styles*))
  "檢查 QUERY 是否匹配 CANDIDATE（orderless 任意順序多 component 比對）。
   回傳 t 或 nil。空查詢匹配任何字串。"
  (let ((components (%split-components query)))
    (when (null components)
      (return-from orderless-match-p t))
    (every (lambda (comp)
             (%match-component comp candidate styles))
           components)))

(defun orderless-filter (query candidates &key (styles *orderless-styles*))
  "過濾並排序 CANDIDATES。
   回傳匹配的 candidate 字串 list，依分數降冪排序。
   空查詢回傳所有候選（視為全部匹配）。"
  (when (or (null query) (zerop (length (string-trim '(#\Space #\Tab #\Newline) query))))
    (return-from orderless-filter (copy-list candidates)))
  (let ((scored
          (loop for c in candidates
                for score = (orderless-score query c :styles styles)
                when (> score 0)
                  collect (cons c score))))
    ;; 依分數降冪、相同分數依字串長度升冪（短優先）、再依字母序
    (mapcar #'car
            (sort scored
                  (lambda (a b)
                    (let ((sa (cdr a)) (sb (cdr b)))
                      (cond
                        ((> sa sb) t)
                        ((< sa sb) nil)
                        (t (let ((la (length (car a))) (lb (length (car b))))
                             (cond
                               ((< la lb) t)
                               ((> la lb) nil)
                               (t (string-lessp (car a) (car b)))))))))))))

(defun orderless-filter-with-positions (query candidates
                                        &key (styles *orderless-styles*))
  "過濾並排序 CANDIDATES，同時回傳每個 component 的匹配位置（供高亮）。
   回傳格式：
     ((:candidate \"str\" :score N
       :matches ((:component \"comp1\" :style flex :positions (p1 p2 ...))
                 (:component \"comp2\" :style literal :positions (start . end))
                 ...))
      ...)"
  (let* ((components (%split-components query))
         (scored '()))
    (when (null components)
      (return-from orderless-filter-with-positions
        (mapcar (lambda (c)
                  (list :candidate c :score 0 :matches nil))
                candidates)))
    (dolist (c candidates)
      (let ((all-matches '())
            (total-score 0)
            (all-ok t))
        (dolist (comp components)
          (multiple-value-bind (positions matched-style)
              (%match-component comp c styles)
            (if positions
                (let* ((style-name (string-downcase
                                    (if (symbolp matched-style)
                                        (symbol-name matched-style)
                                        (string matched-style))))
                       (pos-list (if (numberp (cdr positions))
                                     ;; dotted pair: literal/regexp/prefixes
                                     (let ((s (car positions))
                                           (e (cdr positions)))
                                       (loop for i from s below e collect i))
                                     ;; proper list: flex/initialism — already a list
                                     positions))
                       (flat pos-list)
                       (base (cond
                               ((string= style-name "literal")    100)
                               ((string= style-name "flex")        60)
                               ((string= style-name "initialism")  40)
                               ((string= style-name "prefixes")    80)
                               ((string= style-name "regexp")      50)
                               (t 30)))
                       (gaps 0))
                  (loop for i from 1 below (length flat)
                        for prev = (nth (1- i) flat)
                        for curr = (nth i flat)
                        when (> (- curr prev) 1)
                          do (incf gaps))
                  (let ((first-pos (first flat)))
                    (incf total-score
                          (+ base
                             (* -2 gaps)
                             (max 0 (- 20 first-pos)))))
                  (push (list :component comp
                              :style matched-style
                              :positions positions
                              :flat-positions flat)
                        all-matches))
                (progn
                  (setf all-ok nil)
                  (return)))))
        (when all-ok
          (incf total-score (* 5 (length query)))
          ;; span bonus
          (let ((all-pos
                  (loop for m in all-matches
                        append (getf m :flat-positions))))
            (when all-pos
              (let* ((sorted (sort (copy-list all-pos) #'<))
                     (span (- (first (last sorted)) (first sorted))))
                (incf total-score (max 0 (- 50 span))))))
          ;; 移除內部 flat-positions（不暴露給 caller）
          (dolist (m all-matches)
            (remf m :flat-positions))
          (push (list :candidate c
                      :score total-score
                      :matches (nreverse all-matches))
                scored))))
    ;; 排序
    (setf scored
          (sort scored
                (lambda (a b)
                  (let ((sa (getf a :score))
                        (sb (getf b :score)))
                    (cond
                      ((> sa sb) t)
                      ((< sa sb) nil)
                      (t (let ((la (length (getf a :candidate)))
                               (lb (length (getf b :candidate))))
                           (cond
                             ((< la lb) t)
                             ((> la lb) nil)
                             (t (string-lessp (getf a :candidate)
                                             (getf b :candidate)))))))))))
    scored))
