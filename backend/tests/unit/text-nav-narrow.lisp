;;;; v0.40 §1.1 — text-nav narrow-aware tests.
;;;;
;;;; Covers Phase 1.1 of buffer narrow/widen: every text-nav command
;;;; respects the active [point-min, point-max) window when the
;;;; current buffer is narrowed via limn/excursion:narrow-to-region.
;;;;
;;;; All commands tested:
;;;;   beginning-of-buffer / end-of-buffer        (M-< / M->)
;;;;   move-beginning-of-line / move-end-of-line  (C-a / C-e)
;;;;   next-line / previous-line                  (C-n / C-p)
;;;;   forward-word / backward-word               (M-f / M-b)
;;;;   delete-forward-char                        (C-d)
;;;;   kill-line / kill-word                      (C-k / M-d)
;;;;   skip-syntax-forward / skip-syntax-backward
;;;;
;;;; Setup strategy: build on top of with-excursion-ctx (which already
;;;; wires marker / local / current-buffer-id correctly for narrow
;;;; markers to work), and additionally wire limn/text-nav's vtable
;;;; (*buffer-text-fn* etc.) to read from the same mmbuf32 mock.

(in-package #:limn/unit-test)

;;; ── shared fixture: with-narrow-nav ──────────────────────────────────────
;;;
;;; Wires text-nav vtable on top of with-excursion-ctx, so the mock
;;; buffer is visible to BOTH excursion (for narrow-to-region) and
;;; text-nav (for the commands under test).

(defmacro with-narrow-nav ((var &key (id "nn") (text "") (point 0)) &body body)
  "Set up one mmbuf32 mock, wire excursion + text-nav vtables to it,
   bind it as current buffer.  Inside BODY, VAR is the mock.
   Commands take (mmbuf32-id VAR) as their buf-id arg.
   The text is %nl-translated so \\\\n becomes #\\Newline."
  (let ((nav-pkg (gensym "NP"))
        (pairs   (gensym "PAIRS"))
        (live    (gensym "LIVE"))
        (gid     (gensym "GID")))
    `(with-excursion-ctx ((,var :id ,id :text (%nl ,text) :point ,point))
       (let* ((,gid (mmbuf32-id ,var))
              (,nav-pkg (find-package '#:limn/text-nav))
              (,pairs
                (when ,nav-pkg
                  (list
                   (cons (find-symbol "*GOAL-COLUMN*"          ,nav-pkg) nil)
                   (cons (find-symbol "*BUFFER-TEXT-FN*"       ,nav-pkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-text b))))
                   (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,nav-pkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-point b))))
                   (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,nav-pkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off))))
                   ;; Edits go through mmbuf32-insert-fn / -delete-fn
                   ;; (defined in excursion-v032.lisp) so marker
                   ;; fixup fires — narrow markers and any test
                   ;; markers track edits correctly.
                   (cons (find-symbol "*BUFFER-INSERT-FN*"     ,nav-pkg)
                         (let ((id ,gid))
                           (lambda (bid off str)
                             (declare (ignore bid))
                             (mmbuf32-insert-fn id off str))))
                   (cons (find-symbol "*BUFFER-DELETE-FN*"     ,nav-pkg)
                         (let ((id ,gid))
                           (lambda (bid from to)
                             (declare (ignore bid))
                             (mmbuf32-delete-fn id from to))))
                   (cons (find-symbol "*KILL-NEW-FN*"          ,nav-pkg)
                         (lambda (str) (declare (ignore str)) nil)))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
           ,@body)))))

(defun %narrow (lo hi)
  "Apply (narrow-to-region LO HI) on the current buffer."
  (funcall (find-symbol "NARROW-TO-REGION" '#:limn/excursion) lo hi))

(defun %cur (b) (mmbuf32-point b))
(defun %txt (b) (mmbuf32-text b))

;;; ─────────────────────────────────────────────────────────────────────────
;;; M-< / M->  (beginning-of-buffer / end-of-buffer)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-m<-goes-to-point-min
  "M-< 在 narrow 內到 point-min（5），不是 0。"
  (with-narrow-nav (b :text "0123456789ABCDEF" :point 8)
    (%narrow 5 12)
    (limn/text-nav:beginning-of-buffer (mmbuf32-id b))
    (assert-eql 5 (%cur b) "M-< → point-min 5")))

(deftest nav-narrow-m>-goes-to-point-max
  "M-> 在 narrow 內到 point-max（12），不是 buffer end。"
  (with-narrow-nav (b :text "0123456789ABCDEF" :point 8)
    (%narrow 5 12)
    (limn/text-nav:end-of-buffer (mmbuf32-id b))
    (assert-eql 12 (%cur b) "M-> → point-max 12")))

(deftest nav-narrow-m<-widened-goes-to-zero
  "widen 之後 M-< 還是回 0。"
  (with-narrow-nav (b :text "0123456789ABCDEF" :point 8)
    (%narrow 5 12)
    (funcall (find-symbol "WIDEN" '#:limn/excursion))
    (limn/text-nav:beginning-of-buffer (mmbuf32-id b))
    (assert-eql 0 (%cur b) "widen → M-< back to 0")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; C-a / C-e  (move-beginning-of-line / move-end-of-line)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-c-a-stops-at-point-min
  "C-a 不會越過 point-min — 即使前面沒有 \\n。"
  ;; "aa\nbbbb\ncc"  narrow [3, 8) covers "bbbb\n" portion partially.
  ;; cursor=5 sits inside "bbbb", scan-back hits point-min=3 not 0.
  (with-narrow-nav (b :text "aa\\\nbbbb\\\ncc" :point 5)
    (%narrow 3 8)
    (limn/text-nav:move-beginning-of-line (mmbuf32-id b))
    (assert-eql 3 (%cur b) "C-a clamped to point-min 3")))

(deftest nav-narrow-c-e-stops-at-point-max
  "C-e 不會越過 point-max — 即使後面沒有 \\n。"
  ;; "aaaaa", narrow [1, 4).  cursor=2.  C-e → 4 (not 5).
  (with-narrow-nav (b :text "aaaaa" :point 2)
    (%narrow 1 4)
    (limn/text-nav:move-end-of-line (mmbuf32-id b))
    (assert-eql 4 (%cur b) "C-e clamped to point-max 4")))

(deftest nav-narrow-c-a-respects-newline-inside-narrow
  "narrow 內有 \\n 時 C-a 仍走到 \\n 之後（先到的優先）。"
  ;; "xx\nyyyy"  narrow [0, 7) = whole.  cursor=5 (in yyyy)
  ;; C-a → 3 (after \n).
  (with-narrow-nav (b :text "xx\\\nyyyy" :point 5)
    (%narrow 0 7)
    (limn/text-nav:move-beginning-of-line (mmbuf32-id b))
    (assert-eql 3 (%cur b) "C-a found \\n inside narrow")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; M-f / M-b  (forward-word / backward-word)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-m-f-stops-at-point-max
  "M-f 不會越過 point-max — 即使 word 還沒結束。"
  ;; "aaaabbbbcccc", narrow [0, 6).  cursor=0.
  ;; Without narrow, M-f would land at 12 (end). With narrow, stops at 6.
  (with-narrow-nav (b :text "aaaabbbbcccc" :point 0)
    (%narrow 0 6)
    (limn/text-nav:forward-word (mmbuf32-id b))
    (assert-eql 6 (%cur b) "M-f clamped to point-max 6")))

(deftest nav-narrow-m-b-stops-at-point-min
  "M-b 不會越過 point-min — 即使 word 還沒結束。"
  (with-narrow-nav (b :text "aaaabbbbcccc" :point 12)
    (%narrow 6 12)
    (limn/text-nav:backward-word (mmbuf32-id b))
    (assert-eql 6 (%cur b) "M-b clamped to point-min 6")))

(deftest nav-narrow-m-f-finds-word-inside-narrow
  "narrow 內有完整 word 時 M-f 正常走到 word 結尾。"
  ;; "  hi  bye"  narrow [0, 6).  cursor=0.
  ;; M-f: skip ws (0..1) then word (2..4="hi"), stop at 4.
  (with-narrow-nav (b :text "  hi  bye" :point 0)
    (%narrow 0 6)
    (limn/text-nav:forward-word (mmbuf32-id b))
    (assert-eql 4 (%cur b) "M-f stopped at hi-end (4)")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; C-n / C-p
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-c-n-stays-inside-narrow
  "C-n 從 narrow 內最後一行不會走出 narrow（no-op）。"
  ;; "aaa\nbbb\nccc"  narrow [4, 7) = just "bbb" (no trailing \n).
  ;; cursor=5 → eol=7, hi=7 → no next line → no move.
  (with-narrow-nav (b :text "aaa\\\nbbb\\\nccc" :point 5)
    (%narrow 4 7)
    (limn/text-nav:next-line (mmbuf32-id b))
    (assert-eql 5 (%cur b) "C-n at last narrow line: no-op")))

(deftest nav-narrow-c-p-stays-inside-narrow
  "C-p 從 narrow 內第一行不會走出 narrow（no-op）。"
  ;; narrow [4, 11) covers "bbb\nccc". cursor=5 (in bbb) → bol=4=lo → no prev.
  (with-narrow-nav (b :text "aaa\\\nbbb\\\nccc" :point 5)
    (%narrow 4 11)
    (limn/text-nav:previous-line (mmbuf32-id b))
    (assert-eql 5 (%cur b) "C-p at first narrow line: no-op")))

(deftest nav-narrow-c-n-moves-between-narrow-lines
  "narrow 內有多行時 C-n 正常往下走，goal-column 保留。"
  ;; "aaa\nbbbb\nccc"  narrow [0, 12) = whole.  cursor=1 (col 1 in aaa)
  ;; C-n → line 2 col 1 = offset 5.
  (with-narrow-nav (b :text "aaa\\\nbbbb\\\nccc" :point 1)
    (%narrow 0 12)
    (limn/text-nav:next-line (mmbuf32-id b))
    (assert-eql 5 (%cur b) "C-n: col 1 in line 2")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; C-d / DEL — delete-forward-char
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-c-d-noop-at-point-max
  "C-d 在 point-max 是 no-op，即使 buffer 後面還有字。"
  (with-narrow-nav (b :text "abcdef" :point 3)
    (%narrow 0 3)
    (limn/text-nav:delete-forward-char (mmbuf32-id b))
    (assert-equal "abcdef" (%txt b) "no edit at point-max")
    (assert-eql 3 (%cur b) "cursor unchanged")))

(deftest nav-narrow-c-d-deletes-inside-narrow
  "C-d 在 narrow 內正常刪一字，narrow 邊界 fixup。"
  (with-narrow-nav (b :text "abcdef" :point 1)
    (%narrow 0 4)
    (limn/text-nav:delete-forward-char (mmbuf32-id b))
    (assert-equal "acdef" (%txt b) "deleted 'b'")
    (assert-eql 3 (funcall (find-symbol "POINT-MAX" '#:limn/excursion))
                "point-max fixup 4 → 3")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; C-k — kill-line
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-c-k-stops-at-point-max
  "C-k 在 narrow 末行 kill 到 point-max，不會穿到 buffer 末。"
  ;; "abcdefghij"  narrow [0, 5).  cursor=2 → kill "cde" (to point-max=5).
  (with-narrow-nav (b :text "abcdefghij" :point 2)
    (%narrow 0 5)
    (limn/text-nav:kill-line (mmbuf32-id b))
    (assert-equal "abfghij" (%txt b) "killed 'cde' only")))

(deftest nav-narrow-c-k-at-point-max-noop
  "C-k 在 point-max 是 no-op。"
  (with-narrow-nav (b :text "abcdef" :point 3)
    (%narrow 0 3)
    (limn/text-nav:kill-line (mmbuf32-id b))
    (assert-equal "abcdef" (%txt b) "no edit at point-max")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; M-d — kill-word
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-m-d-stops-at-point-max
  "M-d 在 narrow 末 kill 到 point-max。"
  ;; "abcd efgh"  narrow [0, 7).  cursor=0.
  ;; M-d kills "abcd" first call; but skip-non-word-first: starts on
  ;; 'a' which IS word, so skips nothing, then kills "abcd" → cursor 4.
  ;; Test from cursor=5 (after space): skip nothing (e is word),
  ;; kill "ef" up to hi=7 (efgh truncated to ef).
  (with-narrow-nav (b :text "abcd efgh" :point 5)
    (%narrow 0 7)
    (limn/text-nav:kill-word (mmbuf32-id b))
    (assert-equal "abcd gh" (%txt b) "killed 'ef' (narrow-clipped)")))

(deftest nav-narrow-m-d-at-point-max-noop
  "M-d 在 point-max 是 no-op。"
  (with-narrow-nav (b :text "abcdef" :point 3)
    (%narrow 0 3)
    (limn/text-nav:kill-word (mmbuf32-id b))
    (assert-equal "abcdef" (%txt b) "no edit at point-max")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; skip-syntax-forward / -backward
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-skip-syntax-forward-stops-at-point-max
  "skip-syntax-forward 不會越過 point-max。"
  ;; All word chars. cursor=0, narrow [0, 4). skip-word → stops at 4.
  (with-narrow-nav (b :text "aaaaaa" :point 0)
    (%narrow 0 4)
    (limn/text-nav:skip-syntax-forward "w" (mmbuf32-id b))
    (assert-eql 4 (%cur b) "skip-syntax-forward clamped to point-max")))

(deftest nav-narrow-skip-syntax-backward-stops-at-point-min
  "skip-syntax-backward 不會越過 point-min。"
  (with-narrow-nav (b :text "aaaaaa" :point 6)
    (%narrow 2 6)
    (limn/text-nav:skip-syntax-backward "w" (mmbuf32-id b))
    (assert-eql 2 (%cur b) "skip-syntax-backward clamped to point-min")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; widen-then-act baseline (no narrow → original semantics intact)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest nav-narrow-no-narrow-full-buffer-access
  "沒有 narrow 時 M-> 仍到 buffer end（baseline preserved）。"
  (with-narrow-nav (b :text "abcdef" :point 0)
    ;; no narrow applied
    (limn/text-nav:end-of-buffer (mmbuf32-id b))
    (assert-eql 6 (%cur b) "no narrow: M-> to text-end 6")))

(deftest nav-narrow-no-narrow-m<-zero
  "沒有 narrow 時 M-< 到 0。"
  (with-narrow-nav (b :text "abcdef" :point 4)
    (limn/text-nav:beginning-of-buffer (mmbuf32-id b))
    (assert-eql 0 (%cur b) "no narrow: M-< to 0")))
