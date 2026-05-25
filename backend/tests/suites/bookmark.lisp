;;;; v0.17 bookmark wire primitives — Qt-tier tests.
;;;;
;;;; SPEC §12 v0.17 / §5.x:
;;;;   bookmark/list-native :buffer-id    → PDF native outline tree
;;;;                                        (delegates to existing buffer/toc
;;;;                                        logic; framework users who want
;;;;                                        the embedded TOC use this)
;;;;   bookmark/list  :buffer-id          → user-managed bookmark list
;;;;                                        (in-memory per buffer)
;;;;   bookmark/set   :buffer-id :name :page [:x :y :note]
;;;;                                      → add or update by :name
;;;;   bookmark/get   :buffer-id :name    → one record or fail
;;;;   bookmark/delete :buffer-id :name   → remove or fail (unknown name)
;;;;
;;;; Storage model: per-buffer in-memory hash. Cleared on buffer/close.
;;;; Persistence (sidecar file / native outline rewrite / hybrid) is
;;;; entirely user-Lisp territory — framework doesn't choose.

(in-package #:limn/test)

;;; ── helpers ───────────────────────────────────────────────────────────

(defun bm-set! (buf name &key (page 0) (x 0.0) (y 0.0) (note ""))
  (send! "bookmark/set"
         :|buffer-id| buf :|name| name :|page| page
         :|x| x :|y| y :|note| note))

(defun bm-get (buf name)
  (send! "bookmark/get" :|buffer-id| buf :|name| name))

(defun bm-delete! (buf name)
  (send! "bookmark/delete" :|buffer-id| buf :|name| name))

(defun bm-list (buf)
  (send! "bookmark/list" :|buffer-id| buf))

(defun bm-list-native (buf)
  (send! "bookmark/list-native" :|buffer-id| buf))

;;; v0.37 Phase F: clear both bookmark maps before EACH test so the
;;; path-keyed mirror (which persists across buffer/close, by design
;;; — see v027-workflow Ω9a) doesn't leak state from one test into
;;; the next.  The fixture is reused across tests in this suite, so
;;; without an explicit reset the second test sees the first test's
;;; bookmarks under the new buffer-id (hydration kicks in).
(pre-test-hook (send! "bookmark/_test-reset"))

;;; ── A. set + get round-trip ──────────────────────────────────────────

(deftest test-bookmark-set-and-get-roundtrip
  "After bookmark/set, bookmark/get returns the stored record."
  (with-buffer (buf)
    (assert-ok (bm-set! buf "ch1" :page 2))
    (let* ((r (bm-get buf "ch1"))
           (d (and (eq (getf r :|ok|) t) (getf r :|data|))))
      (assert-ok r "get returns ok")
      (assert-equal "ch1" (getf d :|name|) "name preserved")
      (assert-equal 2     (getf d :|page|) "page preserved"))))

(deftest test-bookmark-set-all-optional-fields
  "x, y, note all roundtrip via get."
  (with-buffer (buf)
    (assert-ok (bm-set! buf "intro" :page 0
                        :x 0.42 :y 0.31 :note "first page"))
    (let* ((d (json-get* (bm-get buf "intro") :|data|)))
      (assert-equal 0       (getf d :|page|))
      (assert-true (< (abs (- (getf d :|x|) 0.42)) 0.001)  "x preserved")
      (assert-true (< (abs (- (getf d :|y|) 0.31)) 0.001)  "y preserved")
      (assert-equal "first page" (getf d :|note|)         "note preserved"))))

(deftest test-bookmark-set-defaults-when-omitted
  "Omitting :x / :y / :note defaults to 0 / 0 / empty string."
  (with-buffer (buf)
    (assert-ok (send! "bookmark/set"
                      :|buffer-id| buf :|name| "bare" :|page| 1))
    (let ((d (json-get* (bm-get buf "bare") :|data|)))
      (assert-true (< (abs (or (getf d :|x|) 1.0)) 0.001) "x default 0")
      (assert-true (< (abs (or (getf d :|y|) 1.0)) 0.001) "y default 0")
      (assert-equal "" (or (getf d :|note|) "") "note default empty"))))

;;; ── B. set updates existing (same name = upsert) ─────────────────────

(deftest test-bookmark-set-updates-existing
  "Second set with same name replaces first; list shows one entry."
  (with-buffer (buf)
    (bm-set! buf "k" :page 0 :note "first")
    (bm-set! buf "k" :page 3 :note "second")
    (let ((d (json-get* (bm-get buf "k") :|data|)))
      (assert-equal 3 (getf d :|page|) "page updated")
      (assert-equal "second" (getf d :|note|) "note updated"))
    (let ((items (json-get* (bm-list buf) :|data| :|items|)))
      (assert-equal 1 (length items)
                    "update is upsert, not duplicate insert"))))

;;; ── C. get / delete on unknown name fail ─────────────────────────────

(deftest test-bookmark-get-unknown-fails
  "bookmark/get for a name that wasn't set returns ok=false."
  (with-buffer (buf)
    (assert-fail (bm-get buf "nope") "get unknown fails")))

(deftest test-bookmark-delete-unknown-fails
  "bookmark/delete on unknown name fails (strict — caller can check
   bookmark/list first if they want graceful semantics)."
  (with-buffer (buf)
    (assert-fail (bm-delete! buf "nope") "delete unknown fails")))

(deftest test-bookmark-delete-then-get-fails
  "After delete, get is no longer found."
  (with-buffer (buf)
    (bm-set! buf "tmp" :page 1)
    (assert-ok (bm-get buf "tmp") "get works pre-delete")
    (assert-ok (bm-delete! buf "tmp") "delete works")
    (assert-fail (bm-get buf "tmp") "get fails post-delete")))

;;; ── D. list returns all (in insertion order) + empty case ────────────

(deftest test-bookmark-list-empty-on-fresh-buffer
  "Freshly-opened buffer has zero user bookmarks."
  (with-buffer (buf)
    (let* ((r (bm-list buf))
           (items (json-get* r :|data| :|items|)))
      (assert-ok r)
      (assert-equal 0 (length items) "empty list"))))

(deftest test-bookmark-list-returns-all-set
  "Three sets → list returns three items, names match (set semantics)."
  (with-buffer (buf)
    (bm-set! buf "a" :page 0)
    (bm-set! buf "b" :page 1)
    (bm-set! buf "c" :page 2)
    (let* ((items (json-get* (bm-list buf) :|data| :|items|))
           (names (sort (mapcar (lambda (e) (getf e :|name|)) items)
                        #'string<)))
      (assert-equal 3 (length items))
      (assert-equal '("a" "b" "c") names))))

(deftest test-bookmark-list-preserves-insertion-order
  "list returns items in insertion order (deterministic for clients
   that want stable iteration; user can re-sort by any field)."
  (with-buffer (buf)
    (bm-set! buf "z" :page 0)
    (bm-set! buf "a" :page 1)
    (bm-set! buf "m" :page 2)
    (let* ((items (json-get* (bm-list buf) :|data| :|items|))
           (names (mapcar (lambda (e) (getf e :|name|)) items)))
      (assert-equal '("z" "a" "m") names "insertion order"))))

;;; ── E. per-buffer isolation ──────────────────────────────────────────

(deftest test-bookmark-isolated-across-buffers
  "Setting a bookmark on bufA doesn't leak into bufB."
  (with-buffer (bA)
    (with-buffer (bB)
      (bm-set! bA "only-A" :page 0)
      (let* ((a-items (json-get* (bm-list bA) :|data| :|items|))
             (b-items (json-get* (bm-list bB) :|data| :|items|)))
        (assert-equal 1 (length a-items) "bA has 1")
        (assert-equal 0 (length b-items) "bB has 0 (no leak)")))))

(deftest test-bookmark-delete-doesnt-touch-other-buffer
  "Deleting in bufA leaves bufB's same-named bookmark intact."
  (with-buffer (bA)
    (with-buffer (bB)
      (bm-set! bA "k" :page 0 :note "in-A")
      (bm-set! bB "k" :page 0 :note "in-B")
      (bm-delete! bA "k")
      (assert-fail (bm-get bA "k") "bA deleted")
      (let ((d (json-get* (bm-get bB "k") :|data|)))
        (assert-equal "in-B" (getf d :|note|) "bB intact")))))

;;; ── F. page validation ───────────────────────────────────────────────

(deftest test-bookmark-set-page-out-of-range-fails
  "Page must be in [0, num_pages); -1 and num_pages both fail."
  (with-buffer (buf)
    ;; fixture is 6 pages → valid 0..5
    (assert-ok   (bm-set! buf "ok1" :page 0))
    (assert-ok   (bm-set! buf "ok2" :page 5))
    (assert-fail (bm-set! buf "bad" :page -1) ":page=-1 rejected")
    (assert-fail (bm-set! buf "bad" :page 99) ":page beyond doc rejected")))

;;; ── G. name validation ───────────────────────────────────────────────

(deftest test-bookmark-empty-name-rejected
  "Empty :name is invalid for set / get / delete (caller bug we want
   to surface, not silently accept)."
  (with-buffer (buf)
    (assert-fail (bm-set! buf "" :page 0))
    (assert-fail (bm-get buf ""))
    (assert-fail (bm-delete! buf ""))))

;;; ── H. non-mupdf buffer rejected ─────────────────────────────────────

(deftest test-bookmark-rejects-text-engine-buffer
  "bookmark/* requires a mupdf-engine buffer (bookmarks describe
   document positions). Calling on a text-engine buffer fails clearly."
  (let* ((r (send! "bridge/engine-load"
                   :|win-id| "w1" :|engine| "text" :|path| ""))
         (tid (json-get* r :|data| :|buffer-id|)))
    (when tid
      (assert-fail (bm-set! tid "x" :page 0)
                   "set on text-engine buffer rejected")
      (assert-fail (bm-list tid) "list on text-engine buffer rejected"))))

;;; ── I. bookmarks scoped to buffer lifetime (close clears) ────────────

(deftest test-bookmark-cleared-on-buffer-close
  "Close + reopen (different buffer-id) starts with no bookmarks.
   Persistence is user-Lisp territory; framework provides only
   in-memory store."
  (let* ((r1  (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "mupdf"
                     :|path| *fixture-pdf*))
         (b1  (json-get* r1 :|data| :|buffer-id|)))
    (when b1
      (bm-set! b1 "before-close" :page 0)
      (send! "buffer/close" :|buffer-id| b1)
      (let* ((r2 (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf"
                        :|path| *fixture-pdf*))
             (b2 (json-get* r2 :|data| :|buffer-id|)))
        (when b2
          (let* ((items (json-get* (bm-list b2) :|data| :|items|)))
            (assert-equal 0 (length items)
                          "fresh buffer-id has no bookmarks"))
          (send! "buffer/close" :|buffer-id| b2))))))

;;; ── J. list-native delegates to PDF outline ──────────────────────────

(deftest test-bookmark-list-native-returns-tree
  "bookmark/list-native returns the PDF's embedded outline shape under
   :items (same data buffer/toc provides). We just check the shape is
   correct (items field present and list-typed); the actual content
   depends on whether the fixture PDF has an outline."
  (with-buffer (buf)
    (let* ((r     (bm-list-native buf))
           (data  (json-get* r :|data|))
           (items (getf data :|items|)))
      (assert-ok r "list-native ok")
      (assert-true (or (null items) (listp items))
                   ":items field is a list (possibly empty)"))))

;;; ── K. unknown buffer-id rejected ────────────────────────────────────

(deftest test-bookmark-unknown-buffer-fails
  "All bookmark/* commands fail cleanly on unknown buffer-id."
  (assert-fail (send! "bookmark/list" :|buffer-id| "b-nope"))
  (assert-fail (send! "bookmark/set"  :|buffer-id| "b-nope"
                                       :|name| "x" :|page| 0))
  (assert-fail (send! "bookmark/get"  :|buffer-id| "b-nope" :|name| "x"))
  (assert-fail (send! "bookmark/delete" :|buffer-id| "b-nope" :|name| "x")))

;;; ── L. CJK / Unicode in name and note ────────────────────────────────

(deftest test-bookmark-cjk-name-and-note
  "Name and note round-trip CJK / non-BMP correctly (uses same UTF-8
   wire path that v0.16 codepoint work hardened)."
  (with-buffer (buf)
    (bm-set! buf "第一章" :page 0 :note "重点：🌟 introduction")
    (let ((d (json-get* (bm-get buf "第一章") :|data|)))
      (assert-equal "第一章" (getf d :|name|))
      (assert-equal "重点：🌟 introduction" (getf d :|note|)))))
