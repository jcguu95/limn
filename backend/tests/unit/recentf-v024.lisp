;;;; v0.24 §H — recentf RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/recentf : *recentf-list* / *recentf-max-saved-items*
;;;;                  *recentf-save-file*
;;;;                  recentf-push / recentf-save / recentf-load
;;;;                  recentf-open / recentf-clear / recentf-remove
;;;;
;;;; 全部 RED — 在 limn-recentf.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/recentf)
    (make-package '#:limn/recentf :use '(#:cl)))
  (dolist (sym '("*RECENTF-LIST*"
                 "*RECENTF-MAX-SAVED-ITEMS*"
                 "*RECENTF-SAVE-FILE*"
                 "RECENTF-PUSH"
                 "RECENTF-SAVE"
                 "RECENTF-LOAD"
                 "RECENTF-OPEN"
                 "RECENTF-CLEAR"
                 "RECENTF-REMOVE"
                 ;; I/O vtable
                 "*RECENTF-WRITE-FN*"
                 "*RECENTF-READ-FN*"
                 "*FIND-FILE-FN*"))
    (export (intern sym '#:limn/recentf) '#:limn/recentf)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defmacro with-recentf-env ((&key (max 50) (initial-list '())) &body body)
  "Fresh recentf state + virtual I/O for each test."
  `(let ((limn/recentf:*recentf-list*           (copy-list ,initial-list))
         (limn/recentf:*recentf-max-saved-items* ,max)
         (limn/recentf:*recentf-save-file*       "/tmp/test-recentf.lisp"))
     (let ((vdisk (make-hash-table :test #'equal)))
       (let ((limn/recentf:*recentf-write-fn*
               (lambda (path content)
                 (setf (gethash path vdisk) content)))
             (limn/recentf:*recentf-read-fn*
               (lambda (path)
                 (gethash path vdisk nil)))
             (limn/recentf:*find-file-fn*
               (lambda (path) (declare (ignore path)))))
         ,@body))))

;;; ── H1. recentf-push ──────────────────────────────────────────────────────

(deftest recentf-h1-push-new-path
  "push 新 path 出現在 *recentf-list* 最前面。"
  (with-recentf-env ()
    (limn/recentf:recentf-push "/tmp/foo.txt")
    (assert-equal "/tmp/foo.txt" (car limn/recentf:*recentf-list*)
                  "new path at front of list")))

(deftest recentf-h1-push-duplicate-moves-to-top
  "push 已在 list 中的 path 移到頂端（不增加長度）。"
  (with-recentf-env (:initial-list '("/a" "/b" "/c"))
    (limn/recentf:recentf-push "/b")
    (assert-equal "/b" (car limn/recentf:*recentf-list*)
                  "duplicate moved to front")
    (assert-eql 3 (length limn/recentf:*recentf-list*)
                "length unchanged")))

(deftest recentf-h1-push-over-max-trims-list
  "push 超過 *recentf-max-saved-items* 時截掉最舊。"
  (with-recentf-env (:max 3
                     :initial-list '("/1" "/2" "/3"))
    (limn/recentf:recentf-push "/4")
    (assert-eql 3 (length limn/recentf:*recentf-list*)
                "list stays at max length")
    (assert-equal "/4" (car limn/recentf:*recentf-list*)
                  "newest at front")))

(deftest recentf-h1-push-nil-no-op
  "push nil 是 no-op（不 error、不加 nil 進 list）。"
  (with-recentf-env ()
    (assert-no-error (limn/recentf:recentf-push nil))
    (assert-false (member nil limn/recentf:*recentf-list*)
                  "nil not in list")))

(deftest recentf-h1-push-returns-updated-list-or-nil
  "push 後 *recentf-list* 是合法 list。"
  (with-recentf-env ()
    (limn/recentf:recentf-push "/tmp/a.lisp")
    (assert-true (listp limn/recentf:*recentf-list*)
                 "result is a list")))

;;; ── H2. recentf-save / recentf-load ──────────────────────────────────────

(deftest recentf-h2-save-calls-write-fn
  "recentf-save 呼叫 *recentf-write-fn* 一次。"
  (with-recentf-env (:initial-list '("/tmp/a.txt"))
    (let ((write-count 0))
      (let ((limn/recentf:*recentf-write-fn*
              (lambda (path content)
                (declare (ignore path content))
                (incf write-count))))
        (limn/recentf:recentf-save)
        (assert-eql 1 write-count "write-fn called once")))))

(deftest recentf-h2-load-calls-read-fn
  "recentf-load 呼叫 *recentf-read-fn*。"
  (with-recentf-env ()
    (let ((read-called nil))
      (let ((limn/recentf:*recentf-read-fn*
              (lambda (path)
                (declare (ignore path))
                (setf read-called t)
                nil)))
        (limn/recentf:recentf-load)
        (assert-true read-called "read-fn called during load")))))

(deftest recentf-h2-save-load-roundtrip
  "save 後 load 讀回的 list 與 save 前相同。"
  (with-recentf-env (:initial-list '("/a" "/b" "/c"))
    (limn/recentf:recentf-save)
    (let ((saved-list limn/recentf:*recentf-list*))
      (setf limn/recentf:*recentf-list* '())
      (limn/recentf:recentf-load)
      (assert-equal saved-list limn/recentf:*recentf-list*
                    "list restored after save/load"))))

(deftest recentf-h2-load-nonexistent-sidecar-no-op
  "sidecar 不存在時 recentf-load 是 no-op（不 error）。"
  (with-recentf-env ()
    ;; read-fn returns nil = file not found
    (assert-no-error (limn/recentf:recentf-load))
    (assert-true (null limn/recentf:*recentf-list*)
                 "list remains empty when no sidecar")))

;;; ── H3. recentf-open ──────────────────────────────────────────────────────

(deftest recentf-h3-open-n1-calls-find-file
  "recentf-open n=1 呼叫 find-file-fn 開第一個 path。"
  (with-recentf-env (:initial-list '("/first.txt" "/second.txt"))
    (let ((opened nil))
      (let ((limn/recentf:*find-file-fn*
              (lambda (path) (setf opened path))))
        (limn/recentf:recentf-open 1)
        (assert-equal "/first.txt" opened
                      "opened first path")))))

(deftest recentf-h3-open-n2-selects-second
  "recentf-open n=2 開第二個 path。"
  (with-recentf-env (:initial-list '("/first.txt" "/second.txt"))
    (let ((opened nil))
      (let ((limn/recentf:*find-file-fn*
              (lambda (path) (setf opened path))))
        (limn/recentf:recentf-open 2)
        (assert-equal "/second.txt" opened
                      "opened second path")))))

(deftest recentf-h3-open-n-out-of-range-no-error
  "n 超出 list 長度不 error。"
  (with-recentf-env (:initial-list '("/only.txt"))
    (assert-no-error (limn/recentf:recentf-open 99))))

(deftest recentf-h3-open-empty-list-no-error
  "list 為空時 recentf-open 不 error。"
  (with-recentf-env ()
    (assert-no-error (limn/recentf:recentf-open 1))))

;;; ── H4. recentf-remove ────────────────────────────────────────────────────

(deftest recentf-h4-remove-matching-paths
  "recentf-remove 移除符合 predicate 的 path。"
  (with-recentf-env (:initial-list '("/keep.txt" "/remove.txt" "/keep2.txt"))
    (limn/recentf:recentf-remove
      (lambda (p) (search "remove" p)))
    (assert-false (member "/remove.txt" limn/recentf:*recentf-list*
                          :test #'equal)
                  "matching path removed")
    (assert-true  (member "/keep.txt" limn/recentf:*recentf-list*
                          :test #'equal)
                  "non-matching path kept")))

(deftest recentf-h4-remove-nonexistent-no-error
  "predicate 不匹配任何項目時 no-op（不 error）。"
  (with-recentf-env (:initial-list '("/a.txt" "/b.txt"))
    (assert-no-error
      (limn/recentf:recentf-remove
        (lambda (p) (search "zzz" p))))
    (assert-eql 2 (length limn/recentf:*recentf-list*)
                "list unchanged")))

(deftest recentf-h4-remove-updates-length
  "remove 後 list 長度減少正確數量。"
  (with-recentf-env (:initial-list '("/del1.txt" "/del2.txt" "/keep.txt"))
    (limn/recentf:recentf-remove
      (lambda (p) (search "del" p)))
    (assert-eql 1 (length limn/recentf:*recentf-list*)
                "two paths removed")))

;;; ── H5. LRU 語義 ──────────────────────────────────────────────────────────

(deftest recentf-h5-most-recent-at-front
  "最近 push 的 path 在 list 最前。"
  (with-recentf-env ()
    (limn/recentf:recentf-push "/old.txt")
    (limn/recentf:recentf-push "/newer.txt")
    (limn/recentf:recentf-push "/newest.txt")
    (assert-equal "/newest.txt" (car limn/recentf:*recentf-list*)
                  "most recent at front")))

(deftest recentf-h5-max-truncation-keeps-newest
  "max 截斷保留最新項目（不保留最舊）。"
  (with-recentf-env (:max 2)
    (limn/recentf:recentf-push "/old.txt")
    (limn/recentf:recentf-push "/newer.txt")
    (limn/recentf:recentf-push "/newest.txt")
    (assert-eql 2 (length limn/recentf:*recentf-list*)
                "capped at max")
    (assert-false (member "/old.txt" limn/recentf:*recentf-list*
                          :test #'equal)
                  "oldest dropped")))

(deftest recentf-h5-dedup-no-extra-slots
  "重複 push 同一 path 不增加 list 長度。"
  (with-recentf-env (:max 5)
    (dotimes (_ 10)
      (limn/recentf:recentf-push "/same.txt"))
    (assert-eql 1 (length limn/recentf:*recentf-list*)
                "deduplicated: only one entry")))
