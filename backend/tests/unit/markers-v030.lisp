;;;; v0.30 §A — markers RED tests (~50 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/marker : make-marker / point-marker / point-min/max-marker
;;;;                 copy-marker / marker-position / marker-buffer / set-marker
;;;;                 marker-insertion-type / set-marker-insertion-type
;;;;                 process-insert / process-delete  (fixup engine, unit-test entry points)
;;;;                 reset-markers / marker-count-for (test introspection)
;;;;                 *current-buffer-id*
;;;;                 *buffer-cursor-fn* / *buffer-text-len-fn*
;;;;
;;;; Fixup 規則（SPEC v0.30）：
;;;;   Insert at POS, length L：
;;;;     marker.pos < POS               → 不動
;;;;     marker.pos == POS, :before     → 不動
;;;;     marker.pos == POS, :after      → pos += L
;;;;     marker.pos > POS               → pos += L
;;;;   Delete [FROM, TO)：
;;;;     marker.pos <= FROM             → 不動
;;;;     FROM < marker.pos < TO         → clamp to FROM
;;;;     marker.pos >= TO               → pos -= (TO - FROM)
;;;;
;;;; 全部 RED — 在 limn-marker.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/marker)
    (make-package '#:limn/marker :use '(#:cl)))
  (dolist (sym '(;; public API
                 "MAKE-MARKER"
                 "POINT-MARKER"
                 "POINT-MIN-MARKER"
                 "POINT-MAX-MARKER"
                 "COPY-MARKER"
                 "MARKER-POSITION"
                 "MARKER-BUFFER"
                 "SET-MARKER"
                 "MARKER-INSERTION-TYPE"
                 "SET-MARKER-INSERTION-TYPE"
                 ;; fixup entry points (called by event handler; also direct for tests)
                 "PROCESS-INSERT"
                 "PROCESS-DELETE"
                 ;; test helpers
                 "RESET-MARKERS"
                 "MARKER-COUNT-FOR"
                 ;; I/O vtable
                 "*CURRENT-BUFFER-ID*"
                 "*BUFFER-CURSOR-FN*"
                 "*BUFFER-TEXT-LEN-FN*"))
    (export (intern sym '#:limn/marker) '#:limn/marker)))

;; limn/mark stub — A9 integration tests reference limn/mark symbols at
;; read time; this ensures the package exists even in standalone loads.
;; When run via run-unit.lisp the real limn-mark.lisp replaces these stubs.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/mark)
    (make-package '#:limn/mark :use '(#:cl)))
  (dolist (sym '("SET-MARK" "MARK" "PUSH-MARK" "MARK-RING-FOR" "RESET-MARKS"))
    (export (intern sym '#:limn/mark) '#:limn/mark)))

(in-package #:limn/unit-test)

;;; ── mock buffer ──────────────────────────────────────────────────────────
;;;
;;; Minimal in-memory buffer. mmbuf-insert! / mmbuf-delete! mutate text
;;; and then call limn/marker:process-insert / process-delete so markers
;;; get fixed up, mirroring what the real event handler would do.
;;;
;;; *mock-buffers* keeps a buf-id → mmbuf map so the vtable functions can
;;; serve queries about *any* mock buffer that has been registered (needed
;;; for cross-buffer tests where two with-marker-ctx wrappers nest).

(defstruct (mmbuf
             (:conc-name mmbuf-)
             (:constructor make-mmbuf (&key (id "b") (text "") (cursor 0))))
  id
  (text   "" :type string)
  (cursor  0 :type integer))

(defun mmbuf-len (b) (length (mmbuf-text b)))

(defvar *mock-buffers* (make-hash-table :test 'equal))

(defun mmbuf-vtable-cursor (bid)
  (let ((b (gethash bid *mock-buffers*)))
    (if b (mmbuf-cursor b) 0)))

(defun mmbuf-vtable-text-len (bid)
  (let ((b (gethash bid *mock-buffers*)))
    (if b (mmbuf-len b) 0)))

(defun mmbuf-insert! (b pos str)
  "Insert STR at POS in mock buffer B, then fire marker fixup."
  (let ((txt (mmbuf-text b)))
    (setf (mmbuf-text b)
          (concatenate 'string (subseq txt 0 pos) str (subseq txt pos))))
  (when (find-package '#:limn/marker)
    (limn/marker:process-insert (mmbuf-id b) pos (length str))))

(defun mmbuf-delete! (b from to)
  "Delete [FROM,TO) from mock buffer B, then fire marker fixup."
  (let ((txt (mmbuf-text b)))
    (setf (mmbuf-text b)
          (concatenate 'string (subseq txt 0 from) (subseq txt to))))
  (when (find-package '#:limn/marker)
    (limn/marker:process-delete (mmbuf-id b) from to)))

;;; with-marker-ctx — registers buf in *mock-buffers*, binds vtable vars,
;;; and resets markers for ID. Cleanup happens unconditionally.
(defmacro with-marker-ctx ((var &key (id "mb") (text "") (cursor 0)) &body body)
  "Bind VAR to a fresh mock buffer. Rebind limn/marker I/O vtable to target
   *mock-buffers*. Reset all markers for ID before and after body."
  (let ((pkg   (gensym "PKG"))
        (pairs (gensym "PAIRS"))
        (live  (gensym "LIVE")))
    `(let* ((,var (make-mmbuf :id ,id :text ,text :cursor ,cursor))
            (,pkg (find-package '#:limn/marker)))
       (setf (gethash ,id *mock-buffers*) ,var)
       (flet ((reset! ()
                (when ,pkg (limn/marker:reset-markers ,id))))
         (reset!)
         (unwind-protect
              (if (null ,pkg)
                  (progn ,@body)
                  (let* ((,pairs
                           (list
                            (cons (find-symbol "*CURRENT-BUFFER-ID*"   ,pkg) ,id)
                            (cons (find-symbol "*BUFFER-CURSOR-FN*"    ,pkg)
                                  #'mmbuf-vtable-cursor)
                            (cons (find-symbol "*BUFFER-TEXT-LEN-FN*"  ,pkg)
                                  #'mmbuf-vtable-text-len)))
                         (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
                    (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                      ,@body)))
           (remhash ,id *mock-buffers*)
           (reset!))))))

;;; ── A1. Basic creation ───────────────────────────────────────────────────

(deftest marker-a1-make-marker-is-unlinked
  "make-marker 產生的 marker 沒有 buffer 也沒有 position。"
  (with-marker-ctx (b :id "a1a")
    (let ((m (limn/marker:make-marker)))
      (assert-false (limn/marker:marker-position m)
                    "unlinked marker-position is nil")
      (assert-false (limn/marker:marker-buffer m)
                    "unlinked marker-buffer is nil"))))

(deftest marker-a1-point-marker-returns-cursor
  "point-marker 回傳當前 buffer + cursor 位置的 marker。"
  (with-marker-ctx (b :id "a1b" :text "hello" :cursor 3)
    (let ((m (limn/marker:point-marker)))
      (assert-eql 3 (limn/marker:marker-position m)
                  "point-marker position = cursor")
      (assert-equal "a1b" (limn/marker:marker-buffer m)
                    "point-marker buffer = current buffer"))))

(deftest marker-a1-point-min-marker
  "point-min-marker 回傳 position=0 的 marker。"
  (with-marker-ctx (b :id "a1c" :text "hello" :cursor 2)
    (let ((m (limn/marker:point-min-marker)))
      (assert-eql 0 (limn/marker:marker-position m)
                  "point-min position = 0"))))

(deftest marker-a1-point-max-marker
  "point-max-marker 回傳 position = text length 的 marker。"
  (with-marker-ctx (b :id "a1d" :text "hello" :cursor 0)
    (let ((m (limn/marker:point-max-marker)))
      (assert-eql 5 (limn/marker:marker-position m)
                  "point-max position = 5 for 'hello'"))))

(deftest marker-a1-copy-marker-from-marker
  "copy-marker MARKER → 同位置、同 buffer 的新 marker（不是同一物件）。"
  (with-marker-ctx (b :id "a1e" :text "abcde" :cursor 0)
    (let* ((m  (limn/marker:make-marker))
           (_  (limn/marker:set-marker m 2 "a1e"))
           (m2 (limn/marker:copy-marker m)))
      (declare (ignore _))
      (assert-eql 2 (limn/marker:marker-position m2)
                  "copy has same position")
      (assert-equal "a1e" (limn/marker:marker-buffer m2)
                    "copy has same buffer")
      (assert-false (eq m m2) "copy is not eq to original"))))

(deftest marker-a1-copy-marker-from-integer
  "copy-marker INTEGER → marker at that position in current buffer。"
  (with-marker-ctx (b :id "a1f" :text "hello" :cursor 0)
    (let ((m (limn/marker:copy-marker 3)))
      (assert-eql 3 (limn/marker:marker-position m))
      (assert-equal "a1f" (limn/marker:marker-buffer m)))))

(deftest marker-a1-set-marker-updates-position
  "set-marker 可重新指向 position 和 buffer。"
  (with-marker-ctx (b :id "a1g" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 4 "a1g")
      (assert-eql 4 (limn/marker:marker-position m))
      (assert-equal "a1g" (limn/marker:marker-buffer m)))))

(deftest marker-a1-set-marker-nil-unlinks
  "set-marker M nil 解除 marker 與 buffer 的連結。"
  (with-marker-ctx (b :id "a1h" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a1h")
      (limn/marker:set-marker m nil)
      (assert-false (limn/marker:marker-position m) "position = nil after unlink")
      (assert-false (limn/marker:marker-buffer m)   "buffer = nil after unlink"))))

;;; ── A2. insertion-type ───────────────────────────────────────────────────

(deftest marker-a2-default-insertion-type-is-before
  "marker-insertion-type 預設是 :before。"
  (with-marker-ctx (b :id "a2a")
    (let ((m (limn/marker:make-marker)))
      (assert-eq :before (limn/marker:marker-insertion-type m)))))

(deftest marker-a2-set-insertion-type-after
  "set-marker-insertion-type 改成 :after，marker-insertion-type 讀回對。"
  (with-marker-ctx (b :id "a2b")
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker-insertion-type m :after)
      (assert-eq :after (limn/marker:marker-insertion-type m)))))

(deftest marker-a2-copy-marker-inherits-insertion-type
  "copy-marker 複製 insertion-type。"
  (with-marker-ctx (b :id "a2c" :text "hi" :cursor 0)
    (let* ((m  (limn/marker:make-marker))
           (_  (limn/marker:set-marker m 1 "a2c"))
           (_  (limn/marker:set-marker-insertion-type m :after))
           (m2 (limn/marker:copy-marker m)))
      (declare (ignore _))
      (assert-eq :after (limn/marker:marker-insertion-type m2)))))

;;; ── A3. Fixup — Insert ───────────────────────────────────────────────────

(deftest marker-a3-insert-before-marker-shifts-it
  "insert at pos < marker.pos → marker 往後移 len 個 codepoint。"
  (with-marker-ctx (b :id "a3a" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 3 "a3a")
      (mmbuf-insert! b 1 "XX")     ; insert 2 chars at pos 1 < 3
      (assert-eql 5 (limn/marker:marker-position m)
                  "marker shifts from 3 to 5"))))

(deftest marker-a3-insert-after-marker-does-not-move-it
  "insert at pos > marker.pos → marker 不動。"
  (with-marker-ctx (b :id "a3b" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a3b")
      (mmbuf-insert! b 4 "ZZ")    ; insert after marker
      (assert-eql 2 (limn/marker:marker-position m)
                  "marker stays at 2"))))

(deftest marker-a3-insert-at-marker-before-type-does-not-move
  "insert 在 marker 同點，:before → marker 不動（留在原位）。"
  (with-marker-ctx (b :id "a3c" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a3c")
      (assert-eq :before (limn/marker:marker-insertion-type m))
      (mmbuf-insert! b 2 "AB")
      (assert-eql 2 (limn/marker:marker-position m)
                  ":before marker stays at 2"))))

(deftest marker-a3-insert-at-marker-after-type-moves-forward
  "insert 在 marker 同點，:after → marker 推到新文字後。"
  (with-marker-ctx (b :id "a3d" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a3d")
      (limn/marker:set-marker-insertion-type m :after)
      (mmbuf-insert! b 2 "AB")
      (assert-eql 4 (limn/marker:marker-position m)
                  ":after marker moves to 4"))))

(deftest marker-a3-two-markers-at-same-pos-different-type
  "同位置兩個 marker，一 :before 一 :after，insert 後各自正確。"
  (with-marker-ctx (b :id "a3e" :text "hello" :cursor 0)
    (let ((mb (limn/marker:make-marker))
          (ma (limn/marker:make-marker)))
      (limn/marker:set-marker mb 3 "a3e")
      (limn/marker:set-marker ma 3 "a3e")
      (limn/marker:set-marker-insertion-type ma :after)
      (mmbuf-insert! b 3 "XY")    ; len=2
      (assert-eql 3 (limn/marker:marker-position mb) ":before stays at 3")
      (assert-eql 5 (limn/marker:marker-position ma) ":after moves to 5"))))

(deftest marker-a3-insert-zero-length-is-noop
  "insert len=0 → 所有 marker 不動。"
  (with-marker-ctx (b :id "a3f" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a3f")
      (limn/marker:process-insert "a3f" 2 0)    ; explicit no-op
      (assert-eql 2 (limn/marker:marker-position m)
                  "zero-length insert does not move marker"))))

(deftest marker-a3-insert-at-pos-0-shifts-marker-at-0-after
  "insert at pos=0，marker at 0 :after → marker 移到 len。"
  (with-marker-ctx (b :id "a3g" :text "hi" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 0 "a3g")
      (limn/marker:set-marker-insertion-type m :after)
      (mmbuf-insert! b 0 "ABC")   ; len=3
      (assert-eql 3 (limn/marker:marker-position m)
                  ":after at 0 moves to 3"))))

(deftest marker-a3-insert-at-pos-0-keeps-marker-at-0-before
  "insert at pos=0，marker at 0 :before → 不動。"
  (with-marker-ctx (b :id "a3h" :text "hi" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 0 "a3h")
      (mmbuf-insert! b 0 "ABC")
      (assert-eql 0 (limn/marker:marker-position m)
                  ":before at 0 stays"))))

(deftest marker-a3-two-sequential-inserts-accumulate
  "連續兩次 insert → marker 累積兩次 fixup。"
  (with-marker-ctx (b :id "a3i" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a3i")
      (mmbuf-insert! b 0 "X")    ; len=1 → marker: 3
      (mmbuf-insert! b 0 "Y")    ; len=1 → marker: 4
      (assert-eql 4 (limn/marker:marker-position m)
                  "two inserts before marker: 2 + 1 + 1 = 4"))))

(deftest marker-a3-insert-in-middle-many-markers
  "5 個 markers 散落各處，insert 後只有 pos > insert-point 的移動。"
  (with-marker-ctx (b :id "a3j" :text "abcde" :cursor 0)
    (let ((ms (loop for p in '(0 1 2 3 4)
                    collect (let ((m (limn/marker:make-marker)))
                              (limn/marker:set-marker m p "a3j")
                              m))))
      ;; insert "XX" at pos 2, len=2
      (mmbuf-insert! b 2 "XX")
      ;; expected: 0→0, 1→1, 2→2(:before), 3→5, 4→6
      (let ((positions (mapcar #'limn/marker:marker-position ms)))
        (assert-equal '(0 1 2 5 6) positions
                      "markers at 0,1 unchanged; :before at 2 unchanged; 3→5, 4→6")))))

;;; ── A4. Fixup — Delete ───────────────────────────────────────────────────

(deftest marker-a4-delete-before-marker-shifts-it-left
  "delete [0,2) → marker at 3 moves to 1."
  (with-marker-ctx (b :id "a4a" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 3 "a4a")
      (mmbuf-delete! b 0 2)       ; delete "he", len=2
      (assert-eql 1 (limn/marker:marker-position m)
                  "3 - 2 = 1"))))

(deftest marker-a4-delete-after-marker-does-not-move-it
  "delete wholly after marker → marker 不動。"
  (with-marker-ctx (b :id "a4b" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 1 "a4b")
      (mmbuf-delete! b 3 5)       ; delete "lo"
      (assert-eql 1 (limn/marker:marker-position m)
                  "marker before deletion range stays"))))

(deftest marker-a4-delete-covers-marker-clamps-to-from
  "marker 在 [FROM,TO) 內 → clamp 到 FROM。"
  (with-marker-ctx (b :id "a4c" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a4c")
      (mmbuf-delete! b 1 4)       ; delete "ell"
      (assert-eql 1 (limn/marker:marker-position m)
                  "marker inside [1,4) clamps to 1"))))

(deftest marker-a4-delete-marker-at-from-boundary-stays
  "marker.pos == FROM → 不動（不 clamp、不 shift）。"
  (with-marker-ctx (b :id "a4d" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 1 "a4d")
      (mmbuf-delete! b 1 3)       ; delete "el", marker at FROM
      (assert-eql 1 (limn/marker:marker-position m)
                  "marker at FROM stays at 1"))))

(deftest marker-a4-delete-marker-at-to-boundary-shifts
  "marker.pos == TO → pos -= (TO-FROM)。"
  (with-marker-ctx (b :id "a4e" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 3 "a4e")
      (mmbuf-delete! b 1 3)       ; delete "el" [1,3), marker at TO=3
      (assert-eql 1 (limn/marker:marker-position m)
                  "marker at TO shifts: 3 - (3-1) = 1"))))

(deftest marker-a4-delete-all-text-clamps-to-0
  "delete 全部文字，所有 marker clamp 到 0。"
  (with-marker-ctx (b :id "a4f" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 4 "a4f")
      (mmbuf-delete! b 0 5)
      (assert-eql 0 (limn/marker:marker-position m)
                  "marker inside [0,5) clamps to 0"))))

(deftest marker-a4-sequential-delete-then-insert
  "delete 再 insert → 兩次 fixup 都正確。"
  (with-marker-ctx (b :id "a4g" :text "abcde" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 4 "a4g")
      (mmbuf-delete! b 1 3)       ; delete [1,3): "bc" → "ade", marker: 4-2=2
      (mmbuf-insert! b 0 "ZZ")    ; insert at 0, len=2 → marker: 2+2=4
      (assert-eql 4 (limn/marker:marker-position m)
                  "delete then insert accumulate correctly"))))

;;; ── A5. Cross-buffer isolation ───────────────────────────────────────────

(deftest marker-a5-edit-other-buffer-does-not-move-marker
  "edit buffer b2 不影響 marker 在 b1 的 position。"
  (with-marker-ctx (b1 :id "a5a" :text "hello" :cursor 0)
    (with-marker-ctx (b2 :id "a5b" :text "world" :cursor 0)
      (let ((m (limn/marker:make-marker)))
        (limn/marker:set-marker m 3 "a5a")
        ;; edit b2 only
        (mmbuf-insert! b2 0 "PREFIX")
        (assert-eql 3 (limn/marker:marker-position m)
                    "marker in a5a unaffected by edit in a5b")
        (assert-equal "a5a" (limn/marker:marker-buffer m)
                      "marker still bound to a5a")))))

(deftest marker-a5-markers-in-different-buffers-independent
  "兩個 buffer 各有 marker，分別 edit 後各自正確。"
  (with-marker-ctx (b1 :id "a5c" :text "hello" :cursor 0)
    (with-marker-ctx (b2 :id "a5d" :text "world" :cursor 0)
      (let ((m1 (limn/marker:make-marker))
            (m2 (limn/marker:make-marker)))
        (limn/marker:set-marker m1 2 "a5c")
        (limn/marker:set-marker m2 3 "a5d")
        (mmbuf-insert! b1 0 "X")   ; only b1 edited
        (assert-eql 3 (limn/marker:marker-position m1) "m1: 2+1=3")
        (assert-eql 3 (limn/marker:marker-position m2) "m2 unchanged: 3")))))

(deftest marker-a5-unlinked-marker-unaffected-by-any-edit
  "unlinked marker（no buffer）不受任何 edit 影響。"
  (with-marker-ctx (b :id "a5e" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      ;; m is unlinked (no buffer assigned)
      (mmbuf-insert! b 0 "XYZ")
      (assert-false (limn/marker:marker-position m)
                    "unlinked marker position stays nil"))))

;;; ── A6. Multiple markers burst ───────────────────────────────────────────

(deftest marker-a6-30-markers-survive-30-inserts
  "建 30 個 marker 於 0..29，做 30 次 insert at 0，各自 position 正確。
   注意：marker at 0 :before → 永遠 stay at 0；其他 marker (orig>0) 都 +30。"
  (with-marker-ctx (b :id "a6a" :text (make-string 30 :initial-element #\a) :cursor 0)
    (let ((ms (loop for p from 0 to 29
                    collect (let ((m (limn/marker:make-marker)))
                              (limn/marker:set-marker m p "a6a")
                              m))))
      (dotimes (_ 30)
        (mmbuf-insert! b 0 "X"))
      ;; orig=0 :before stays at 0; orig=P (P>0) becomes P+30
      (loop for m in ms
            for orig from 0
            for expected = (if (zerop orig) 0 (+ orig 30))
            do (assert-eql expected (limn/marker:marker-position m)
                           (format nil "marker orig ~a → ~a" orig expected))))))

(deftest marker-a6-interleaved-insert-delete
  "交替 insert/delete，marker 最終位置仍對。"
  (with-marker-ctx (b :id "a6b" :text "abcdefghij" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 5 "a6b")
      ;; insert "XX" at 0: marker 5→7
      (mmbuf-insert! b 0 "XX")
      ;; delete [3,5): marker 7-2=5, since FROM=3 < TO=5 <= 7, shifts: 7-2=5
      (mmbuf-delete! b 3 5)
      ;; insert "Y" at 2: marker 5→6
      (mmbuf-insert! b 2 "Y")
      (assert-eql 6 (limn/marker:marker-position m)
                  "interleaved ops: final position 6"))))

(deftest marker-a6-marker-count-tracks-registration
  "marker-count-for 反映 set-marker 後的登記數。"
  (with-marker-ctx (b :id "a6c" :text "hello" :cursor 0)
    (let ((before (limn/marker:marker-count-for "a6c")))
      (let ((m1 (limn/marker:make-marker))
            (m2 (limn/marker:make-marker)))
        (limn/marker:set-marker m1 1 "a6c")
        (limn/marker:set-marker m2 2 "a6c")
        (assert-eql (+ before 2) (limn/marker:marker-count-for "a6c")
                    "count increases by 2 after 2 set-marker calls")))))

;;; ── A7. Non-BMP codepoint unit ───────────────────────────────────────────

(deftest marker-a7-emoji-codepoint-unit
  "marker 在 emoji（2 個 codepoint）後，insert 1 ASCII char 前面，marker += 1。"
  ;; 字串「AB😀C」= codepoints [A=0, B=1, 😀=2, C=3]（SBCL STRING 以 codepoint 計）
  (with-marker-ctx (b :id "a7a" :text (coerce '(#\A #\B #\U0001F600 #\C) 'string)
                   :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 3 "a7a") ; after emoji (pos 2), before C (pos 3)
      (mmbuf-insert! b 0 "X")            ; insert 1 ASCII at 0
      (assert-eql 4 (limn/marker:marker-position m)
                  "codepoint unit: 3+1=4 after insert before emoji"))))

(deftest marker-a7-emoji-insert-after-does-not-shift
  "insert after marker（emoji-heavy string） → marker 不動。"
  (with-marker-ctx (b :id "a7b" :text (coerce '(#\A #\U0001F600 #\B) 'string)
                   :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 1 "a7b") ; before emoji
      (mmbuf-insert! b 3 "Z")            ; after everything
      (assert-eql 1 (limn/marker:marker-position m)
                  "insert after: marker stays at 1"))))

;;; ── A8. GC simulation / manual cleanup ──────────────────────────────────
;;;
;;; SPEC 說 unit-tier 用 simple list + manual cleanup 代替 weakref reaper。
;;; 這組測試驗證：明確解除 marker 之後，process-insert 不 error、
;;; 也不繼續操作已解除的 marker。

(deftest marker-a8-unlink-before-edit-does-not-crash
  "set-marker M nil 解除後，buffer edit 不 crash。"
  (with-marker-ctx (b :id "a8a" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a8a")
      (limn/marker:set-marker m nil)      ; unlink
      (assert-no-error
       (mmbuf-insert! b 0 "X")
       "insert after unlink does not signal"))))

(deftest marker-a8-reset-markers-clears-count
  "reset-markers 後 marker-count-for 回到 0。"
  (with-marker-ctx (b :id "a8b" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 3 "a8b")
      (limn/marker:reset-markers "a8b")
      (assert-eql 0 (limn/marker:marker-count-for "a8b")
                  "count = 0 after reset"))))

(deftest marker-a8-edit-after-reset-does-not-crash
  "reset-markers 後 mmbuf-insert! 不 error，新建 marker 仍能正常 fixup。"
  (with-marker-ctx (b :id "a8c" :text "hello" :cursor 0)
    (let ((m1 (limn/marker:make-marker)))
      (limn/marker:set-marker m1 2 "a8c")
      (limn/marker:reset-markers "a8c")
      ;; register a new marker after reset
      (let ((m2 (limn/marker:make-marker)))
        (limn/marker:set-marker m2 1 "a8c")
        (assert-no-error (mmbuf-insert! b 0 "X") "insert after reset + new marker")
        (assert-eql 2 (limn/marker:marker-position m2)
                    "new marker after reset gets fixup: 1+1=2")))))

;;; ── A9. Integration: mark-ring uses markers ──────────────────────────────
;;;
;;; v0.30 把 limn/mark 的 mark 儲存升級成 marker，使 set-mark 之後的 insert
;;; 不會讓 mark 失準。這組測試驗證整合後行為。

(deftest marker-a9-set-mark-then-insert-before-mark-adjusts
  "set-mark pos=5，在 pos=0 insert 2 字 → mark 應自動調整到 7。"
  (with-marker-ctx (b :id "a9a" :text "hello world" :cursor 5)
    (when (find-package '#:limn/mark)
      ;; wire cursor vtable for limn/mark too
      (let ((mark-pkg (find-package '#:limn/mark)))
        (let* ((cur-sym (find-symbol "*BUFFER-CURSOR-FN*" mark-pkg))
               (set-sym (find-symbol "*BUFFER-SET-CURSOR-FN*" mark-pkg)))
          (when (and cur-sym set-sym)
            (let ((b2 b))
              (progv (list cur-sym set-sym)
                  (list (lambda (bid) (declare (ignore bid)) (mmbuf-cursor b2))
                        (lambda (bid off) (declare (ignore bid)) (setf (mmbuf-cursor b2) off)))
                (limn/mark:reset-marks "a9a")
                (limn/mark:set-mark 5 "a9a")
                (mmbuf-insert! b 0 "XY")    ; insert 2 chars at 0
                (assert-eql 7 (limn/mark:mark "a9a")
                            "mark adjusts from 5 to 7 after insert at 0")))))))))

(deftest marker-a9-set-mark-insert-after-does-not-move-mark
  "set-mark pos=2，在 pos=4 insert → mark 不動。"
  (with-marker-ctx (b :id "a9b" :text "hello" :cursor 2)
    (when (find-package '#:limn/mark)
      (let ((mark-pkg (find-package '#:limn/mark)))
        (let* ((cur-sym (find-symbol "*BUFFER-CURSOR-FN*" mark-pkg))
               (set-sym (find-symbol "*BUFFER-SET-CURSOR-FN*" mark-pkg)))
          (when (and cur-sym set-sym)
            (let ((b2 b))
              (progv (list cur-sym set-sym)
                  (list (lambda (bid) (declare (ignore bid)) (mmbuf-cursor b2))
                        (lambda (bid off) (declare (ignore bid)) (setf (mmbuf-cursor b2) off)))
                (limn/mark:reset-marks "a9b")
                (limn/mark:set-mark 2 "a9b")
                (mmbuf-insert! b 4 "ZZZ")
                (assert-eql 2 (limn/mark:mark "a9b")
                            "mark at 2 stays when insert at 4")))))))))

(deftest marker-a9-multiple-marks-all-adjust
  "push-mark 多次後 insert，所有 mark ring 裡的 marker 都調整。"
  (with-marker-ctx (b :id "a9c" :text "abcdefghij" :cursor 0)
    (when (find-package '#:limn/mark)
      (let ((mark-pkg (find-package '#:limn/mark)))
        (let* ((cur-sym (find-symbol "*BUFFER-CURSOR-FN*" mark-pkg))
               (set-sym (find-symbol "*BUFFER-SET-CURSOR-FN*" mark-pkg)))
          (when (and cur-sym set-sym)
            (let ((b2 b))
              (progv (list cur-sym set-sym)
                  (list (lambda (bid) (declare (ignore bid)) (mmbuf-cursor b2))
                        (lambda (bid off) (declare (ignore bid)) (setf (mmbuf-cursor b2) off)))
                (limn/mark:reset-marks "a9c")
                ;; push 3 marks at 1, 4, 7
                (limn/mark:set-mark 1 "a9c")
                (limn/mark:push-mark "a9c" :pos 4)
                (limn/mark:push-mark "a9c" :pos 7)
                ;; insert "XX" at pos 0, len=2
                (mmbuf-insert! b 0 "XX")
                ;; current mark (7) should now be 9
                (assert-eql 9 (limn/mark:mark "a9c")
                            "current mark 7→9 after insert at 0")
                ;; ring should also have adjusted entries
                (let ((ring (limn/mark:mark-ring-for "a9c")))
                  (assert-true (member 6 ring)   ; 4+2=6
                               "ring entry 4→6")
                  (assert-true (member 3 ring)   ; 1+2=3
                               "ring entry 1→3"))))))))))

;;; ── A10. Dogfood — 長期使用情境 ────────────────────────────────────────
;;;
;;; 模擬使用者連續使用 1-2 週後可能遇到的問題：marker leak、跨 buffer 搬遷、
;;; 越界 set-marker、高頻 edit、idempotency 等。

(deftest marker-a10-set-marker-clamps-position-to-text-len
  "set-marker 位置超過 text-len → clamp 到 text-len（Emacs 慣例）。"
  (with-marker-ctx (b :id "a10a" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 100 "a10a")
      (assert-eql 5 (limn/marker:marker-position m)
                  "100 clamped to text-len 5"))))

(deftest marker-a10-set-marker-clamps-negative-to-zero
  "set-marker 負位置 → clamp 到 0。"
  (with-marker-ctx (b :id "a10b" :text "hi" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m -5 "a10b")
      (assert-eql 0 (limn/marker:marker-position m)
                  "-5 clamped to 0"))))

(deftest marker-a10-set-marker-without-buffer-arg-keeps-existing
  "set-marker M pos 省略 buffer 參數 → 保留現有 buffer（不 unlink）。"
  (with-marker-ctx (b :id "a10c" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 1 "a10c")
      (limn/marker:set-marker m 3)                  ; no buffer arg
      (assert-eql 3 (limn/marker:marker-position m))
      (assert-equal "a10c" (limn/marker:marker-buffer m)
                    "buffer unchanged when omitted"))))

(deftest marker-a10-set-marker-moves-marker-between-buffers
  "set-marker 把 marker 從 A 改指 B → A 的 edit 不再影響它、B 的 edit 才影響。"
  (with-marker-ctx (b1 :id "a10d-A" :text "hello" :cursor 0)
    (with-marker-ctx (b2 :id "a10d-B" :text "world" :cursor 0)
      (let ((m (limn/marker:make-marker)))
        (limn/marker:set-marker m 3 "a10d-A")
        ;; move to B
        (limn/marker:set-marker m 2 "a10d-B")
        (assert-equal "a10d-B" (limn/marker:marker-buffer m)
                      "marker now in B")
        ;; edit A — should NOT move
        (mmbuf-insert! b1 0 "XXX")
        (assert-eql 2 (limn/marker:marker-position m)
                    "edits in old buffer A do not affect marker")
        ;; edit B — SHOULD move
        (mmbuf-insert! b2 0 "Y")
        (assert-eql 3 (limn/marker:marker-position m)
                    "edits in new buffer B affect marker: 2+1=3")))))

(deftest marker-a10-process-insert-unknown-buf-no-error
  "process-insert 對未登記任何 marker 的 buf-id → silent no-op。"
  (when (find-package '#:limn/marker)
    (assert-no-error
     (limn/marker:process-insert "never-existed-a10e" 0 3)
     "no markers for buf-id: no error")))

(deftest marker-a10-process-delete-unknown-buf-no-error
  "process-delete 對未登記 marker 的 buf-id → silent no-op。"
  (when (find-package '#:limn/marker)
    (assert-no-error
     (limn/marker:process-delete "never-existed-a10f" 0 3)
     "no markers for buf-id: no error")))

(deftest marker-a10-copy-marker-integer-with-insertion-type
  "copy-marker INTEGER :after BUF → 三參數完整形式。"
  (with-marker-ctx (b :id "a10g" :text "hello" :cursor 0)
    (let ((m (limn/marker:copy-marker 2 :after "a10g")))
      (assert-eql 2 (limn/marker:marker-position m))
      (assert-equal "a10g" (limn/marker:marker-buffer m))
      (assert-eq :after (limn/marker:marker-insertion-type m)))))

(deftest marker-a10-point-max-marker-after-tracks-end
  "point-max-marker 設 :after，insert 在末端 → marker 跟到新末端（append-only）。"
  (with-marker-ctx (b :id "a10h" :text "hello" :cursor 0)
    (let ((m (limn/marker:point-max-marker)))
      (limn/marker:set-marker-insertion-type m :after)
      (mmbuf-insert! b 5 "!!")
      (assert-eql 7 (limn/marker:marker-position m)
                  ":after at end: 5+2=7, follows append"))))

(deftest marker-a10-1000-edits-stay-consistent
  "高頻 edit：1000 次 insert at 0 → marker 從 5 變成 1005。"
  (with-marker-ctx (b :id "a10i" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 5 "a10i")
      (dotimes (_ 1000)
        (mmbuf-insert! b 0 "x"))
      (assert-eql 1005 (limn/marker:marker-position m)
                  "1000 single-char inserts before: 5+1000=1005"))))

(deftest marker-a10-idempotent-set-marker-same-buffer
  "set-marker M pos buf 第二次（同 buffer）→ marker-count 不增加（不 double-register）。"
  (with-marker-ctx (b :id "a10j" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a10j")
      (let ((after-first (limn/marker:marker-count-for "a10j")))
        (limn/marker:set-marker m 3 "a10j")
        (assert-eql after-first (limn/marker:marker-count-for "a10j")
                    "second set-marker on same buffer does not re-register")))))

(deftest marker-a10-marker-position-is-always-integer
  "marker-position 永遠 integer（防 float / ratio 污染）。"
  (with-marker-ctx (b :id "a10k" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 2 "a10k")
      (mmbuf-insert! b 0 "X")
      (assert-true (integerp (limn/marker:marker-position m))
                   "position is integer after fixup"))))

(deftest marker-a10-delete-then-insert-at-same-point
  "find-replace pattern: delete [3,5) 後 insert at 3 → marker 淨計算正確。"
  (with-marker-ctx (b :id "a10l" :text "hello" :cursor 0)
    (let ((m (limn/marker:make-marker)))
      (limn/marker:set-marker m 4 "a10l")
      (mmbuf-delete! b 3 5)              ; 4 in [3,5) → clamp to 3
      (mmbuf-insert! b 3 "XX")           ; :before at 3 stays
      (assert-eql 3 (limn/marker:marker-position m)
                  "delete-clamp then insert-before-at-same: stays at 3"))))

(deftest marker-a10-point-marker-without-current-buffer-errors
  "point-marker 在沒有 *current-buffer-id* 時 → signal error。"
  (when (find-package '#:limn/marker)
    (progv (list (find-symbol "*CURRENT-BUFFER-ID*" '#:limn/marker))
        (list nil)
      (assert-error error (limn/marker:point-marker)
                    "no current buffer → error"))))
