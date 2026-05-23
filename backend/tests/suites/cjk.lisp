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
;;;;         test/inject-ime-preedit :text :frame-id   (NEW v0.16)
;;;;         test/inject-ime-commit  :text :frame-id   (existed since v0.7)
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
   codepoint, not at the corresponding UTF-16 index."
  (let ((b (open-text-buffer)))
    (when b
      (send! "buffer/insert" :|buffer-id| b :|at| 0 :|text| "🌟🌟🌟")
      (send! "buffer/cursor-set" :|buffer-id| b :|offset| 2)
      (assert-equal 2 (buf-cursor b) "cursor=2 (codepoint)")
      (send! "buffer/insert" :|buffer-id| b :|offset| 2 :|text| "Z")
      (assert-equal "🌟🌟Z🌟" (buf-text b)
                    "Z inserts between codepoints 2 and 3"))))

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
  "test/inject-ime-preedit pushes an ime-preedit event with the
   composition string. This is the in-progress text the user is
   composing (not yet committed to any buffer)."
  (drain-events)
  (send! "test/inject-ime-preedit" :|text| "ち" :|frame-id| "f1")
  (let ((ev (read-event :type "ime-preedit" :timeout 1)))
    (assert-true ev "ime-preedit event arrived")
    (when ev
      (assert-equal "ち" (getf ev :|text|) "event :text matches"))))

(deftest test-ime-inject-preedit-text-evolves
  "Successive preedits represent the evolving composition; each
   produces an event with the current :text."
  (drain-events)
  (send! "test/inject-ime-preedit" :|text| "に")
  (let ((e1 (read-event :type "ime-preedit" :timeout 1)))
    (assert-true e1 "first preedit fired")
    (when e1 (assert-equal "に" (getf e1 :|text|))))
  (send! "test/inject-ime-preedit" :|text| "にほん")
  (let ((e2 (read-event :type "ime-preedit" :timeout 1)))
    (assert-true e2 "second preedit fired")
    (when e2 (assert-equal "にほん" (getf e2 :|text|) "evolved text"))))

(deftest test-ime-inject-commit-still-fires
  "test/inject-ime-commit (existing since v0.7) regression: still
   fires ime-commit event with :text."
  (drain-events)
  (send! "test/inject-ime-commit" :|text| "日本" :|frame-id| "f1")
  (let ((ev (read-event :type "ime-commit" :timeout 1)))
    (assert-true ev "ime-commit event arrived")
    (when ev (assert-equal "日本" (getf ev :|text|)))))

(deftest test-ime-preedit-and-commit-distinct-event-types
  "ime-preedit and ime-commit are distinct event types — verify by
   firing one of each and confirming both arrive on their own queues."
  (drain-events)
  (send! "test/inject-ime-preedit" :|text| "に")
  (send! "test/inject-ime-commit"  :|text| "日本")
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
   Pre-v0.16 there's no ime-commit dispatcher — this is RED."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "")
      (send! "test/inject-ime-commit" :|text| "中文")
      (assert-equal "中文" (mbtext)
                    "ime-commit text appended into minibuffer"))
    (send! "minibuffer/close")))

(deftest test-ime-commit-cursor-advances-by-codepoint
  "After ime-commit '🌟', minibuffer cursor advances by 1 codepoint
   (regression — combines IME + non-BMP cursor)."
  (send! "minibuffer/open" :|prompt| "test: ")
  (unwind-protect
    (progn
      (send! "minibuffer/set-text" :|text| "")
      (send! "test/inject-ime-commit" :|text| "🌟")
      (assert-equal 1 (mbcursor)
                    "cursor=1 codepoint after non-BMP ime-commit"))
    (send! "minibuffer/close")))
