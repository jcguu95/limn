;;;; Unit tests for limn/dispatch.
;;;;
;;;; We don't need a real socket — limn/dispatch accepts a vtable of I/O
;;;; functions, so we drive it with an in-memory FIFO that the test owns.

(in-package #:limn/unit-test)

;;; ── mock client: a struct with two queues ──────────────────────────────

(defstruct mock
  (incoming '())   ; lines the "frontend" is about to send to us
  (outgoing '()))  ; lines we sent to the frontend (newest last)

(defun mock-push-line (m line)
  (setf (mock-incoming m) (append (mock-incoming m) (list line))))

(defun mock-write (m line)
  (setf (mock-outgoing m) (append (mock-outgoing m) (list line)))
  t)

(defun mock-try-read (m)
  (if (mock-incoming m)
      (pop (mock-incoming m))
      nil))

(defun mock-blocking (m)
  ;; In tests we always pre-stage messages, so blocking == try, with :eof
  ;; sentinel if nothing's there (prevents accidental infinite loops).
  (or (mock-try-read m) :eof))

(defun new-mock-session ()
  (let ((m (make-mock)))
    (values
     (limn/dispatch:make-session-for m
       :write-fn    #'mock-write
       :try-read-fn #'mock-try-read
       :blocking-fn #'mock-blocking)
     m)))

;;; ── tests ──────────────────────────────────────────────────────────────

(deftest dispatch-call-roundtrip
  ;; Stage a response keyed to the id we expect dispatch to mint (r1),
  ;; then call and verify the decoded plist comes back.
  (let ((limn/dispatch::*request-timeout* 1.0))
    (multiple-value-bind (sess m) (new-mock-session)
      (mock-push-line m "{\"id\":\"r1\",\"ok\":true,\"data\":{\"page\":3}}")
      (let ((resp (limn/dispatch:call sess "view/get" :|win-id| "w1")))
        (assert-true (limn/bridge:response-ok? resp) "response ok")
        (assert-equal 3 (getf (limn/bridge:response-data resp) :|page|)
                      "data.page round-trips")
        ;; Did the request leave the wire?
        (let ((sent (first (mock-outgoing m))))
          (assert-true (search "\"cmd\":\"view/get\"" sent)
                       "request encoded view/get")
          (assert-true (search "\"id\":\"r1\"" sent)
                       "request used id r1"))))))

(deftest dispatch-call-timeout
  ;; No staged response: call should signal.
  (let ((limn/dispatch::*request-timeout* 0.2))
    (multiple-value-bind (sess m) (new-mock-session)
      (declare (ignore m))
      (assert-error error
        (limn/dispatch:call sess "view/get" :|win-id| "w1")))))

(deftest dispatch-event-fires-hook
  ;; pump() should pull an event line and run the matching hook.
  (limn/hooks:clear-all-hooks)
  (multiple-value-bind (sess m) (new-mock-session)
    (let ((seen '()))
      (limn/hooks:add-hook (limn/dispatch:event-hook-name "buffer-opened")
                           (lambda (ev) (push ev seen)))
      (mock-push-line m "{\"event\":\"buffer-opened\",\"buffer-id\":\"b1\"}")
      (let ((n (limn/dispatch:pump sess)))
        (assert-equal 1 n "pump processed one line"))
      (assert-equal 1 (length seen) "hook fired once")
      (assert-equal "b1" (getf (first seen) :|buffer-id|)
                    "event payload reached the handler"))))

(deftest dispatch-stale-response-is-dropped
  ;; A response with an id we never sent should be silently ignored (i.e.
  ;; not crash, not leak into the next call).
  (let ((limn/dispatch::*request-timeout* 0.5))
    (multiple-value-bind (sess m) (new-mock-session)
      (mock-push-line m "{\"id\":\"ghost\",\"ok\":true,\"data\":null}")
      (mock-push-line m "{\"id\":\"r1\",\"ok\":true,\"data\":{\"x\":1}}")
      (let ((resp (limn/dispatch:call sess "view/get")))
        (assert-equal 1 (getf (limn/bridge:response-data resp) :|x|)
                      "correct response matched despite stale prior")))))

(deftest dispatch-interleaved-event-and-response
  ;; An event arriving before the response should fire its hook AND let
  ;; the response still be matched.
  (limn/hooks:clear-all-hooks)
  (let ((limn/dispatch::*request-timeout* 0.5)
        (events 0))
    (multiple-value-bind (sess m) (new-mock-session)
      (limn/hooks:add-hook (limn/dispatch:event-hook-name "tick")
                           (lambda (_) (declare (ignore _)) (incf events)))
      (mock-push-line m "{\"event\":\"tick\"}")
      (mock-push-line m "{\"id\":\"r1\",\"ok\":true,\"data\":42}")
      (let ((resp (limn/dispatch:call sess "noop")))
        (assert-equal 42 (limn/bridge:response-data resp) "response matched")
        (assert-equal 1 events "event hook fired once")))))

(deftest dispatch-notify-no-wait
  ;; notify() should just write and return, not block.
  (multiple-value-bind (sess m) (new-mock-session)
    (limn/dispatch:notify sess "test/ping" :|n| 7)
    (let ((sent (first (mock-outgoing m))))
      (assert-true (search "\"cmd\":\"test/ping\"" sent) "cmd encoded")
      (assert-true (search "\"n\":7" sent) "arg encoded"))))
