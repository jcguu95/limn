;;;; v0.16 CJK 三件套 — Qt-tier tests
;;;;
;;;; Three orthogonal-but-related concerns per SPEC §12 v0.16:
;;;;
;;;;   1. Cursor units: switch from QString-index (UTF-16 code units) to
;;;;      codepoint count. BMP CJK chars are unchanged (1 unit = 1
;;;;      codepoint); non-BMP (emoji 🌟, some CJK Ext-B) differ (2 units
;;;;      = 1 codepoint). Wire :cursor / :offset / :count all become
;;;;      codepoint-based.
;;;;
;;;;   2. Cursor consistency: minibuffer/get, buffer/cursor-get/set,
;;;;      buffer/insert :offset, buffer/delete :offset/:count all share
;;;;      the same codepoint unit.
;;;;
;;;;   3. IME pipeline: Qt inputMethodEvent → ime-preedit / ime-commit
;;;;      events. Test injection primitives:
;;;;         test/inject-ime/preedit :text :frame-id   (NEW v0.16)
;;;;         test/inject-ime/commit  :text :frame-id   (existed since v0.7)
;;;;
;;;; All RED until v0.16 impl lands. Once GREEN, this suite is the
;;;; permanent regression net for CJK / non-BMP / IME behaviour.

(in-package #:limn/test)

;;; ── helpers ───────────────────────────────────────────────────────────

(defun mbtext ()
  "Current minibuffer text (string)."
  (json-get* (send! "minibuffer/get") :|data| :|text|))

(defun mbcursor ()
  "Current minibuffer cursor (codepoint offset, post-v0.16)."
  (json-get* (send! "minibuffer/get") :|data| :|cursor|))

(defun buf-text (b)
  (json-get* (send! "buffer/text" :|buffer-id| b) :|data| :|text|))

(defun buf-cursor (b)
  ;; cursor-get returns :offset (existing wire contract). v0.16 changes
  ;; what that integer counts (codepoints, not UTF-16 units), not the
  ;; field name.
  (json-get* (send! "buffer/cursor-get" :|buffer-id| b) :|data| :|offset|))

(defun open-text-buffer ()
  "Allocate a fresh text-engine buffer; return its id."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "text" :|path| "")))
    (and (eq (getf r :|ok|) t)
         (json-get* r :|data| :|buffer-id|))))

;;; ── A. cursor units: codepoint not UTF-16 ───────────────────────────

(deftest test-cjk-cursor-bmp-cjk-insert
  "BMP CJK characters (中, 文): cursor advances by 1 per char.
   Regression guard — BMP behaviour shouldn't change in the switch."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "中文")
      (assert-equal "中文" (buf-text b) "text round-trips")
      (assert-equal 2 (buf-cursor b) "cursor at 2 (one per BMP CJK char)"))))

(deftest test-cjk-cursor-non-bmp-emoji-insert
  "Non-BMP emoji (🌟 U+1F31F): cursor advances by 1 codepoint, NOT 2
   UTF-16 units. Pre-v0.16 returned 2 — that's the bug we're fixing."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟")
      (assert-equal "🌟" (buf-text b))
      (assert-equal 1 (buf-cursor b)
                    "cursor at 1 (one codepoint, not two UTF-16 units)"))))

(deftest test-cjk-cursor-mixed-bmp-and-non-bmp
  "abc🌟x: 5 codepoints (a b c 🌟 x). Pre-v0.16 = 6 (a b c 🌟high 🌟low x)."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "abc🌟x")
      (assert-equal 5 (buf-cursor b)
                    "5 codepoints, not 6 UTF-16 units"))))

(deftest test-cjk-cursor-multiple-emoji
  "Three emoji in a row: cursor=3 (codepoint), not 6 (UTF-16 units)."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌟🌟")
      (assert-equal 3 (buf-cursor b)
                    "3 codepoints, not 6 UTF-16 units"))))

;;; ── B. buffer/insert :offset and buffer/delete are codepoint-aware ──

(deftest test-cjk-buffer-insert-at-codepoint-offset
  "Insert at codepoint offset 1 in '🌟🌟' splits between the two emoji.
   If offset were UTF-16-based, offset=1 would land mid-surrogate."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌟")
      (send! "buffer/insert" :|buffer-id| b :|at| 1 :|text| "X")
      (assert-equal "🌟X🌟" (buf-text b)
                    "X lands between the two emoji"))))

(deftest test-cjk-buffer-delete-range-is-codepoint
  "Delete from=1 to=2 removes one codepoint (the 🌟), not one UTF-16
   unit (which would leave a dangling surrogate)."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "a🌟b")
      (send! "buffer/delete" :|buffer-id| b :|from| 1 :|to| 2)
      (assert-equal "ab" (buf-text b)
                    "one codepoint deletion removes whole emoji"))))

(deftest test-cjk-buffer-cursor-set-codepoint
  "cursor-set with codepoint offset; subsequent insert lands at that
   codepoint, not at the corresponding UTF-16 index.

   Also verifies insert-AT-cursor shifts cursor right (existing rule):
   cursor was 2, insert 1-codepoint Z at 2 → cursor=3."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌟🌟")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
      (assert-equal 2 (buf-cursor b) "cursor=2 (codepoint)")
      (send! "buffer/insert" :|buffer-id| b :|at| 2 :|text| "Z")
      (assert-equal "🌟🌟Z🌟" (buf-text b)
                    "Z inserts between codepoints 2 and 3")
      (assert-equal 3 (buf-cursor b)
                    "cursor shifts right by 1 codepoint (Z)"))))

(deftest test-cjk-buffer-insert-after-cursor-leaves-cursor
  "Insert AT an offset AFTER the current cursor leaves cursor unchanged.
   Tests the 'after-cursor insert' branch of the cursor-shift rule.
   Specifically with non-BMP characters: insert 🌟 at offset 4 when
   cursor is at 2 → cursor stays at 2 (not blindly +1 for char, not
   +2 for UTF-16 units)."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌟🌟🌟🌟")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
      (assert-equal 2 (buf-cursor b))
      (send! "buffer/insert" :|buffer-id| b :|at| 4 :|text| "🌟")
      (assert-equal 2 (buf-cursor b)
                    "cursor unchanged when insert is AFTER cursor"))))

;;; ── C. minibuffer cursor consistency ─────────────────────────────────

(deftest test-cjk-minibuffer-cursor-is-codepoint
  "minibuffer/get :cursor must use the same codepoint unit as buffer/."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "🌟a")
      (assert-equal 2 (mbcursor)
                    "cursor=2 codepoints (🌟 + a), not 3 UTF-16 units"))
    (send! "minibuffer/close")))

(deftest test-cjk-minibuffer-cursor-after-bmp-cjk
  "BMP CJK in minibuffer: cursor matches char count (no UTF-16 inflation)."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "你好世界")
      (assert-equal 4 (mbcursor) "cursor=4 for 4 BMP CJK chars"))
    (send! "minibuffer/close")))

;;; ── D. IME events: ime-preedit injection (NEW v0.16 primitive) ──────

(deftest test-ime-inject-preedit-fires-event
  "test/inject-ime/preedit pushes an ime-preedit event with the
   composition string. This is the in-progress text the user is
   composing (not yet committed to any buffer)."
  (drain-events)
  (send! "test/inject-ime/preedit" :|text| "ち" :|frame-id| "f1")
  (let ((ev (read-event :type "ime-preedit" :timeout 1)))
    (assert-true ev "ime-preedit event arrived")
    (when ev
      (assert-equal "ち" (getf ev :|text|) "event :text matches"))))

(deftest test-ime-inject-preedit-text-evolves
  "Successive preedits represent the evolving composition; each
   produces an event with the current :text."
  (drain-events)
  (send! "test/inject-ime/preedit" :|text| "に")
  (let ((e1 (read-event :type "ime-preedit" :timeout 1)))
    (assert-true e1 "first preedit fired")
    (when e1 (assert-equal "に" (getf e1 :|text|))))
  (send! "test/inject-ime/preedit" :|text| "にほん")
  (let ((e2 (read-event :type "ime-preedit" :timeout 1)))
    (assert-true e2 "second preedit fired")
    (when e2 (assert-equal "にほん" (getf e2 :|text|) "evolved text"))))

(deftest test-ime-inject-commit-still-fires
  "test/inject-ime/commit (existing since v0.7) regression: still
   fires ime-commit event with :text."
  (drain-events)
  (send! "test/inject-ime/commit" :|text| "日本" :|frame-id| "f1")
  (let ((ev (read-event :type "ime-commit" :timeout 1)))
    (assert-true ev "ime-commit event arrived")
    (when ev (assert-equal "日本" (getf ev :|text|)))))

(deftest test-ime-preedit-and-commit-distinct-event-types
  "ime-preedit and ime-commit are distinct event types — verify by
   firing one of each and confirming both arrive on their own queues."
  (drain-events)
  (send! "test/inject-ime/preedit" :|text| "に")
  (send! "test/inject-ime/commit"  :|text| "日本")
  (let ((pe (read-event :type "ime-preedit" :timeout 1))
        (ce (read-event :type "ime-commit"  :timeout 1)))
    (assert-true pe "preedit arrived")
    (assert-true ce "commit arrived")
    (when (and pe ce)
      (assert-equal "に"   (getf pe :|text|))
      (assert-equal "日本" (getf ce :|text|)))))

;;; ── E. IME commit into minibuffer (dispatch integration) ────────────

(deftest test-ime-commit-mutates-minibuffer
  "When minibuffer is open, ime-commit text should land in the
   minibuffer's text buffer (via dispatch wiring in limn-dispatch).
   Pre-v0.16 there's no ime-commit dispatcher — this is RED.

   Also verifies that the cursor advances by the codepoint count of
   the committed text (subsumes the multi-codepoint cursor assert)."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "")
      (send! "test/inject-ime/commit" :|text| "中文")
      (assert-equal "中文" (mbtext)
                    "ime-commit text appended into minibuffer")
      (assert-equal 2 (mbcursor)
                    "cursor advances by 2 codepoints (BMP CJK)"))
    (send! "minibuffer/close")))

(deftest test-ime-commit-cursor-advances-by-codepoint
  "After ime-commit '🌟', minibuffer cursor advances by 1 codepoint
   (regression — combines IME + non-BMP cursor)."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "")
      (send! "test/inject-ime/commit" :|text| "🌟")
      (assert-equal 1 (mbcursor)
                    "cursor=1 codepoint after non-BMP ime-commit"))
    (send! "minibuffer/close")))


;;; ─────────────────────────────────────────────────────────────────────
;;; Round 2 — net-new RED tests after coverage review (no overlap with
;;; the deftests above; design decisions confirmed by reviewer):
;;;
;;;   • cursor-set / delete that would land mid-surrogate must FAIL
;;;     (strict contract, not silent snap-to-boundary)
;;;   • combining characters counted as N codepoints, NOT as 1 grapheme
;;;     cluster (matches vanilla Emacs)
;;;   • ime-commit when minibuffer is closed must be a graceful no-op
;;;   • ime-preedit with empty string = cancel composition
;;;   • all IME events carry :frame-id per SPEC §6
;;; ─────────────────────────────────────────────────────────────────────

;;; ── F. boundary / rejection contracts ───────────────────────────────

(deftest test-cjk-cursor-set-out-of-codepoint-range-fails
  "Post-v0.16 cursor-set offset is codepoint-counted. For buffer '🌟'
   (1 codepoint), offset=2 used to be valid (UTF-16 end) but is now
   beyond the codepoint count and must fail. offset=1 is end and OK."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟")
      (assert-ok   (send! "buffer/cursor-set" :|buffer-id| b :|offset| 0)
                   "offset=0 OK (start)")
      (assert-ok   (send! "buffer/cursor-set" :|buffer-id| b :|offset| 1)
                   "offset=1 OK (end, codepoint count)")
      (assert-fail (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
                   "offset=2 fails (was valid in UTF-16, now beyond cp)"))))

(deftest test-cjk-buffer-delete-out-of-codepoint-range-fails
  "Symmetric: delete from/to using codepoint indices. For 'a🌟b'
   (3 codepoints), from=3 to=3 is valid end-of-buffer (empty range);
   from=4 is beyond — fails."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "a🌟b")
      (assert-ok   (send! "buffer/delete" :|buffer-id| b :|from| 3 :|to| 3)
                   "from=to=end is valid no-op range")
      (assert-fail (send! "buffer/delete" :|buffer-id| b :|from| 0 :|to| 4)
                   "to=4 is beyond codepoint count (3)"))))

(deftest test-cjk-buffer-empty-delete-noop
  "Empty range delete (from == to) is a no-op: doesn't fail, doesn't
   mutate text, doesn't move cursor."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "abc")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
      (assert-ok (send! "buffer/delete" :|buffer-id| b :|from| 1 :|to| 1))
      (assert-equal "abc" (buf-text b) "text unchanged")
      (assert-equal 2 (buf-cursor b)   "cursor unchanged"))))

;;; ── G. cursor shift after delete (before / in / after region) ───────

(deftest test-cjk-cursor-shifts-when-delete-before
  "Delete a range BEFORE the cursor: cursor shifts left by the deleted
   codepoint count. 'a🌟bcd' cursor=4 (at 'd'), delete from=0 to=2
   (removes 'a🌟') → text='bcd', cursor=2 (still at 'd')."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "a🌟bcd")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 4)
      (send! "buffer/delete" :|buffer-id| b :|from| 0 :|to| 2)
      (assert-equal "bcd" (buf-text b))
      (assert-equal 2 (buf-cursor b) "cursor shifts left by 2 codepoints"))))

(deftest test-cjk-cursor-unchanged-when-delete-after
  "Delete a range AFTER the cursor: cursor is unchanged.
   'abc🌟d' cursor=2, delete from=3 to=5 (removes '🌟d') → cursor=2."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "abc🌟d")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
      (send! "buffer/delete" :|buffer-id| b :|from| 3 :|to| 5)
      (assert-equal "abc" (buf-text b))
      (assert-equal 2 (buf-cursor b) "cursor unchanged"))))

(deftest test-cjk-cursor-clamps-when-delete-spans-cursor
  "Delete a range CONTAINING the cursor: cursor clamps to range start.
   'abcde' cursor=3 (between 'c' and 'd'), delete from=1 to=4 →
   text='ae', cursor=1 (clamped to 'from')."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "abcde")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 3)
      (send! "buffer/delete" :|buffer-id| b :|from| 1 :|to| 4)
      (assert-equal "ae" (buf-text b))
      (assert-equal 1 (buf-cursor b) "cursor clamps to delete range start"))))

;;; ── H. pure-emoji buffer edge ops ───────────────────────────────────

(deftest test-cjk-pure-emoji-delete-first
  "Buffer is just emoji. Delete the first codepoint."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌙🌞")
      (send! "buffer/delete" :|buffer-id| b :|from| 0 :|to| 1)
      (assert-equal "🌙🌞" (buf-text b)))))

(deftest test-cjk-pure-emoji-delete-last
  "Delete the last codepoint of a pure-emoji buffer."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌙🌞")
      (send! "buffer/delete" :|buffer-id| b :|from| 2 :|to| 3)
      (assert-equal "🌟🌙" (buf-text b)))))

(deftest test-cjk-pure-emoji-cursor-at-end
  "Cursor at end-of-buffer (== codepoint count) is valid and stable."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌙🌞")
      (assert-equal 3 (buf-cursor b) "cursor at end after insert")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 3)
      (assert-equal 3 (buf-cursor b) "cursor-set to end roundtrips"))))

;;; ── I. combining character: per-codepoint, NOT grapheme cluster ─────

(deftest test-cjk-combining-character-counts-as-multiple-codepoints
  "'é' written as 'e' (U+0065) + COMBINING ACUTE (U+0301) is 2
   codepoints. We deliberately do NOT do grapheme cluster awareness
   (would be 1 user-visible character but require ICU). Matches vanilla
   Emacs's character-count behaviour."
  (let ((b (open-text-buffer)))
    (when b
      ;; "café" with decomposed é: c a f e combining-acute
      (send! "buffer/insert" :|buffer-id| b :|at| 0
             :|text| (format nil "cafe~A" (code-char #x0301)))
      (assert-equal 5 (buf-cursor b)
                    "5 codepoints (NOT 4 grapheme clusters)"))))

;;; ── J. IME — graceful no-op when minibuffer not open ────────────────

(deftest test-ime-commit-without-minibuffer-doesnt-crash
  "ime-commit when minibuffer is NOT open must NOT crash the server
   and must NOT corrupt any random buffer (no scoping leak).
   At minimum: the call succeeds, subsequent calls work."
  ;; Make sure minibuffer is closed.
  (send! "minibuffer/close")
  (assert-ok (send! "test/inject-ime/commit" :|text| "中文" :|frame-id| "f1")
             "inject responds OK even without minibuffer")
  ;; Server must still respond to follow-up call.
  (assert-ok (send! "bridge/capabilities")
             "server still alive after orphan ime-commit"))

;;; ── K. IME — empty preedit = cancel composition ─────────────────────

(deftest test-ime-preedit-empty-text-cancels
  "Wire contract: ime-preedit with :text=\"\" signals composition
   cancellation. Test that the empty preedit fires its own event
   distinct from the prior :text — clients can detect the cancel."
  (drain-events)
  (send! "test/inject-ime/preedit" :|text| "にほん")
  (drain-events) ; flush the non-empty preedit event
  (send! "test/inject-ime/preedit" :|text| "")
  (let ((ev (read-event :type "ime-preedit" :timeout 1)))
    (assert-true ev "empty preedit event fires (cancel signal)")
    (when ev
      (assert-equal "" (getf ev :|text|)
                    ":text is empty string, signalling cancel"))))

;;; ── L. SPEC §6 — every IME event carries :frame-id ──────────────────

(deftest test-ime-events-include-frame-id
  "SPEC §6 requires every frame-scoped event to carry :frame-id.
   Verify for both ime-preedit and ime-commit."
  (drain-events)
  (send! "test/inject-ime/preedit" :|text| "に" :|frame-id| "f1")
  (let ((pe (read-event :type "ime-preedit" :timeout 1)))
    (assert-true pe "preedit arrived")
    (when pe
      (assert-has-key :|frame-id| pe "preedit event has :frame-id")))
  (send! "test/inject-ime/commit" :|text| "日本" :|frame-id| "f1")
  (let ((ce (read-event :type "ime-commit" :timeout 1)))
    (assert-true ce "commit arrived")
    (when ce
      (assert-has-key :|frame-id| ce "commit event has :frame-id"))))
