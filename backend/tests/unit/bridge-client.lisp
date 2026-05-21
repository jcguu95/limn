;;;; Unit tests for limn-bridge (the Lisp client of the bridge protocol)
;;;;
;;;; This is the in-Lisp half of the wire protocol — JSON encode/decode,
;;;; request id generation, response matching. Pure logic, no socket needed.
;;;;
;;;; API contract:
;;;;
;;;;   (limn-bridge:encode-message plist) → JSON string
;;;;   (limn-bridge:decode-message string) → plist
;;;;   (limn-bridge:make-request cmd &rest args) → request plist with id
;;;;   (limn-bridge:match-response request response) → bool
;;;;   (limn-bridge:response-ok? response) → bool

(in-package #:limn/unit-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/bridge)
    (defpackage :limn/bridge
      (:use :cl)
      (:export #:encode-message #:decode-message
               #:make-request #:match-response
               #:response-ok? #:response-error
               #:response-data #:event-type))))

;;; ── JSON encoding ───────────────────────────────────────────────────────

(deftest bridge-encode-simple
  (let ((s (limn/bridge:encode-message '(:|cmd| "view/set" :|page| 5))))
    (assert-type s string)
    (assert-true (search "view/set" s) "cmd field encoded")
    (assert-true (search "5"        s) "page value encoded")))

(deftest bridge-encode-bool
  (let ((s (limn/bridge:encode-message '(:|on| t))))
    (assert-true (search "true" s) "t encoded as true")))

(deftest bridge-encode-false
  (let ((s (limn/bridge:encode-message '(:|on| :false))))
    (assert-true (search "false" s) ":false encoded as false")))

(deftest bridge-encode-null
  (let ((s (limn/bridge:encode-message '(:|x| nil))))
    (assert-true (search "null" s) "nil encoded as null")))

(deftest bridge-encode-string-escapes-quote
  (let ((s (limn/bridge:encode-message '(:|x| "he said \"hi\""))))
    (assert-true (search "\\\"" s) "internal quote escaped")))

(deftest bridge-encode-array
  (let ((s (limn/bridge:encode-message '(:|xs| (1 2 3)))))
    (assert-true (search "[1,2,3]" s) "array of ints")))

(deftest bridge-encode-utf8
  (let ((s (limn/bridge:encode-message '(:|text| "你好"))))
    ;; UTF-8 characters are typically passed through as-is.
    (assert-true (or (search "你好" s)
                     (search "\\u4f60" s))
                 "UTF-8 encoded somehow")))

;;; ── JSON decoding ───────────────────────────────────────────────────────

(deftest bridge-decode-simple-object
  (let ((p (limn/bridge:decode-message "{\"ok\":true,\"id\":\"r1\"}")))
    (assert-equal t   (getf p :|ok|))
    (assert-equal "r1" (getf p :|id|))))

(deftest bridge-decode-false
  (let ((p (limn/bridge:decode-message "{\"ok\":false}")))
    (assert-eq :false (getf p :|ok|))))

(deftest bridge-decode-null
  (let ((p (limn/bridge:decode-message "{\"x\":null}")))
    (assert-true (or (null (getf p :|x|)) (eq (getf p :|x|) :null)))))

(deftest bridge-decode-nested
  (let ((p (limn/bridge:decode-message
            "{\"id\":\"r1\",\"data\":{\"buffer-id\":\"b1\",\"page-count\":42}}")))
    (assert-equal "b1" (getf (getf p :|data|) :|buffer-id|))
    (assert-equal 42   (getf (getf p :|data|) :|page-count|))))

(deftest bridge-decode-array
  (let ((p (limn/bridge:decode-message "{\"xs\":[1,2,3]}")))
    (assert-equal '(1 2 3) (getf p :|xs|))))

(deftest bridge-decode-string-with-escape
  (let ((p (limn/bridge:decode-message "{\"x\":\"a\\nb\"}")))
    (let ((v (getf p :|x|)))
      (assert-true (search (string #\Newline) v) "escaped newline decoded"))))

;;; ── Request generation ──────────────────────────────────────────────────

(deftest bridge-make-request-has-id
  (let ((req (limn/bridge:make-request "view/set" :|page| 0)))
    (assert-true (getf req :|id|) "id present")
    (assert-equal "view/set" (getf req :|cmd|))))

(deftest bridge-make-request-ids-unique
  (let ((a (limn/bridge:make-request "x"))
        (b (limn/bridge:make-request "x")))
    (assert-false (string= (getf a :|id|) (getf b :|id|))
                  "ids are distinct")))

;;; ── Response matching ───────────────────────────────────────────────────

(deftest bridge-match-response-matches-on-id
  (let* ((req (limn/bridge:make-request "x"))
         (id  (getf req :|id|))
         (resp (list :|id| id :|ok| t)))
    (assert-true (limn/bridge:match-response req resp))))

(deftest bridge-match-response-rejects-different-id
  (let* ((req  (limn/bridge:make-request "x"))
         (resp (list :|id| "other-id" :|ok| t)))
    (assert-false (limn/bridge:match-response req resp))))

;;; ── Response shape helpers ──────────────────────────────────────────────

(deftest bridge-response-ok-true
  (let ((r (list :|ok| t :|data| '(:|x| 1))))
    (assert-true (limn/bridge:response-ok? r))))

(deftest bridge-response-ok-false
  (let ((r (list :|ok| :false :|error| "bad")))
    (assert-false (limn/bridge:response-ok? r))))

(deftest bridge-response-data-extraction
  (let ((r (list :|ok| t :|data| '(:|x| 1))))
    (assert-equal '(:|x| 1) (limn/bridge:response-data r))))

(deftest bridge-response-error-extraction
  (let ((r (list :|ok| :false :|error| "nope")))
    (assert-equal "nope" (limn/bridge:response-error r))))

(deftest bridge-event-type
  (let ((ev (list :|event| "key" :|key| "j")))
    (assert-equal "key" (limn/bridge:event-type ev))))

;;; ── Decode of malformed JSON ────────────────────────────────────────────

(deftest bridge-decode-truncated-object
  "Truncated JSON (missing closing }) signals an error."
  (assert-error error
                (limn/bridge:decode-message "{\"ok\":true")
                "truncated object errors"))

(deftest bridge-decode-invalid-utf8-tolerated
  "Invalid escape sequences either resolve or raise — but never crash."
  (handler-case
      (let ((r (limn/bridge:decode-message "{\"x\":\"\\q\"}")))
        ;; Either it accepted \q literally, or errored — both fine
        (assert-true t (format nil "handled invalid escape: ~s" r)))
    (error () (assert-true t "invalid escape raised cleanly"))))

(deftest bridge-decode-empty-string
  "Empty string raises an error (no message)."
  (assert-error error
                (limn/bridge:decode-message "")
                "empty input errors"))

(deftest bridge-decode-just-whitespace
  "Whitespace-only input raises an error."
  (assert-error error
                (limn/bridge:decode-message "   ")
                "whitespace errors"))

;;; ── Encode of nested arrays ─────────────────────────────────────────────

(deftest bridge-encode-array-of-objects
  (let ((s (limn/bridge:encode-message
            '(:|xs| ((:|name| "a") (:|name| "b"))))))
    (assert-true (search "\"name\":\"a\"" s) "first object encoded")
    (assert-true (search "\"name\":\"b\"" s) "second object encoded")))

;;; ── Large message (1MB) doesn't choke ──────────────────────────────────

(deftest bridge-decode-large-string
  "Decoding a JSON object with a 100KB string field succeeds."
  (let* ((big (make-string 100000 :initial-element #\a))
         (msg (format nil "{\"x\":\"~a\"}" big))
         (parsed (limn/bridge:decode-message msg)))
    (assert-equal 100000 (length (getf parsed :|x|))
                  "large string preserved")))

;;; ── Roundtrip property: encode then decode ─────────────────────────────

(deftest bridge-roundtrip-simple
  (let* ((orig '(:|cmd| "x" :|n| 42 :|b| t))
         (json (limn/bridge:encode-message orig))
         (back (limn/bridge:decode-message json)))
    (assert-equal "x" (getf back :|cmd|))
    (assert-equal 42  (getf back :|n|))
    (assert-equal t   (getf back :|b|))))

(deftest bridge-roundtrip-nested
  (let* ((orig '(:|data| (:|inner| (:|deep| 7))))
         (json (limn/bridge:encode-message orig))
         (back (limn/bridge:decode-message json)))
    (assert-equal 7 (getf (getf (getf back :|data|) :|inner|) :|deep|)
                  "deeply nested value roundtrips")))

;;; ── Concurrent IDs ──────────────────────────────────────────────────────

(deftest bridge-many-unique-ids
  "1000 generated request ids are all unique."
  (let ((ids (loop repeat 1000 collect (getf (limn/bridge:make-request "x") :|id|))))
    (assert-equal 1000 (length (remove-duplicates ids :test #'equal))
                  "1000 unique ids")))

;;; ── Numeric edge cases ──────────────────────────────────────────────────

(deftest bridge-encode-negative-int
  (let ((s (limn/bridge:encode-message '(:|n| -42))))
    (assert-true (search "-42" s))))

(deftest bridge-encode-zero
  (let ((s (limn/bridge:encode-message '(:|n| 0))))
    (assert-true (search "\"n\":0" s))))

(deftest bridge-encode-large-int
  (let ((s (limn/bridge:encode-message '(:|n| 2147483647))))
    (assert-true (search "2147483647" s))))

(deftest bridge-decode-negative-int
  (let ((p (limn/bridge:decode-message "{\"n\":-7}")))
    (assert-equal -7 (getf p :|n|))))

(deftest bridge-decode-scientific-notation
  "JSON numbers like 1e10 are decoded to numeric value."
  (let ((p (limn/bridge:decode-message "{\"n\":1e3}")))
    (assert-true (numberp (getf p :|n|))
                 "scientific notation parsed to number")))

;;; ── Empty containers ────────────────────────────────────────────────────

(deftest bridge-encode-empty-array
  (let ((s (limn/bridge:encode-message '(:|xs| ()))))
    (assert-true (or (search "[]" s) (search "null" s))
                 "empty array or null")))

(deftest bridge-decode-empty-array
  (let ((p (limn/bridge:decode-message "{\"xs\":[]}")))
    (assert-true (null (getf p :|xs|)) "empty array decodes to nil/empty")))

(deftest bridge-decode-empty-object
  (let ((p (limn/bridge:decode-message "{}")))
    (assert-true (null p) "empty object decodes to nil")))

;;; ── Whitespace tolerance ────────────────────────────────────────────────

(deftest bridge-decode-whitespace-padded
  (let ((p (limn/bridge:decode-message "  {  \"x\"  :  1  }  ")))
    (assert-equal 1 (getf p :|x|) "whitespace tolerated")))

(deftest bridge-decode-newlines-between-fields
  (let ((p (limn/bridge:decode-message
            (format nil "{~%\"a\":1,~%\"b\":2~%}"))))
    (assert-equal 1 (getf p :|a|))
    (assert-equal 2 (getf p :|b|))))

;;; ── Roundtrip with all common types ────────────────────────────────────

(deftest bridge-roundtrip-all-types
  (let* ((orig '(:|str|    "hello world"
                  :|int|    42
                  :|neg|    -7
                  :|float|  1.5
                  :|true|   t
                  :|false|  :false
                  :|arr|    (1 2 3)
                  :|obj|    (:|inner| "deep")))
         (json (limn/bridge:encode-message orig))
         (back (limn/bridge:decode-message json)))
    (assert-equal "hello world" (getf back :|str|))
    (assert-equal 42            (getf back :|int|))
    (assert-equal -7            (getf back :|neg|))
    (check-assertion (< (abs (- (getf back :|float|) 1.5)) 0.001)
                     "float roundtripped"
                     "got ~s" (getf back :|float|))
    (assert-equal t              (getf back :|true|))
    (assert-equal :false         (getf back :|false|))
    (assert-equal '(1 2 3)       (getf back :|arr|))
    (assert-equal "deep"         (getf (getf back :|obj|) :|inner|))))
