;;;; Smoke tests — minimal sanity checks
;;;;
;;;; If these fail, nothing else will work. Run this suite first to catch
;;;; gross protocol breakage.

(in-package #:limn/test)

(deftest smoke-can-connect
  "Test framework can establish a socket connection."
  (assert-true (connected?) "socket is connected"))

(deftest smoke-capabilities-responds
  "bridge/capabilities returns a response (any shape)."
  (let ((r (send! "bridge/capabilities")))
    (assert-true r "got a response")
    (assert-has-key :|id| r "response has id")
    (assert-has-key :|ok| r "response has ok")))

(deftest smoke-fixture-exists
  "The test PDF fixture file is present on disk."
  (assert-true (probe-file *fixture-pdf*)
               (format nil "fixture PDF exists at ~a" *fixture-pdf*)))

(deftest smoke-can-load-fixture
  "We can load the fixture PDF (if mupdf engine is available)."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r "fixture loads via mupdf engine")))

(deftest smoke-view-get-after-load
  "view/get works after loading."
  (let ((r (send! "view/get" :|win-id| "w1")))
    (assert-ok r "view/get returns data")))
