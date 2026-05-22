;;;; Buffer editing tests — SPEC v0.5 §5.3 後段
;;;;
;;;; cursor / insert / delete 是 text engine 的 SHOULD 實作。所有 text-
;;;; engine buffer（user 開的、chrome 的）共用同一套協議。mupdf 之類非
;;;; 編輯型 engine 對這些指令一律回 "not supported"。
;;;;
;;;; 本檔在 v0.8 batch「Buffer editing」實作前全部紅。

(in-package #:limn/test)

(defmacro with-text-buffer ((var) &body body)
  "Open a text-engine buffer for the duration of BODY."
  (let ((r (gensym)))
    `(let* ((,r (send! "bridge/engine-load"
                       :|win-id| "w1" :|engine| "text" :|path| ""))
            (,var (json-get* ,r :|data| :|buffer-id|)))
       (unwind-protect (progn ,@body)
         (when ,var (ignore-errors (send! "buffer/close" :|buffer-id| ,var)))))))

;;; ── cursor ────────────────────────────────────────────────────────────

(deftest test-buffer-cursor-get-fresh-buffer
  "Fresh text buffer has cursor at offset 0."
  (with-text-buffer (buf)
    (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
      (assert-ok r)
      (assert-equal 0 (json-get* r :|data| :|offset|)))))

(deftest test-buffer-cursor-set-and-get-roundtrip
  "cursor-set then cursor-get returns the set value."
  (with-text-buffer (buf)
    ;; Set up some text so offset 3 is valid.
    (send! "buffer/insert" :|buffer-id| buf :|text| "abcdef")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 3)
    (assert-equal 3
                  (json-get* (send! "buffer/cursor-get" :|buffer-id| buf)
                             :|data| :|offset|))))

(deftest test-buffer-cursor-set-out-of-range-fails
  "Setting cursor beyond buffer length fails."
  (with-text-buffer (buf)
    (let ((r (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 999)))
      (assert-fail r "cursor past end rejected"))))

;;; ── insert ────────────────────────────────────────────────────────────

(deftest test-buffer-insert-at-cursor-advances-cursor
  "insert without :at writes at cursor and advances it by text length."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello")
    (assert-equal 5
                  (json-get* (send! "buffer/cursor-get" :|buffer-id| buf)
                             :|data| :|offset|))))

(deftest test-buffer-insert-at-explicit-offset
  "insert :at OFFSET inserts there; cursor stays at its existing place
   if cursor was BEFORE the inserted region; cursor shifts if it was
   AFTER the inserted region."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "world")    ; cursor=5
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "hello-")
    ;; Cursor was at 5 (end of "world"), insert "hello-" (6 chars) at offset
    ;; 0 — cursor was AFTER insertion, so shifts by 6 → new cursor = 11.
    (assert-equal 11
                  (json-get* (send! "buffer/cursor-get" :|buffer-id| buf)
                             :|data| :|offset|))))

(deftest test-buffer-insert-content-readable-via-buffer-text
  "After insert, buffer/text returns the inserted content."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "the quick brown")
    (let ((r (send! "buffer/text" :|buffer-id| buf)))
      (assert-ok r "buffer/text on text buffer works")
      ;; Either {text: "..."} or {words: [...]} — accept either shape;
      ;; the v0.8 implementation gets to pick (and SPEC will amend).
      (let ((d (getf r :|data|)))
        (assert-true (or (search "quick" (or (getf d :|text|) ""))
                          (find "quick"
                                (mapcar (lambda (w) (getf w :|text|))
                                        (getf d :|words|))
                                :test #'string=))
                     "inserted text retrievable")))))

;;; ── delete ────────────────────────────────────────────────────────────

(deftest test-buffer-delete-range-removes-content
  "delete from..to removes the slice [from, to)."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (send! "buffer/delete" :|buffer-id| buf :|from| 5 :|to| 11)   ; remove " world"
    (let* ((r (send! "buffer/text" :|buffer-id| buf))
           (d (getf r :|data|))
           (content (or (getf d :|text|)
                        (apply #'concatenate 'string
                               (mapcar (lambda (w) (getf w :|text|))
                                       (getf d :|words|))))))
      (assert-equal "hello" content "after delete, only 'hello' remains"))))

(deftest test-buffer-delete-invalid-range-fails
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "abc")
    (let ((r (send! "buffer/delete" :|buffer-id| buf :|from| 5 :|to| 99)))
      (assert-fail r "range past end rejected"))))

;;; ── not-supported on mupdf ────────────────────────────────────────────

(deftest test-buffer-edit-not-supported-on-mupdf
  "mupdf (readonly) rejects edit commands with a clean error."
  (with-buffer (mupdf-buf)
    (dolist (cmd '("buffer/cursor-set" "buffer/insert" "buffer/delete"))
      (let ((r (send! cmd :|buffer-id| mupdf-buf
                          :|offset| 0 :|text| "x"
                          :|from| 0 :|to| 1)))
        (assert-fail r (format nil "~a rejected on mupdf buffer" cmd))))))
