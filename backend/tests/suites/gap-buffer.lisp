;;;; Gap-buffer integration tests — v0.20 TDD
;;;;
;;;; These tests verify the OBSERVABLE wire-level contract for text-engine
;;;; buffer editing after the internal QString → GapBuffer refactor.
;;;;
;;;; The refactor is purely internal (QHash<QString,QString> → GapBuffer).
;;;; Wire contract (buffer/insert, buffer/delete, buffer/cursor-get/set,
;;;; buffer/text) must be IDENTICAL before and after.
;;;;
;;;; All existing tests in buffer-edit.lisp must continue to pass; this
;;;; suite adds scenarios that specifically exercise GAP MOVEMENT patterns:
;;;;   - insert at different positions to force gap relocation
;;;;   - remove at non-adjacent positions
;;;;   - alternating insert/remove at opposite ends
;;;;   - CJK (BMP multibyte) + emoji (non-BMP surrogate pair) offset math
;;;;   - stress: build 500-char string via append, then mass-delete
;;;;   - chrome buffers (*minibuffer* etc.) also go through GapBuffer
;;;;
;;;; Run standalone:
;;;;   sbcl --script backend/tests/run-all.lisp
;;;; or via the full test runner.

(in-package #:limn/test)

;;; ── Helpers ──────────────────────────────────────────────────────────────

(defun buf-text (buf)
  "Return the text content of BUF as a string (works for both response shapes)."
  (let* ((r (send! "buffer/text" :|buffer-id| buf))
         (d (getf r :|data|)))
    (assert-ok r "buffer/text ok")
    (or (getf d :|text|)
        (apply #'concatenate 'string
               (mapcar (lambda (w) (getf w :|text|))
                       (getf d :|words|))))))

(defun buf-cursor (buf)
  "Return current codepoint cursor offset for BUF."
  (json-get* (send! "buffer/cursor-get" :|buffer-id| buf)
             :|data| :|offset|))

;;; ── Gap movement via insert at different positions ────────────────────────

(deftest test-gb-insert-backwards-builds-correct-string
  "Insert chars in reverse order (each insert moves the gap left)."
  (with-text-buffer (buf)
    ;; Build "abcd" by inserting each char at the front.
    ;; After each insert the gap sits at position 0; next insert moves it left
    ;; again — exercising repeated leftward gap movement.
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "d")
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "c")
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "b")
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "a")
    (assert-equal "abcd" (buf-text buf) "backwards insert builds correct string")))

(deftest test-gb-insert-alternating-ends-builds-correct-string
  "Alternate inserting at position 0 and at the end (gap bounces back and forth)."
  (with-text-buffer (buf)
    ;; Each even step inserts at the front, each odd step appends.
    ;; Gap must traverse the full buffer length on each step — maximally
    ;; stressful for gap movement correctness.
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "1") ; "1"
    (send! "buffer/insert" :|buffer-id| buf :|at| 1 :|text| "2") ; "12"
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "0") ; "012"
    (send! "buffer/insert" :|buffer-id| buf :|at| 3 :|text| "3") ; "0123"
    (assert-equal "0123" (buf-text buf) "alternating-end inserts correct")))

(deftest test-gb-insert-middle-repeatedly
  "Insert at the exact midpoint of the buffer each time (gap moves to mid each step)."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "AZ")         ; cursor=2
    (send! "buffer/insert" :|buffer-id| buf :|at| 1 :|text| "BY") ; "ABYZ" wait
    ;; After "AZ", insert "BY" at 1: "A" + "BY" + "Z" = "ABYZ"
    (send! "buffer/insert" :|buffer-id| buf :|at| 2 :|text| "C")  ; "ABCYZ"
    (assert-equal "ABCYZ" (buf-text buf) "repeated mid-insert correct")))

;;; ── Remove at non-adjacent positions ─────────────────────────────────────

(deftest test-gb-remove-at-different-positions-each-time
  "Remove slices that are far apart, forcing gap relocation each delete."
  (with-text-buffer (buf)
    ;; Start: "hello world foo bar"
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world foo bar")
    ;; Remove " bar" (15..19) — gap moves to end
    (send! "buffer/delete" :|buffer-id| buf :|from| 15 :|to| 19)
    ;; Remove " foo" (11..15) — gap now at 15, moves left to 11
    (send! "buffer/delete" :|buffer-id| buf :|from| 11 :|to| 15)
    ;; Remove "hello " (0..6) — gap moves far left to 0
    (send! "buffer/delete" :|buffer-id| buf :|from| 0 :|to| 6)
    (assert-equal "world" (buf-text buf)
                  "non-adjacent removes leave correct remainder")))

(deftest test-gb-interleaved-insert-delete-far-apart
  "Interleave inserts and deletes at opposite ends of the buffer."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "........") ; 8 dots
    ;; Append "Z" (end), remove first "." (front), repeat 4 times.
    (dotimes (_ 4)
      (let ((len (length (buf-text buf))))
        (send! "buffer/insert" :|buffer-id| buf :|at| len :|text| "Z")
        (send! "buffer/delete" :|buffer-id| buf :|from| 0 :|to| 1)))
    ;; Started with 8 dots, added 4 Zs, removed 4 dots.
    ;; Remaining: 4 dots + 4 Zs = "....ZZZZ"
    (assert-equal "....ZZZZ" (buf-text buf)
                  "alternating append/front-delete correct")))

;;; ── Cursor tracking across gap moves ─────────────────────────────────────

(deftest test-gb-cursor-stable-across-gap-move-insert
  "Inserting BEFORE cursor shifts the cursor right by the inserted length."
  (with-text-buffer (buf)
    ;; Insert "world" at cursor (0) → cursor = 5
    (send! "buffer/insert" :|buffer-id| buf :|text| "world")
    (assert-equal 5 (buf-cursor buf) "cursor after first insert")
    ;; Insert "hello " BEFORE cursor (at offset 0) — cursor was AFTER that
    ;; position, so it shifts right by 6.
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "hello ")
    (assert-equal 11 (buf-cursor buf) "cursor shifted by prepend length")))

(deftest test-gb-cursor-stable-across-delete-before-cursor
  "Deleting a range BEFORE cursor shifts cursor left by the deleted count."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world") ; cursor=11
    ;; Delete "hello " (0..6) — cursor was 11, now shifts to 5.
    (send! "buffer/delete" :|buffer-id| buf :|from| 0 :|to| 6)
    (assert-equal 5 (buf-cursor buf)
                  "cursor shifted left after delete before cursor")))

(deftest test-gb-cursor-snaps-when-inside-deleted-range
  "Cursor inside the deleted range snaps to the start of the deleted range."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "abcdef")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 3) ; cursor inside "cde"
    ;; Delete "cde" (2..5) — cursor was at 3 which is inside → snap to 2.
    (send! "buffer/delete" :|buffer-id| buf :|from| 2 :|to| 5)
    (assert-equal 2 (buf-cursor buf)
                  "cursor snapped to start of deleted range")))

;;; ── BMP CJK: each codepoint = 1 UTF-16 unit ──────────────────────────────

(deftest test-gb-cjk-insert-and-read
  "BMP CJK characters: 1 codepoint = 1 wire-offset unit."
  (with-text-buffer (buf)
    ;; Insert 你好 (2 CJK characters)
    (send! "buffer/insert" :|buffer-id| buf :|text| "你好")
    (assert-equal 2 (buf-cursor buf) "cursor after 2 CJK chars")
    ;; Insert 世界 at offset 1 → 你世界好
    (send! "buffer/insert" :|buffer-id| buf :|at| 1 :|text| "世界")
    (assert-equal "你世界好" (buf-text buf) "CJK mid-insert correct")))

(deftest test-gb-cjk-delete-by-codepoint
  "Delete removes the correct codepoints for BMP CJK."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "你好世界")
    ;; Delete "好世" (offsets 1..3)
    (send! "buffer/delete" :|buffer-id| buf :|from| 1 :|to| 3)
    (assert-equal "你界" (buf-text buf) "CJK delete correct")))

;;; ── Non-BMP emoji: each codepoint = 2 UTF-16 units ──────────────────────
;;;
;;; SPEC v0.16: wire offsets are CODEPOINTS.  The GapBuffer stores UTF-16
;;; units internally.  LimnCommand's cp_to_qsidx / qsidx_to_cp converters
;;; must correctly cross the GapBuffer API with UTF-16 indices.
;;;
;;; An emoji like 😀 (U+1F600) is 1 codepoint but 2 UTF-16 units.
;;; So at the wire level: insert 😀 → cursor advances by 1 (codepoint);
;;; internally GapBuffer receives insert(0, "😀") with QString.length()==2.

(deftest test-gb-emoji-codepoint-length-at-wire
  "Emoji inserts advance cursor by 1 codepoint (not 2 UTF-16 units)."
  (with-text-buffer (buf)
    ;; Insert one emoji (1 codepoint)
    (send! "buffer/insert" :|buffer-id| buf :|text| "😀")
    (assert-equal 1 (buf-cursor buf)
                  "cursor after one emoji = 1 codepoint")))

(deftest test-gb-emoji-delete-removes-whole-codepoint
  "Deleting an emoji (1 codepoint) via from=0 to=1 removes it completely."
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "a😀b")
    ;; 3 codepoints: "a"=0, "😀"=1, "b"=2
    (send! "buffer/delete" :|buffer-id| buf :|from| 1 :|to| 2) ; remove 😀
    (assert-equal "ab" (buf-text buf) "emoji delete at wire codepoint boundary")))

(deftest test-gb-mixed-ascii-cjk-emoji-offsets
  "Mixed content: ASCII + CJK + emoji; cursor math stays consistent."
  (with-text-buffer (buf)
    ;; Build: "A你😀B"  → codepoints: A=0, 你=1, 😀=2, B=3
    (send! "buffer/insert" :|buffer-id| buf :|text| "A")
    (send! "buffer/insert" :|buffer-id| buf :|text| "你")
    (send! "buffer/insert" :|buffer-id| buf :|text| "😀")
    (send! "buffer/insert" :|buffer-id| buf :|text| "B")
    (assert-equal 4 (buf-cursor buf) "4 codepoints → cursor=4")
    ;; Delete the CJK char at codepoint offset 1
    (send! "buffer/delete" :|buffer-id| buf :|from| 1 :|to| 2)
    (assert-equal "A😀B" (buf-text buf) "delete CJK from mixed string")))

;;; ── Chrome buffers: "whole-buffer replace" paths ────────────────────────
;;;
;;; These are the callers that do   text_buffers[id] = new_string   or
;;;   text_buffers[id].clear()  in the current C++ code.  After v0.20 those
;;; paths become  GapBuffer::clear()  +  GapBuffer::insert(0, str)  (or just
;;; clear()).  The wire-visible contract must be identical.

(deftest test-gb-minibuffer-set-text-replaces-content
  "minibuffer/set-text replaces the full text and moves cursor to end."
  ;; The typical flow: open minibuffer, type something, then set-text to
  ;; simulate history-recall / completion replacing the entire input.
  (send! "minibuffer/open" :|prompt| "Test: ")
  (unwind-protect
      (progn
        (send! "minibuffer/set-text" :|text| "first")
        (let ((r1 (send! "minibuffer/get")))
          (assert-ok r1 "minibuffer/get after set-text ok")
          (assert-equal "first" (json-get* r1 :|data| :|text|)
                        "text is 'first' after set-text")
          (assert-equal 5 (json-get* r1 :|data| :|cursor|)
                        "cursor at end (codepoint 5)"))
        ;; Replace again — exercises GapBuffer::clear() + insert()
        (send! "minibuffer/set-text" :|text| "replaced content")
        (let ((r2 (send! "minibuffer/get")))
          (assert-equal "replaced content" (json-get* r2 :|data| :|text|)
                        "second set-text replaces again")
          (assert-equal 16 (json-get* r2 :|data| :|cursor|)
                        "cursor at end of new content")))
    (send! "minibuffer/close")))

(deftest test-gb-message-echo-replaces-echo-area
  "message/echo replaces *echo-area* content (assignment path → GapBuffer::clear()+insert)."
  (send! "message/echo" :|text| "first echo")
  (let* ((r1    (send! "buffer/text" :|buffer-id| "*echo-area*"))
         (text1 (or (json-get* r1 :|data| :|text|)
                    (apply #'concatenate 'string
                           (mapcar (lambda (w) (getf w :|text|))
                                   (json-get* r1 :|data| :|words|))))))
    (assert-ok r1 "buffer/text *echo-area* ok")
    (assert-equal "first echo" text1 "*echo-area* contains first echo"))
  ;; Overwrite with a different message — second clear()+insert()
  (send! "message/echo" :|text| "second echo")
  (let* ((r2    (send! "buffer/text" :|buffer-id| "*echo-area*"))
         (text2 (or (json-get* r2 :|data| :|text|)
                    (apply #'concatenate 'string
                           (mapcar (lambda (w) (getf w :|text|))
                                   (json-get* r2 :|data| :|words|))))))
    (assert-equal "second echo" text2
                  "*echo-area* contains second echo (not concatenation)")))

(deftest test-gb-message-clear-empties-echo-area
  "message/clear empties *echo-area* (GapBuffer::clear() path)."
  (send! "message/echo" :|text| "something to clear")
  (send! "message/clear")
  (let* ((r    (send! "buffer/text" :|buffer-id| "*echo-area*"))
         (text (or (json-get* r :|data| :|text|)
                   (apply #'concatenate 'string
                          (mapcar (lambda (w) (getf w :|text|))
                                  (json-get* r :|data| :|words|))))))
    (assert-ok r "buffer/text *echo-area* ok after clear")
    (assert-equal "" text "*echo-area* is empty after message/clear")))

;;; ── Chrome buffers go through GapBuffer too ──────────────────────────────

(deftest test-gb-chrome-minibuffer-insert-delete
  "The *minibuffer* chrome buffer also uses GapBuffer after v0.20."
  ;; We open the minibuffer, then use buffer/cursor-get to verify state.
  ;; We cannot use buffer/insert directly on *minibuffer* because its text
  ;; is driven by minibuffer/open + user input events; but buffer/cursor-get
  ;; must still work, proving the chrome buffers are GapBuffer-backed.
  (let ((r (send! "buffer/cursor-get" :|buffer-id| "*minibuffer*")))
    (assert-ok r "*minibuffer* cursor-get succeeds")
    (assert-equal 0 (json-get* r :|data| :|offset|)
                  "*minibuffer* starts at offset 0")))

(deftest test-gb-chrome-messages-buffer-single-append
  "message/log appends to *messages*; content is readable via buffer/text."
  (send! "message/log" :|text| "gap-buffer-test-marker-42")
  (let* ((r (send! "buffer/text" :|buffer-id| "*messages*"))
         (d (getf r :|data|))
         (content (or (getf d :|text|)
                      (apply #'concatenate 'string
                             (mapcar (lambda (w) (getf w :|text|))
                                     (getf d :|words|))))))
    (assert-ok r "*messages* buffer/text succeeds")
    (assert-true (search "gap-buffer-test-marker-42" content)
                 "*messages* contains logged text")))

(deftest test-gb-chrome-messages-multiple-log-accumulate
  "Multiple message/log calls accumulate in order (GapBuffer append fast-path).
   This exercises cmd_message_log's  log.insert(log.length(), newline+text)
   path — the gap should stay at the end and each append is O(text_length)."
  ;; Use unique sentinel strings so we can find them even if *messages*
  ;; already has content from earlier tests.
  (send! "message/log" :|text| "gb-log-line-AAA")
  (send! "message/log" :|text| "gb-log-line-BBB")
  (send! "message/log" :|text| "gb-log-line-CCC")
  (let* ((r (send! "buffer/text" :|buffer-id| "*messages*"))
         (d (getf r :|data|))
         (content (or (getf d :|text|)
                      (apply #'concatenate 'string
                             (mapcar (lambda (w) (getf w :|text|))
                                     (getf d :|words|))))))
    (assert-ok r "*messages* readable after multiple logs")
    ;; All three lines must appear, in order.
    (let ((pos-a (search "gb-log-line-AAA" content))
          (pos-b (search "gb-log-line-BBB" content))
          (pos-c (search "gb-log-line-CCC" content)))
      (assert-true pos-a "gb-log-line-AAA present")
      (assert-true pos-b "gb-log-line-BBB present")
      (assert-true pos-c "gb-log-line-CCC present")
      ;; Relative ordering: A before B before C.
      (when (and pos-a pos-b pos-c)
        (assert-true (< pos-a pos-b) "AAA appears before BBB")
        (assert-true (< pos-b pos-c) "BBB appears before CCC")))))

;;; ── Stress: large sequential build then mass delete ──────────────────────

(deftest test-gb-stress-sequential-build-and-delete
  "Build a 100-char string char-by-char (always append), then delete it all."
  (with-text-buffer (buf)
    ;; Append 100 'x' characters one at a time.
    (dotimes (i 100)
      (let ((len i))
        (send! "buffer/insert" :|buffer-id| buf :|at| len :|text| "x")))
    ;; Verify length via cursor (cursor is at end after last append at len=99→100)
    (assert-equal 100 (buf-cursor buf) "100 appends → cursor=100")
    (assert-equal (make-string 100 :initial-element #\x) (buf-text buf)
                  "100 appended x's correct")
    ;; Delete all in one shot
    (send! "buffer/delete" :|buffer-id| buf :|from| 0 :|to| 100)
    (assert-equal "" (buf-text buf) "mass delete leaves empty buffer")
    (assert-equal 0 (buf-cursor buf) "cursor at 0 after mass delete")))

(deftest test-gb-stress-build-backwards-then-verify
  "Build a 26-char string in reverse order (maximum gap movement), read back."
  (with-text-buffer (buf)
    ;; Insert each letter at the front: final order 'a'..'z'
    (loop for c from (char-code #\z) downto (char-code #\a) do
      (send! "buffer/insert" :|buffer-id| buf :|at| 0
             :|text| (string (code-char c))))
    (assert-equal "abcdefghijklmnopqrstuvwxyz" (buf-text buf)
                  "backwards build gives correct alphabetical string")))
