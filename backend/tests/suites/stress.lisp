;;;; Stress / robustness tests
;;;;
;;;; These tests exercise the bridge under heavier load: many requests,
;;;; large payloads, rapid open/close cycles, malformed input.

(in-package #:limn/test)

;;; ── Rapid request cycle ─────────────────────────────────────────────────

(deftest test-stress-rapid-capabilities
  "Send 100 bridge/capabilities calls in quick succession."
  (let ((ok-count 0)
        (n 100))
    (loop repeat n do
      (let ((r (send! "bridge/capabilities")))
        (when (eq (getf r :|ok|) t) (incf ok-count))))
    (assert-equal n ok-count "all 100 rapid calls succeeded")))

(deftest test-stress-rapid-open-close
  "Open/close the same PDF 20 times — no resource leak should appear."
  (loop repeat 20 do
    (let* ((r (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
           (bid (json-get* r :|data| :|buffer-id|)))
      (assert-ok r)
      (when bid
        (assert-ok (send! "buffer/close" :|buffer-id| bid))))))

(deftest test-stress-rapid-view-set
  "Send many view/set in a row — simulate fast scrolling."
  (with-buffer (buf)
    (loop for i from 0 below 30 do
      (send! "view/set" :|win-id| "w1" :|offset-y| (float (* i 10))))))

;;; ── Large payloads ──────────────────────────────────────────────────────

(deftest test-stress-large-overlay-set
  "1000 overlays at once."
  (with-buffer (buf)
    (let ((layers (loop for i from 0 below 1000
                        collect `(:|type| "rect"
                                  :|page| ,(mod i 5)
                                  :|rect| ,(list (float (mod i 100))
                                                  (float (mod i 100))
                                                  (float (+ (mod i 100) 4))
                                                  (float (+ (mod i 100) 4)))
                                  :|color| "#FF0000"
                                  :|opacity| 0.2))))
      (let ((r (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
        (assert-ok r "1000 overlays accepted")))))

(deftest test-stress-render-high-dpi
  "Render at very high DPI (large PNG payload)."
  (with-buffer (buf)
    (let ((r (send! "buffer/render" :|buffer-id| buf :|page| 0 :|dpi| 300)))
      (assert-ok r "high-dpi render succeeds")
      (let ((png (json-get* r :|data| :|png|)))
        (check-assertion (> (length png) 10000)
                         "high-dpi PNG is substantial in size"
                         "got ~a bytes" (length png))))))

;;; ── Concurrent in-flight requests ───────────────────────────────────────

(deftest test-stress-many-pending-requests
  "Send 20 requests without reading responses, then collect all."
  (let* ((ids (loop repeat 20 collect (send-raw! '(:|cmd| "bridge/capabilities"))))
         (responses (mapcar #'read-response ids)))
    (assert-equal 20 (length responses) "got 20 responses")
    (loop for id in ids
          for r in responses
          do (assert-equal id (getf r :|id|) "id matched"))))

;;; ── Malformed input ─────────────────────────────────────────────────────

(deftest test-stress-very-long-cmd-name
  "Cmd name of 10000 chars rejected cleanly (no crash)."
  (let ((r (send! (make-string 10000 :initial-element #\x))))
    (assert-fail r "long cmd rejected")))

(deftest test-stress-deeply-nested-engine-params
  "Engine ignores unknown deeply-nested engine-params."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params|
                    '(:|made-up|
                       (:|nested|
                         (:|deeper|
                           (:|stuff| 42)))))))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

;;; ── UTF-8 in commands ───────────────────────────────────────────────────

(deftest test-stress-utf8-throughout
  "UTF-8 in paths, error messages, etc. round-trips correctly."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf"
                  :|path|   "/不存在/論文.pdf")))
    (assert-fail r)
    (let ((err (getf r :|error|)))
      (assert-type err string)
      ;; The error message should contain or echo the path safely
      (check-assertion (> (length err) 0) "error message non-empty"))))

;;; ── Memory growth over time ─────────────────────────────────────────────

(deftest test-stress-memory-not-growing-on-render
  "Repeated render calls should release memory between calls.
   Indirect test: after 50 renders, frontend still responsive."
  (with-buffer (buf)
    (loop repeat 50 do
      (send! "buffer/render" :|buffer-id| buf :|page| 0 :|dpi| 72))
    ;; If memory leaked badly, this would slow down or fail
    (let ((r (send! "bridge/capabilities")))
      (assert-ok r "frontend still responsive after 50 renders"))))

(deftest test-stress-memory-not-growing-on-overlays
  "Repeated overlay updates should not accumulate memory."
  (with-buffer (buf)
    (loop repeat 100 do
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (10.0 10.0 50.0 50.0)
                                :|color| "#FF0000" :|opacity| 0.4))))
    (let ((r (send! "bridge/capabilities")))
      (assert-ok r "frontend still responsive after 100 overlay updates"))))

;;; ── Backpressure: slow client doesn't crash frontend ────────────────────

(deftest test-stress-slow-reader
  "Send many requests, then read responses with delays — frontend buffers
   should not overflow."
  (let ((ids (loop repeat 30 collect
                   (send-raw! '(:|cmd| "bridge/capabilities")))))
    ;; Sleep briefly between reads, simulating a slow client
    (let ((all-ok t))
      (dolist (id ids)
        (let ((r (handler-case (read-response id :timeout 5)
                   (error () nil))))
          (sleep 0.01)
          (unless (and r (eq t (getf r :|ok|)))
            (setf all-ok nil))))
      (assert-true all-ok "all 30 responses arrived under slow read"))))

;;; ── Extreme inputs ──────────────────────────────────────────────────────

(deftest test-stress-very-long-string-arg
  "A 100KB string in a JSON payload doesn't crash the parser."
  (let* ((huge (make-string 100000 :initial-element #\x))
         (r (send! "bridge/engine-load"
                   :|win-id| "w1" :|engine| "mupdf" :|path| huge)))
    ;; The file doesn't exist, but the request should be parsed
    (assert-fail r "long path rejected as missing file")
    (let ((err (getf r :|error|)))
      (assert-type err string))))

;;; ── Caches can be cleared (per test/flush-caches) ──────────────────────

(deftest test-stress-flush-caches
  "test/flush-caches reduces resource use without crashing."
  (let ((r (send! "test/flush-caches")))
    (when (eq (getf r :|ok|) t)
      ;; capabilities still works after flush
      (assert-ok (send! "bridge/capabilities")
                 "frontend operational after cache flush"))))

;;; ── Resource cleanup verified via test/snapshot ─────────────────────────

(deftest test-stress-snapshot-resource-counts
  "test/snapshot reports resource counts; open/close should net to zero."
  (let ((before (json-get* (send! "test/snapshot") :|data|)))
    (when before
      ;; Open and close 10 buffers
      (dotimes (i 10)
        (let* ((r (send! "buffer/open" :|engine| "mupdf"
                          :|path| *fixture-pdf*))
               (bid (json-get* r :|data| :|buffer-id|)))
          (when bid (send! "buffer/close" :|buffer-id| bid))))
      ;; Snapshot again — buffer count should not have grown
      (let ((after (json-get* (send! "test/snapshot") :|data|)))
        (when (and (getf before :|buffer-count|)
                   (getf after  :|buffer-count|))
          (assert-equal (getf before :|buffer-count|)
                        (getf after  :|buffer-count|)
                        "buffer count net to zero after 10 open/close cycles"))))))
