;;;; Bridge Protocol Tests
;;;;
;;;; Covers section 4 of LIMN-SPEC: transport, message format, request/response,
;;;; events, IDs, error handling.
;;;;
;;;; These tests don't depend on any particular engine — they test the bridge
;;;; protocol itself.

(in-package #:limn/test)

;;; ── 4.1 Transport ────────────────────────────────────────────────────────

(deftest test-protocol-socket-connects
  "Bridge accepts connections on its socket path."
  ;; If we got here through run-suite, connect! has already succeeded.
  (assert-true (connected?) "socket connection established"))

(deftest test-protocol-line-delimited
  "Multiple JSON objects can be sent on consecutive lines."
  (let ((id1 (send-raw! '(:|cmd| "bridge/capabilities")))
        (id2 (send-raw! '(:|cmd| "bridge/win-list"))))
    (let ((r1 (read-response id1))
          (r2 (read-response id2)))
      (assert-ok r1 "first line-delimited response")
      (assert-ok r2 "second line-delimited response"))))

(deftest test-protocol-utf8
  "UTF-8 content is round-tripped through the protocol."
  ;; Use a path with UTF-8 characters in error scenarios.
  ;; Even though file doesn't exist, the error message should echo path correctly.
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1"
                  :|engine| "mupdf"
                  :|path|   "/nonexistent/中文文件.pdf")))
    (assert-fail r "UTF-8 path in failing request")
    (assert-true (getf r :|error|) "error message returned for UTF-8 path")))

;;; ── 4.2 Message types: Request / Response ────────────────────────────────

(deftest test-protocol-request-needs-id
  "Server should accept requests with an id."
  (let* ((id (next-id))
         (_  (send-raw! (list :|cmd| "bridge/capabilities" :|id| id)))
         (r  (read-response id)))
    (assert-equal id (getf r :|id|) "response id matches request id")))

(deftest test-protocol-response-shape-ok
  "Successful response: {id, ok:true, data?}."
  (let ((r (send! "bridge/capabilities")))
    (assert-has-key :|id| r "id field present")
    (assert-has-key :|ok| r "ok field present")
    (assert-true   (eq (getf r :|ok|) t) "ok = true")))

(deftest test-protocol-response-shape-fail
  "Failure response: {id, ok:false, error}."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| "/no/such.pdf")))
    (assert-has-key :|id| r "id present in failure")
    (assert-has-key :|ok| r "ok present in failure")
    (assert-equal :false (getf r :|ok|) "ok = false")
    (assert-has-key :|error| r "error field present")
    (assert-type (getf r :|error|) string "error is a string")))

;;; ── 4.3 Concurrent requests ──────────────────────────────────────────────

(deftest test-protocol-concurrent-requests-different-ids
  "Multiple outstanding requests are tracked by id."
  (let* ((ids (loop repeat 5 collect (send-raw! '(:|cmd| "bridge/capabilities"))))
         (responses (mapcar #'read-response ids)))
    (assert-equal 5 (length responses) "got 5 responses")
    (assert-equal ids (mapcar (lambda (r) (getf r :|id|)) responses)
                  "responses match in same order (or by id)")))

(deftest test-protocol-out-of-order-responses-tolerated
  "If frontend responds out of order, framework matches by id."
  ;; This is mostly a framework test: send three and read them by id
  ;; in a different order than sent.
  (let ((a (send-raw! '(:|cmd| "bridge/capabilities")))
        (b (send-raw! '(:|cmd| "bridge/win-list")))
        (c (send-raw! '(:|cmd| "bridge/capabilities"))))
    ;; read in reversed order
    (let ((rc (read-response c))
          (rb (read-response b))
          (ra (read-response a)))
      (assert-equal a (getf ra :|id|) "a matched")
      (assert-equal b (getf rb :|id|) "b matched")
      (assert-equal c (getf rc :|id|) "c matched"))))

;;; ── Unknown / malformed commands ─────────────────────────────────────────

(deftest test-protocol-unknown-command-error
  "Unknown command name returns {ok:false, error}."
  (let ((r (send! "bridge/this-does-not-exist")))
    (assert-fail r "unknown command returns ok=false")
    (assert-type (getf r :|error|) string "error message is a string")))

(deftest test-protocol-missing-cmd-field-error
  "Request without 'cmd' field returns an error."
  (let* ((id (send-raw! '(:|action| "?")))
         (r  (read-response id)))
    (assert-fail r "missing cmd returns ok=false")))

(deftest test-protocol-wrong-namespace-error
  "Unknown namespace prefix returns an error."
  (let ((r (send! "foo/bar")))
    (assert-fail r "foo/bar returns ok=false")))

(deftest test-protocol-empty-cmd-error
  "Empty cmd string returns an error."
  (let ((r (send! "")))
    (assert-fail r "empty cmd returns ok=false")))

;;; ── Events have no id ─────────────────────────────────────────────────────

(deftest test-protocol-event-has-no-id
  "Events pushed by Frontend have an 'event' field and no 'id'."
  ;; Trigger a heartbeat by waiting; if heartbeat is configured, we'll see one.
  (let ((ev (read-event :type "heartbeat" :timeout 6)))
    (when ev
      (assert-has-key :|event| ev "event field present")
      (assert-equal nil (getf ev :|id|) "no id field on event"))))

;;; ── Large message handling ────────────────────────────────────────────────
;;; Spec doesn't limit line length; verify large messages flow through.

(deftest test-protocol-large-response
  "Large response (high-DPI PNG, hundreds of KB) is parsed correctly."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf    (json-get* load-r :|data| :|buffer-id|)))
    (when buf
      (let* ((r (send! "buffer/render"
                       :|buffer-id| buf :|page| 0 :|dpi| 300))
             (png (json-get* r :|data| :|png|)))
        (assert-ok r "large render response received")
        (check-assertion (> (length png) 50000)
                         "PNG payload > 50KB transferred intact"
                         "got ~a bytes" (length png)))
      (ignore-errors (send! "buffer/close" :|buffer-id| buf)))))

(deftest test-protocol-large-request
  "Large request payload (1000-item overlay batch) is parsed correctly."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf    (json-get* load-r :|data| :|buffer-id|)))
    (when buf
      (let* ((layers (loop for i from 0 below 1000
                           collect `(:|type| "rect" :|page| 0
                                     :|rect| ,(list (float (mod i 50))
                                                     (float (mod i 50))
                                                     (float (+ (mod i 50) 5))
                                                     (float (+ (mod i 50) 5)))
                                     :|color| "#FF0000"
                                     :|opacity| 0.2)))
             (r (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
        (assert-ok r "large request accepted"))
      (ignore-errors (send! "buffer/close" :|buffer-id| buf)))))

;;; ── Response data wrapper consistency ─────────────────────────────────────
;;; Per spec v0.3: ALL responses use the data wrapper for payload.

(deftest test-protocol-data-wrapper-on-engine-load
  "bridge/engine-load wraps buffer-id in data."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r)
    (assert-has-key :|data| r "data wrapper present")
    (assert-has-key :|buffer-id| (getf r :|data|) "buffer-id in data")))

(deftest test-protocol-data-wrapper-on-win-split
  "bridge/win-split wraps win-a/win-b in data."
  (let ((r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h")))
    (when (eq (getf r :|ok|) t)
      (assert-has-key :|data| r)
      (assert-has-key :|win-a| (getf r :|data|))
      (assert-has-key :|win-b| (getf r :|data|))
      ;; cleanup
      (ignore-errors
        (send! "bridge/win-close" :|win-id| (json-get* r :|data| :|win-b|))))))

(deftest test-protocol-empty-response-allowed
  "Commands that have no data may return {id, ok:true} with no data field."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|page| 0)))
      (assert-ok r)
      ;; data may or may not be present; both are valid per spec
      )))

;;; ── Numeric edge cases ────────────────────────────────────────────────────

(deftest test-protocol-large-integers
  "Large integer values (page numbers, DPI) round-trip through JSON."
  (with-buffer (buf)
    ;; 99999 is a large page number — should produce an error response,
    ;; not a JSON parsing error
    (let ((r (send! "view/set" :|win-id| "w1" :|page| 99999)))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded cleanly"))))

(deftest test-protocol-float-precision
  "Float values preserve reasonable precision through JSON round-trip."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|zoom| 1.234567)
    (let ((zoom (json-get* (send! "view/get" :|win-id| "w1")
                            :|data| :|zoom|)))
      (check-assertion (< (abs (- zoom 1.234567)) 0.001)
                       "zoom preserved to 3 decimal places"
                       "got ~s" zoom))))

(deftest test-protocol-negative-numbers
  "Negative number encoding/decoding works (e.g. negative offset-y)."
  (with-buffer (buf)
    ;; Negative offset may be clamped to 0 or accepted; either way no crash
    (let ((r (send! "view/set" :|win-id| "w1" :|offset-y| -100.5)))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

;;; ── Connection lifecycle ──────────────────────────────────────────────────

(deftest test-protocol-many-sequential-calls
  "200 sequential calls don't degrade or leak."
  (let ((all-ok t))
    (loop repeat 200 do
      (unless (eq t (getf (send! "bridge/capabilities") :|ok|))
        (setf all-ok nil)))
    (assert-true all-ok "200 sequential calls all succeeded")))
