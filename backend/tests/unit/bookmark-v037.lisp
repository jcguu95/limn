;;;; v0.37 — limn/bookmark RED tests (unit-tier)
;;;;
;;;; Cross-buffer, persistent, name-based bookmarks (Emacs bookmark.el
;;;; analog).  Coexists with the existing PDF single-char wire bookmarks
;;;; in limn-pdf-mode §E — that one is per-buffer / per-doc + single
;;;; char; this one is global / cross-buffer / human-readable name.
;;;;
;;;; Data model (one bookmark):
;;;;   :name    string, unique key in *bookmarks*
;;;;   :handler symbol naming a registered handler (e.g. 'text-mode,
;;;;            'pdf-mode); dispatched on jump
;;;;   :record  plist with handler-specific shape:
;;;;              text-mode → (:file "..." :position N :line L)
;;;;              pdf-mode  → (:doc-hash "..." :path "..."
;;;;                           :page P :y-offset Y :x-offset X)
;;;;
;;;; Public API (limn/bookmark package):
;;;;   make-bookmark / bookmark-name / bookmark-handler / bookmark-record
;;;;   bookmark-add bookmark-remove bookmark-rename
;;;;   bookmark-find bookmark-list bookmark-clear bookmark-count
;;;;   register-handler unregister-handler
;;;;   bookmark-jump  (dispatches via handler)
;;;;   bookmarks-sidecar-path bookmarks-save bookmarks-load
;;;;
;;;; All RED until limn-bookmark.lisp implements them.

;; ── package stub so file loads even before module exists ────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/bookmark)
    (make-package '#:limn/bookmark :use '(#:cl)))
  (dolist (sym '("MAKE-BOOKMARK" "BOOKMARK-NAME" "BOOKMARK-HANDLER"
                 "BOOKMARK-RECORD"
                 "BOOKMARK-ADD" "BOOKMARK-REMOVE" "BOOKMARK-RENAME"
                 "BOOKMARK-FIND" "BOOKMARK-LIST" "BOOKMARK-CLEAR"
                 "BOOKMARK-COUNT"
                 "REGISTER-HANDLER" "UNREGISTER-HANDLER"
                 "BOOKMARK-JUMP"
                 "REGISTER-RECORD-FN" "UNREGISTER-RECORD-FN"
                 "MAKE-CURRENT-RECORD"
                 "BOOKMARKS-SIDECAR-PATH"
                 "BOOKMARKS-SAVE" "BOOKMARKS-LOAD"
                 "*BOOKMARKS*" "*HANDLER-REGISTRY*"))
    (export (intern sym '#:limn/bookmark) '#:limn/bookmark)))

(in-package #:limn/unit-test)

;;; ── B1. struct construction + accessors ─────────────────────────────

(deftest bookmark-b1-make-and-accessors
  "make-bookmark returns an object with name/handler/record readable."
  (let ((b (limn/bookmark:make-bookmark
            :name "intro"
            :handler 'text-mode
            :record '(:file "/tmp/a.txt" :position 42 :line 3))))
    (assert-equal "intro"    (limn/bookmark:bookmark-name b))
    (assert-equal 'text-mode (limn/bookmark:bookmark-handler b))
    (assert-equal 42 (getf (limn/bookmark:bookmark-record b) :position))))

;;; ── B2. add / find / count / clear ──────────────────────────────────

(deftest bookmark-b2-add-and-find
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "ch1" :handler 'text-mode
                                :record '(:file "/x.txt" :position 0)))
  (let ((b (limn/bookmark:bookmark-find "ch1")))
    (assert-true b "find returns the stored bookmark")
    (assert-equal "ch1" (limn/bookmark:bookmark-name b))))

(deftest bookmark-b2-find-unknown-returns-nil
  (limn/bookmark:bookmark-clear)
  (assert-false (limn/bookmark:bookmark-find "ghost")
                "find on missing name returns nil"))

(deftest bookmark-b2-add-replaces-by-name
  "Re-adding with same name overwrites (upsert), not duplicate."
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "k" :handler 'text-mode
                                :record '(:file "/a" :position 0)))
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "k" :handler 'text-mode
                                :record '(:file "/b" :position 99)))
  (assert-equal 1 (limn/bookmark:bookmark-count)
                "second add is upsert, not duplicate")
  (assert-equal "/b"
                (getf (limn/bookmark:bookmark-record
                       (limn/bookmark:bookmark-find "k"))
                      :file)
                "record updated on upsert"))

(deftest bookmark-b2-clear-empties-store
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "a" :handler 'text-mode
                                :record '(:file "/x" :position 0)))
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "b" :handler 'text-mode
                                :record '(:file "/y" :position 0)))
  (assert-equal 2 (limn/bookmark:bookmark-count))
  (limn/bookmark:bookmark-clear)
  (assert-equal 0 (limn/bookmark:bookmark-count) "cleared"))

;;; ── B3. remove ──────────────────────────────────────────────────────

(deftest bookmark-b3-remove-by-name
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "tmp" :handler 'text-mode
                                :record '(:file "/x" :position 0)))
  (assert-true (limn/bookmark:bookmark-find "tmp"))
  (assert-true (limn/bookmark:bookmark-remove "tmp")
               "remove returns truthy on success")
  (assert-false (limn/bookmark:bookmark-find "tmp")
                "gone after remove"))

(deftest bookmark-b3-remove-unknown-returns-nil
  (limn/bookmark:bookmark-clear)
  (assert-false (limn/bookmark:bookmark-remove "ghost")
                "remove on missing name returns nil"))

;;; ── B4. rename ──────────────────────────────────────────────────────

(deftest bookmark-b4-rename-changes-key
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "old" :handler 'text-mode
                                :record '(:file "/x" :position 7)))
  (assert-true (limn/bookmark:bookmark-rename "old" "new"))
  (assert-false (limn/bookmark:bookmark-find "old")
                "old name gone")
  (let ((b (limn/bookmark:bookmark-find "new")))
    (assert-true b "new name resolves")
    (assert-equal 7 (getf (limn/bookmark:bookmark-record b) :position)
                  "record preserved")))

(deftest bookmark-b4-rename-collision-fails
  "Renaming to a name that already exists must fail (return nil) — don't
   silently destroy the other bookmark."
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "a" :handler 'text-mode
                                :record '(:file "/x" :position 0)))
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "b" :handler 'text-mode
                                :record '(:file "/y" :position 0)))
  (assert-false (limn/bookmark:bookmark-rename "a" "b")
                "rename to existing name refused")
  (assert-true (limn/bookmark:bookmark-find "a")
               "original 'a' still there")
  (assert-true (limn/bookmark:bookmark-find "b")
               "victim 'b' untouched"))

;;; ── B5. list (sorted by name, deterministic) ────────────────────────

(deftest bookmark-b5-list-returns-all-sorted-by-name
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "zeta" :handler 'text-mode
                                :record '(:file "/z" :position 0)))
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "alpha" :handler 'text-mode
                                :record '(:file "/a" :position 0)))
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "mu" :handler 'text-mode
                                :record '(:file "/m" :position 0)))
  (let ((names (mapcar #'limn/bookmark:bookmark-name
                       (limn/bookmark:bookmark-list))))
    (assert-equal '("alpha" "mu" "zeta") names
                  "list sorted by name (deterministic for UI)")))

(deftest bookmark-b5-list-empty-when-empty
  (limn/bookmark:bookmark-clear)
  (assert-equal 0 (length (limn/bookmark:bookmark-list))))

;;; ── B6. handler registration + dispatch ─────────────────────────────

(deftest bookmark-b6-register-and-dispatch
  "register-handler installs a jump-fn keyed by handler symbol.
   bookmark-jump dispatches to that fn with the bookmark record."
  (limn/bookmark:bookmark-clear)
  (let ((called nil))
    (limn/bookmark:register-handler
     'test-handler
     (lambda (record) (setf called (getf record :marker))))
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark :name "k" :handler 'test-handler
                                  :record '(:marker 99)))
    (limn/bookmark:bookmark-jump "k")
    (assert-equal 99 called "handler fn received the record")
    (limn/bookmark:unregister-handler 'test-handler)))

(deftest bookmark-b6-jump-unknown-name-signals
  "bookmark-jump on a name that doesn't exist raises an error so the
   user sees feedback (Emacs convention: silent no-op hides bugs)."
  (limn/bookmark:bookmark-clear)
  (assert-error error
                (limn/bookmark:bookmark-jump "no-such")))

(deftest bookmark-b6-jump-unregistered-handler-signals
  "bookmark-jump where the handler symbol has no registered fn must
   raise (loudly) — likely cause is a stale persisted file from a
   feature that's been removed; surfacing it tells the user to delete
   the orphan."
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "orphan" :handler 'no-such-mode
                                :record '(:x 1)))
  (assert-error error
                (limn/bookmark:bookmark-jump "orphan")))

;;; ── B6b. record-fn registry ─────────────────────────────────────────

(deftest bookmark-b6b-register-record-fn-and-make
  "register-record-fn stores a thunk; make-current-record runs it."
  (limn/bookmark:register-record-fn
   'fake-mode (lambda () '(:file "/tmp/x" :position 42)))
  (let ((r (limn/bookmark:make-current-record 'fake-mode)))
    (assert-equal "/tmp/x" (getf r :file)
                  "record-fn return value passed back")
    (assert-equal 42 (getf r :position)))
  (limn/bookmark:unregister-record-fn 'fake-mode))

(deftest bookmark-b6b-make-record-unregistered-returns-nil
  "make-current-record on a mode without a record-fn returns NIL —
   command layer reads this as 'this mode can't be bookmarked' and
   shows a user-visible message instead of erroring."
  (limn/bookmark:unregister-record-fn 'no-such-mode)
  (assert-false (limn/bookmark:make-current-record 'no-such-mode)))

;;; ── B7. persistence (sidecar) ───────────────────────────────────────

(deftest bookmark-b7-sidecar-path-shape
  (let ((p (limn/bookmark:bookmarks-sidecar-path)))
    (assert-true (search ".limn/" (namestring p))
                 "sidecar lives under ~/.limn/")
    (assert-true (search "bookmarks" (namestring p))
                 "filename mentions bookmarks")))

(deftest bookmark-b7-save-load-roundtrip
  (let ((tmp (merge-pathnames "limn-bm-test.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR")
                                            "/tmp/")))))
    (when (probe-file tmp) (delete-file tmp))
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark :name "intro" :handler 'text-mode
                                  :record '(:file "/x.txt"
                                            :position 0 :line 1)))
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark :name "ch2" :handler 'pdf-mode
                                  :record '(:path "/y.pdf"
                                            :doc-hash "abc"
                                            :page 5 :y-offset 0.3
                                            :x-offset 0.0)))
    (limn/bookmark:bookmarks-save tmp)
    ;; nuke in-memory, reload from disk
    (limn/bookmark:bookmark-clear)
    (assert-equal 0 (limn/bookmark:bookmark-count) "cleared pre-load")
    (limn/bookmark:bookmarks-load tmp)
    (assert-equal 2 (limn/bookmark:bookmark-count) "both restored")
    (let ((p (limn/bookmark:bookmark-find "ch2")))
      (assert-true p "ch2 came back")
      (assert-equal 5 (getf (limn/bookmark:bookmark-record p) :page)
                    "page survived roundtrip")
      (assert-equal 'pdf-mode (limn/bookmark:bookmark-handler p)
                    "handler symbol survived"))
    (when (probe-file tmp) (delete-file tmp))))

(deftest bookmark-b7-load-missing-file-noops
  "Loading a path that doesn't exist is a silent no-op (matches
   limn/history:load-history semantics — first run = empty store)."
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "in-mem" :handler 'text-mode
                                :record '(:file "/x" :position 0)))
  (limn/bookmark:bookmarks-load "/tmp/limn-bm-does-not-exist.lisp")
  (assert-equal 1 (limn/bookmark:bookmark-count)
                "in-memory store untouched"))

(deftest bookmark-b7-save-empty-is-roundtripable
  (let ((tmp (merge-pathnames "limn-bm-empty.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR")
                                            "/tmp/")))))
    (when (probe-file tmp) (delete-file tmp))
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmarks-save tmp)
    (limn/bookmark:bookmarks-load tmp)
    (assert-equal 0 (limn/bookmark:bookmark-count))
    (when (probe-file tmp) (delete-file tmp))))

;;; ── B8. CJK / Unicode in names + records ────────────────────────────

(deftest bookmark-b8-cjk-name-and-record
  "Bookmark name and record fields round-trip CJK + emoji."
  (let ((tmp (merge-pathnames "limn-bm-cjk.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR")
                                            "/tmp/")))))
    (when (probe-file tmp) (delete-file tmp))
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark :name "第一章 🌟"
                                  :handler 'text-mode
                                  :record '(:file "/路径/笔记.org"
                                            :position 12)))
    (limn/bookmark:bookmarks-save tmp)
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmarks-load tmp)
    (let ((b (limn/bookmark:bookmark-find "第一章 🌟")))
      (assert-true b "CJK + emoji name resolves")
      (assert-equal "/路径/笔记.org"
                    (getf (limn/bookmark:bookmark-record b) :file)
                    "CJK record field intact"))
    (when (probe-file tmp) (delete-file tmp))))
