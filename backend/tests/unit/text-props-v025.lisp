;;;; v0.25 §B — text-properties RED tests  (~28 tests)
;;;;
;;;; Tests cover: put/get, add/remove, boundary traversal, stickiness
;;;; on insert/delete, interval merging, propertize, and face integration.
;;;; All RED until limn/text-props is implemented.
;;;;
;;;; Key invariant under test: all mutations go through limn/text-props:insert
;;;; and limn/text-props:delete (not the bridge directly). Tests exercise the
;;;; interval tree through that wrapper.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/text-props)
    (make-package '#:limn/text-props :use '(#:cl)))
  (dolist (sym '("MAKE-PROP-BUFFER"
                 "INSERT" "DELETE-REGION"
                 "PUT-TEXT-PROPERTY"
                 "GET-TEXT-PROPERTY"
                 "ADD-TEXT-PROPERTIES"
                 "REMOVE-TEXT-PROPERTIES"
                 "NEXT-PROPERTY-CHANGE"
                 "PREVIOUS-PROPERTY-CHANGE"
                 "TEXT-PROPERTY-ANY"
                 "PROPERTIZE"
                 "BUFFER-TEXT" "BUFFER-LENGTH"))
    (let ((s (intern sym '#:limn/text-props)))
      (export s '#:limn/text-props))))

(in-package #:limn/unit-test)

;;; Each test gets a fresh in-memory prop-buffer so intervals don't bleed.
;;; make-prop-buffer takes an initial string (no bridge needed — unit tier).

(defmacro with-prop-buf ((var initial) &body body)
  `(let ((,var (limn/text-props:make-prop-buffer ,initial)))
     ,@body))

;;; ─── B1. put / get ────────────────────────────────────────────────

(deftest text-props-b1-put-get-roundtrip
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (assert-eq 'bold (limn/text-props:get-text-property 6 :face buf))
    (assert-eq 'bold (limn/text-props:get-text-property 8 :face buf))
    (assert-eq 'bold (limn/text-props:get-text-property 10 :face buf))))

(deftest text-props-b1-get-outside-range-is-nil
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (assert-false (limn/text-props:get-text-property 5 :face buf)
                  "position before interval → nil")
    (assert-false (limn/text-props:get-text-property 11 :face buf)
                  "position at end (exclusive) → nil")))

(deftest text-props-b1-multiple-props-same-range
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:put-text-property 0 5 :help-echo "hi" buf)
    (assert-eq 'bold (limn/text-props:get-text-property 0 :face buf))
    (assert-equal "hi" (limn/text-props:get-text-property 0 :help-echo buf))))

(deftest text-props-b1-overlapping-ranges-latest-wins
  (with-prop-buf (buf "AAABBBCCC")
    (limn/text-props:put-text-property 0 9 :face 'base buf)
    (limn/text-props:put-text-property 3 6 :face 'override buf)
    (assert-eq 'base     (limn/text-props:get-text-property 0 :face buf))
    (assert-eq 'override (limn/text-props:get-text-property 3 :face buf))
    (assert-eq 'base     (limn/text-props:get-text-property 6 :face buf))))

;;; ─── B2. add / remove ─────────────────────────────────────────────

(deftest text-props-b2-add-text-properties
  (with-prop-buf (buf "Hello")
    (limn/text-props:add-text-properties 0 5 '(:face bold :weight heavy) buf)
    (assert-eq 'bold  (limn/text-props:get-text-property 0 :face buf))
    (assert-eq 'heavy (limn/text-props:get-text-property 0 :weight buf))))

(deftest text-props-b2-remove-text-properties-specific-prop
  (with-prop-buf (buf "Hello")
    (limn/text-props:add-text-properties 0 5 '(:face bold :weight heavy) buf)
    (limn/text-props:remove-text-properties 0 5 '(:face nil) buf)
    (assert-false (limn/text-props:get-text-property 0 :face buf)
                  "removed prop should be nil")
    (assert-eq 'heavy (limn/text-props:get-text-property 0 :weight buf)
               "other prop should survive")))

;;; ─── B3. boundary traversal ───────────────────────────────────────

(deftest text-props-b3-next-property-change
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (let ((next (limn/text-props:next-property-change 0 buf nil)))
      (assert-equal 6 next "next change should be at 6 where bold starts"))))

(deftest text-props-b3-next-property-change-limit
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (let ((next (limn/text-props:next-property-change 0 buf 4)))
      (assert-false next "limit 4 should prevent finding change at 6"))))

(deftest text-props-b3-previous-property-change
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (let ((prev (limn/text-props:previous-property-change 11 buf nil)))
      (assert-equal 6 prev "prev change going left from 11 is at 6"))))

(deftest text-props-b3-text-property-any-found
  (with-prop-buf (buf "abcde")
    (limn/text-props:put-text-property 3 5 :face 'match buf)
    (assert-equal 3 (limn/text-props:text-property-any 0 5 :face 'match buf))))

(deftest text-props-b3-text-property-any-not-found
  (with-prop-buf (buf "abcde")
    (assert-false (limn/text-props:text-property-any 0 5 :face 'missing buf))))

;;; ─── B4. propertize ───────────────────────────────────────────────

(deftest text-props-b4-propertize-returns-string
  (let ((s (limn/text-props:propertize "hello" :face 'bold)))
    (assert-true (stringp s) "propertize returns a string")))

(deftest text-props-b4-propertize-carries-props
  (let ((s (limn/text-props:propertize "hello" :face 'bold :weight 'heavy)))
    (assert-eq 'bold  (limn/text-props:get-text-property 0 :face s))
    (assert-eq 'heavy (limn/text-props:get-text-property 0 :weight s))))

(deftest text-props-b4-propertize-no-side-effect-on-original
  (let* ((orig "hello")
         (_s (limn/text-props:propertize orig :face 'bold)))
    (declare (ignore _s))
    (assert-false (limn/text-props:get-text-property 0 :face orig)
                  "original string must be unmodified")))

;;; ─── B5. insert stickiness ────────────────────────────────────────

(deftest text-props-b5-insert-middle-inherits
  ;; Insert inside [0,5) bold → new text at pos 2 becomes bold
  (with-prop-buf (buf "Hello")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:insert buf 2 "XX")
    ;; buf is now "HeXXllo" — position 2,3 should be bold
    (assert-eq 'bold (limn/text-props:get-text-property 2 :face buf))
    (assert-eq 'bold (limn/text-props:get-text-property 3 :face buf))))

(deftest text-props-b5-insert-at-rear-sticky-inherits
  ;; By default: insert at right boundary inherits (rear-sticky)
  (with-prop-buf (buf "Hello")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:insert buf 5 " World")
    ;; " World" at 5-10 should be bold (rear-sticky default)
    (assert-eq 'bold (limn/text-props:get-text-property 5 :face buf))))

(deftest text-props-b5-insert-at-front-nonsticky-no-inherit
  ;; By default: insert at left boundary does NOT inherit (front-nonsticky)
  (with-prop-buf (buf "Hello")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:insert buf 0 ">>")
    ;; ">>" prepended — should NOT be bold
    (assert-false (limn/text-props:get-text-property 0 :face buf)
                  "front-nonsticky: prepended text should not inherit bold")))

(deftest text-props-b5-front-sticky-propagates
  ;; Explicitly set front-sticky on the face prop → insert at front inherits
  (with-prop-buf (buf "Hello")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:put-text-property 0 5 :front-sticky '(:face) buf)
    (limn/text-props:insert buf 0 ">>")
    (assert-eq 'bold (limn/text-props:get-text-property 0 :face buf)
               "front-sticky: prepended text should inherit bold")))

(deftest text-props-b5-rear-nonsticky-does-not-extend
  ;; rear-nonsticky → insert at right boundary does NOT inherit
  (with-prop-buf (buf "Hello")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:put-text-property 0 5 :rear-nonsticky '(:face) buf)
    (limn/text-props:insert buf 5 " World")
    (assert-false (limn/text-props:get-text-property 5 :face buf)
                  "rear-nonsticky: appended text should not inherit bold")))

;;; ─── B6. delete semantics ─────────────────────────────────────────

(deftest text-props-b6-delete-whole-interval-removes-props
  (with-prop-buf (buf "Hello World")
    (limn/text-props:put-text-property 6 11 :face 'bold buf)
    (limn/text-props:delete-region buf 6 5)       ; remove "World"
    (assert-false (limn/text-props:get-text-property 6 :face buf)
                  "interval should be gone after deleting its text")))

(deftest text-props-b6-delete-partial-left-trims
  (with-prop-buf (buf "0123456789")
    (limn/text-props:put-text-property 3 8 :face 'bold buf)
    (limn/text-props:delete-region buf 1 4)       ; remove pos 1-4 inclusive
    ;; original [3,8) → after delete trim to [1, 4) in new indexing
    (assert-false (limn/text-props:get-text-property 0 :face buf))
    (assert-eq 'bold (limn/text-props:get-text-property 1 :face buf))))

(deftest text-props-b6-delete-shifts-subsequent-intervals
  (with-prop-buf (buf "AAABBBCCC")
    (limn/text-props:put-text-property 6 9 :face 'bold buf)  ; "CCC"
    (limn/text-props:delete-region buf 0 3)                   ; remove "AAA"
    ;; "CCC" was at [6,9), now at [3,6)
    (assert-false (limn/text-props:get-text-property 2 :face buf))
    (assert-eq 'bold (limn/text-props:get-text-property 3 :face buf))))

;;; ─── B7. interval merging ─────────────────────────────────────────

(deftest text-props-b7-adjacent-identical-merged
  ;; After two adjacent puts with identical plists they should be one interval
  (with-prop-buf (buf "HelloWorld")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:put-text-property 5 10 :face 'bold buf)
    ;; next-property-change from 0 should reach 10 (no boundary in middle)
    (let ((next (limn/text-props:next-property-change 0 buf nil)))
      (assert-equal 10 next
                    "merged interval: no boundary at 5"))))

(deftest text-props-b7-adjacent-different-not-merged
  (with-prop-buf (buf "HelloWorld")
    (limn/text-props:put-text-property 0 5 :face 'bold buf)
    (limn/text-props:put-text-property 5 10 :face 'italic buf)
    (let ((next (limn/text-props:next-property-change 0 buf nil)))
      (assert-equal 5 next
                    "different intervals: boundary at 5 must remain"))))
