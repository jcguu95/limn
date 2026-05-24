;;;; v0.25 §D — history rings RED tests  (~13 tests)
;;;;
;;;; Tests cover: ring creation, add/overflow, no-dup, built-in rings,
;;;; and sidecar persist/load round-trip.
;;;; All RED until limn/history is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/history)
    (make-package '#:limn/history :use '(#:cl)))
  (dolist (sym '("DEFINE-HISTORY" "ADD-TO-HISTORY" "HISTORY-ITEMS"
                 "HISTORY-MAX-SIZE"
                 "*MINIBUFFER-HISTORY*" "*COMMAND-HISTORY*" "*SEARCH-HISTORY*"
                 "HISTORY-SIDECAR-PATH"
                 "SAVE-HISTORY" "LOAD-HISTORY"))
    (let ((s (intern sym '#:limn/history)))
      (export s '#:limn/history))))

(in-package #:limn/unit-test)

;;; ─── D1. define-history / add-to-history ─────────────────────────

(deftest history-d1-define-creates-ring
  (limn/history:define-history 'test-h-d1 :size 10)
  (assert-equal 10 (limn/history:history-max-size 'test-h-d1)
                "define-history should create ring with given size"))

(deftest history-d1-add-to-history-appends
  (limn/history:define-history 'test-h-add :size 10)
  (limn/history:add-to-history 'test-h-add "item-a")
  (limn/history:add-to-history 'test-h-add "item-b")
  (let ((items (limn/history:history-items 'test-h-add)))
    (assert-contains "item-a" items)
    (assert-contains "item-b" items)))

(deftest history-d1-most-recent-first
  (limn/history:define-history 'test-h-order :size 10)
  (limn/history:add-to-history 'test-h-order "first")
  (limn/history:add-to-history 'test-h-order "second")
  (assert-equal "second" (first (limn/history:history-items 'test-h-order))
                "most recently added item should be at front"))

;;; ─── D2. ring overflow ────────────────────────────────────────────

(deftest history-d2-ring-rolls-over-at-size
  (limn/history:define-history 'test-h-ring :size 3)
  (limn/history:add-to-history 'test-h-ring "a")
  (limn/history:add-to-history 'test-h-ring "b")
  (limn/history:add-to-history 'test-h-ring "c")
  (limn/history:add-to-history 'test-h-ring "d") ; should push out "a"
  (let ((items (limn/history:history-items 'test-h-ring)))
    (assert-equal 3 (length items) "ring size should not exceed max")
    (assert-false (find "a" items :test #'equal)
                  "oldest item should be evicted")))

;;; ─── D3. no consecutive duplicates ───────────────────────────────

(deftest history-d3-consecutive-dup-not-added
  (limn/history:define-history 'test-h-dup :size 10)
  (limn/history:add-to-history 'test-h-dup "same")
  (limn/history:add-to-history 'test-h-dup "same")
  (assert-equal 1 (length (limn/history:history-items 'test-h-dup))
                "consecutive duplicate should not be stored twice"))

(deftest history-d3-non-consecutive-dup-allowed
  (limn/history:define-history 'test-h-nondup :size 10)
  (limn/history:add-to-history 'test-h-nondup "a")
  (limn/history:add-to-history 'test-h-nondup "b")
  (limn/history:add-to-history 'test-h-nondup "a") ; allowed: not consecutive
  (assert-equal 3 (length (limn/history:history-items 'test-h-nondup))))

;;; ─── D4. built-in rings ───────────────────────────────────────────

(deftest history-d4-minibuffer-history-exists
  (assert-true limn/history:*minibuffer-history*
               "*minibuffer-history* should be pre-defined"))

(deftest history-d4-command-history-exists
  (assert-true limn/history:*command-history*
               "*command-history* should be pre-defined"))

(deftest history-d4-search-history-exists
  (assert-true limn/history:*search-history*
               "*search-history* should be pre-defined"))

;;; ─── D5. sidecar persist / load ───────────────────────────────────

(deftest history-d5-sidecar-path-matches-spec
  (limn/history:define-history 'my-cmd-hist :size 50)
  (let ((path (limn/history:history-sidecar-path 'my-cmd-hist)))
    (assert-true (search "my-cmd-hist" path)
                 "sidecar path should include history name")
    (assert-true (search ".limn/history/" path)
                 "sidecar path should be under ~/.limn/history/")))

(deftest history-d5-save-load-roundtrip
  (let ((tmp (merge-pathnames "limn-hist-test.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR") "/tmp/")))))
    (limn/history:define-history 'test-h-persist :size 10)
    (limn/history:add-to-history 'test-h-persist "alpha")
    (limn/history:add-to-history 'test-h-persist "beta")
    (limn/history:save-history 'test-h-persist tmp)
    ;; clear in-memory, reload from file
    (limn/history:define-history 'test-h-persist :size 10)
    (limn/history:load-history 'test-h-persist tmp)
    (let ((items (limn/history:history-items 'test-h-persist)))
      (assert-contains "alpha" items "alpha should survive roundtrip")
      (assert-contains "beta"  items "beta should survive roundtrip"))
    (when (probe-file tmp) (delete-file tmp))))
