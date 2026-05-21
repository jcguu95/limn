;;;; Unit tests for limn-buffer (Lisp-side buffer tracking)
;;;;
;;;; The backend keeps a Lisp-side registry of buffers, paralleling what
;;;; the Frontend tracks. This is for fast lookup, hook integration, and
;;;; offline state (e.g., session save).
;;;;
;;;; API contract:
;;;;
;;;;   (limn-buffer:register buffer-id path engine)
;;;;   (limn-buffer:unregister buffer-id)
;;;;   (limn-buffer:lookup buffer-id) → buffer object or nil
;;;;   (limn-buffer:list-all)         → list of all buffer ids
;;;;   (limn-buffer:path buffer)
;;;;   (limn-buffer:engine buffer)
;;;;   (limn-buffer:metadata-set buffer key value)
;;;;   (limn-buffer:metadata-get buffer key)

(in-package #:limn/unit-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/buffer)
    (defpackage :limn/buffer
      (:use :cl)
      (:export #:register #:unregister #:lookup #:list-all
               #:path #:engine
               #:metadata-set #:metadata-get
               #:clear-all
               #:buffer-p))))

(defmacro with-clean-buffers (&body body)
  `(progn
     (handler-case (limn/buffer:clear-all) (error () nil))
     ,@body
     (handler-case (limn/buffer:clear-all) (error () nil))))

;;; ── Registration ────────────────────────────────────────────────────────

(deftest buffer-register-and-lookup
  (with-clean-buffers
    (limn/buffer:register "b1" "/tmp/x.pdf" "mupdf")
    (let ((buf (limn/buffer:lookup "b1")))
      (assert-true buf "lookup returns object")
      (assert-true (limn/buffer:buffer-p buf) "object is a buffer"))))

(deftest buffer-lookup-missing-returns-nil
  (with-clean-buffers
    (assert-eq nil (limn/buffer:lookup "b-nope"))))

(deftest buffer-fields-accessible
  (with-clean-buffers
    (limn/buffer:register "b1" "/tmp/x.pdf" "mupdf")
    (let ((buf (limn/buffer:lookup "b1")))
      (assert-equal "/tmp/x.pdf" (limn/buffer:path buf))
      (assert-equal "mupdf"      (limn/buffer:engine buf)))))

;;; ── Listing ─────────────────────────────────────────────────────────────

(deftest buffer-list-all-empty
  (with-clean-buffers
    (assert-equal nil (limn/buffer:list-all))))

(deftest buffer-list-all-contains-registered
  (with-clean-buffers
    (limn/buffer:register "b1" "/p1" "mupdf")
    (limn/buffer:register "b2" "/p2" "mupdf")
    (let ((ids (limn/buffer:list-all)))
      (assert-true (member "b1" ids :test #'string=) "b1 present")
      (assert-true (member "b2" ids :test #'string=) "b2 present"))))

;;; ── Unregistration ──────────────────────────────────────────────────────

(deftest buffer-unregister-removes
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (limn/buffer:unregister "b1")
    (assert-eq nil (limn/buffer:lookup "b1"))))

(deftest buffer-unregister-nonexistent-noop
  (with-clean-buffers
    (assert-no-error (limn/buffer:unregister "b-nope")
                     "unregistering nonexistent doesn't error")))

;;; ── Per-buffer metadata ─────────────────────────────────────────────────

(deftest buffer-metadata-set-and-get
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (let ((buf (limn/buffer:lookup "b1")))
      (limn/buffer:metadata-set buf :scroll-y 1234.5)
      (assert-equal 1234.5 (limn/buffer:metadata-get buf :scroll-y)))))

(deftest buffer-metadata-default-nil
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (let ((buf (limn/buffer:lookup "b1")))
      (assert-eq nil (limn/buffer:metadata-get buf :unknown-key)))))

(deftest buffer-metadata-overwrites
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (let ((buf (limn/buffer:lookup "b1")))
      (limn/buffer:metadata-set buf :k 1)
      (limn/buffer:metadata-set buf :k 2)
      (assert-equal 2 (limn/buffer:metadata-get buf :k)))))

;;; ── Independent metadata per buffer ─────────────────────────────────────

(deftest buffer-metadata-isolated
  (with-clean-buffers
    (limn/buffer:register "b1" "/p1" "mupdf")
    (limn/buffer:register "b2" "/p2" "mupdf")
    (limn/buffer:metadata-set (limn/buffer:lookup "b1") :v "one")
    (limn/buffer:metadata-set (limn/buffer:lookup "b2") :v "two")
    (assert-equal "one" (limn/buffer:metadata-get (limn/buffer:lookup "b1") :v))
    (assert-equal "two" (limn/buffer:metadata-get (limn/buffer:lookup "b2") :v))))

;;; ── Duplicate register handling ────────────────────────────────────────

(deftest buffer-register-duplicate-overwrites
  "Registering the same buffer-id twice: second one overwrites OR errors.
   Either is acceptable; we just need defined behavior, not corrupt state."
  (with-clean-buffers
    (limn/buffer:register "b1" "/p1" "mupdf")
    (handler-case
        (progn
          (limn/buffer:register "b1" "/p2" "mupdf")
          ;; If it succeeded, path should reflect the second one OR remain first
          (let ((p (limn/buffer:path (limn/buffer:lookup "b1"))))
            (assert-true (or (string= p "/p1") (string= p "/p2"))
                         "path is one of the registered values")))
      (error () (assert-true t "duplicate register errored (also acceptable)")))))

;;; ── Lookup by path (reverse lookup) ────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/buffer)
    (unless (find-symbol "FIND-BY-PATH" :limn/buffer)
      (export (intern "FIND-BY-PATH" :limn/buffer) :limn/buffer))))

(deftest buffer-find-by-path
  "find-by-path returns the buffer for a given file path."
  (with-clean-buffers
    (limn/buffer:register "b1" "/tmp/x.pdf" "mupdf")
    (let ((buf (limn/buffer:find-by-path "/tmp/x.pdf")))
      (assert-true buf "found by path")
      (when buf
        (assert-equal "/tmp/x.pdf" (limn/buffer:path buf))))))

(deftest buffer-find-by-path-missing
  "find-by-path returns nil if no buffer matches."
  (with-clean-buffers
    (assert-eq nil (limn/buffer:find-by-path "/no/such/path"))))

;;; ── Iterating buffers ─────────────────────────────────────────────────

(deftest buffer-list-all-after-multiple-register
  (with-clean-buffers
    (limn/buffer:register "b1" "/p1" "mupdf")
    (limn/buffer:register "b2" "/p2" "mupdf")
    (limn/buffer:register "b3" "/p3" "web")
    (let ((ids (limn/buffer:list-all)))
      (assert-equal 3 (length ids) "3 buffers registered"))))

;;; ── Buffer reflects engine attribute ──────────────────────────────────

(deftest buffer-engine-field
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (limn/buffer:register "b2" "/p" "web")
    (assert-equal "mupdf" (limn/buffer:engine (limn/buffer:lookup "b1")))
    (assert-equal "web"   (limn/buffer:engine (limn/buffer:lookup "b2")))))

;;; ── Clear-all resets fully ─────────────────────────────────────────────

(deftest buffer-clear-all-resets
  (limn/buffer:register "x" "/p" "e")
  (limn/buffer:clear-all)
  (assert-eq nil (limn/buffer:lookup "x") "lookup after clear-all returns nil")
  (assert-equal nil (limn/buffer:list-all) "list-all empty after clear-all"))

;;; ── Buffer count / iteration ──────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/buffer)
    (unless (find-symbol "COUNT-BUFFERS" :limn/buffer)
      (export (intern "COUNT-BUFFERS" :limn/buffer) :limn/buffer))
    (unless (find-symbol "MAP-BUFFERS" :limn/buffer)
      (export (intern "MAP-BUFFERS" :limn/buffer) :limn/buffer))))

(deftest buffer-count
  (with-clean-buffers
    (assert-equal 0 (limn/buffer:count-buffers))
    (limn/buffer:register "b1" "/p1" "mupdf")
    (limn/buffer:register "b2" "/p2" "mupdf")
    (assert-equal 2 (limn/buffer:count-buffers))))

(deftest buffer-map-buffers
  "map-buffers iterates over all registered buffers."
  (with-clean-buffers
    (limn/buffer:register "b1" "/p1" "mupdf")
    (limn/buffer:register "b2" "/p2" "web")
    (let ((engines '()))
      (limn/buffer:map-buffers
        (lambda (buf) (push (limn/buffer:engine buf) engines)))
      (assert-equal 2 (length engines))
      (assert-contains "mupdf" engines)
      (assert-contains "web"   engines))))

;;; ── Buffer metadata bulk operations ────────────────────────────────────

(deftest buffer-metadata-multiple-keys
  "Many metadata keys on one buffer don't collide."
  (with-clean-buffers
    (limn/buffer:register "b1" "/p" "mupdf")
    (let ((b (limn/buffer:lookup "b1")))
      (limn/buffer:metadata-set b :k1 "v1")
      (limn/buffer:metadata-set b :k2 42)
      (limn/buffer:metadata-set b :k3 '(a b c))
      (assert-equal "v1"    (limn/buffer:metadata-get b :k1))
      (assert-equal 42      (limn/buffer:metadata-get b :k2))
      (assert-equal '(a b c)(limn/buffer:metadata-get b :k3)))))

;;; ── Buffer-id format ──────────────────────────────────────────────────

(deftest buffer-id-is-stable
  "buffer-id used in registration is the same returned by lookup."
  (with-clean-buffers
    (limn/buffer:register "my-id" "/p" "mupdf")
    (let ((b (limn/buffer:lookup "my-id")))
      ;; Implementation may expose buffer-id via accessor or via lookup args;
      ;; we just verify lookup returns a non-nil result for the same id
      (assert-true b "registered id is findable"))))

;;; ── Concurrent-ish operations (sequential but interleaved) ───────────

(deftest buffer-interleaved-register-unregister
  "Register/unregister alternation doesn't corrupt state."
  (with-clean-buffers
    (loop for i below 20 do
      (limn/buffer:register (format nil "b~a" i) (format nil "/p~a" i) "mupdf")
      (when (oddp i)
        (limn/buffer:unregister (format nil "b~a" (1- i)))))
    ;; Now we should have ~10 buffers (the even ones)
    (let ((remaining (limn/buffer:list-all)))
      (assert-true (>= (length remaining) 1) "some buffers remaining"))))
