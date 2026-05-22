;;;; chrome tests — SPEC §5.5 message/ + §5.6 modeline/.
;;;;
;;;; Minibuffer gets its own (much bigger) suite in minibuffer.lisp.

(in-package #:limn/test)

;;; ── message/* ──────────────────────────────────────────────────────────

(deftest test-message-echo-ok
  "message/echo with a non-empty text returns ok."
  (assert-ok (send! "message/echo" :|text| "hello from test")))

(deftest test-message-log-ok
  "message/log writes silently to *Messages*."
  (assert-ok (send! "message/log" :|text| "background msg")))

(deftest test-message-clear-ok
  "message/clear empties the echo area, doesn't fail."
  (assert-ok (send! "message/clear")))

(deftest test-message-echo-empty-text-fails
  "Empty text is rejected (matches buffer/render's similar invariants)."
  (let ((r (send! "message/echo" :|text| "")))
    (assert-false (eq t (getf r :|ok|))
                  "empty text should not silently pass")))

;;; ── modeline/* ─────────────────────────────────────────────────────────

(deftest test-modeline-set-then-get
  "Setting all three segments and reading them back round-trips."
  (assert-ok (send! "modeline/set"
                    :|win-id| "w1"
                    :|left|   "PDF: paper.pdf"
                    :|middle| "pdf-mode"
                    :|right|  "p5/42"))
  (let ((data (json-get* (send! "modeline/get" :|win-id| "w1") :|data|)))
    (assert-equal "PDF: paper.pdf" (getf data :|left|))
    (assert-equal "pdf-mode"       (getf data :|middle|))
    (assert-equal "p5/42"          (getf data :|right|))))

(deftest test-modeline-empty-strings-allowed
  "Empty segments are valid (renders as nothing)."
  (assert-ok (send! "modeline/set" :|win-id| "w1"
                    :|left| "" :|middle| "" :|right| "")))

(deftest test-modeline-partial-update
  "Setting just one segment leaves others unchanged."
  (send! "modeline/set" :|win-id| "w1"
         :|left| "L0" :|middle| "M0" :|right| "R0")
  (send! "modeline/set" :|win-id| "w1" :|middle| "M1")
  (let ((data (json-get* (send! "modeline/get" :|win-id| "w1") :|data|)))
    (assert-equal "L0" (getf data :|left|)   "left unchanged")
    (assert-equal "M1" (getf data :|middle|) "middle updated")
    (assert-equal "R0" (getf data :|right|)  "right unchanged")))

(deftest test-modeline-unknown-window-fails
  (let ((r (send! "modeline/set" :|win-id| "no-such-w" :|left| "x")))
    (assert-false (eq t (getf r :|ok|)))))
