;;;; Unit tests for the minibuffer-read round-trip — defcommand with an
;;;; "s" interactive spec must drive a real bridge minibuffer/open call,
;;;; wait for a minibuffer-submit event, and return its text.
;;;;
;;;; The whole point of batch 7: limn/cmd:*minibuffer-read* was a stub
;;;; that errored. Now installed at limn:start, it does the wire dance.
;;;;
;;;; These tests run against a MOCK session — we stage the
;;;; minibuffer/open response and the minibuffer-submit event, then call
;;;; call-interactively and verify the command body received the text.

(in-package #:limn/unit-test)

;;; ── helpers ────────────────────────────────────────────────────────────

;; Re-use the mock client / session machinery defined in dispatch.lisp.
;; (defstruct mock, mock-push-line, new-mock-session, etc.)

(defun stage-submit (m text)
  "Pre-stage a minibuffer-submit event on the mock incoming queue."
  (mock-push-line m
                  (format nil
                          "{\"event\":\"minibuffer-submit\",\"text\":\"~a\"}"
                          text)))

(defun stage-cancel (m)
  (mock-push-line m "{\"event\":\"minibuffer-cancel\"}"))

(defun stage-response (m id)
  "Stage an ok response with no body — used for minibuffer/open + close."
  (mock-push-line m (format nil "{\"id\":\"~a\",\"ok\":true}" id)))

;;; ── wait-for-event ─────────────────────────────────────────────────────

(deftest wait-for-event-fires-on-matching-event
  "wait-for-event blocks until predicate matches, pumping the socket itself
   when no background pump thread exists."
  (limn/hooks:clear-all-hooks)
  (multiple-value-bind (sess m) (new-mock-session)
    (let ((seen nil))
      (limn/hooks:add-hook (limn/dispatch:event-hook-name "test-evt")
                           (lambda (ev) (setf seen (getf ev :|payload|))))
      (mock-push-line m "{\"event\":\"test-evt\",\"payload\":42}")
      (limn/dispatch:wait-for-event sess (lambda () seen) :timeout 1.0)
      (assert-equal 42 seen "event payload landed via background pump"))))

(deftest wait-for-event-times-out
  (multiple-value-bind (sess m) (new-mock-session)
    (declare (ignore m))
    (assert-error error
      (limn/dispatch:wait-for-event sess (lambda () nil) :timeout 0.1))))

;;; ── defcommand "s" round-trip ──────────────────────────────────────────
;;;
;;; This is the headline test: an interactive command with `"sPrompt: "`
;;; should pull text from the wire, not from a placeholder.

(deftest defcommand-s-spec-pulls-from-minibuffer
  "call-interactively on a command with 'sX: ' spec drives minibuffer/open
   and returns the body's value computed from the minibuffer-submit text."
  (limn/cmd:clear-commands)
  (limn/hooks:clear-all-hooks)
  (multiple-value-bind (sess m) (new-mock-session)
    ;; Stage: response to minibuffer/open (r1), the submit event, then
    ;; response to minibuffer/close (r2).
    (stage-response m "r1")
    (stage-submit   m "hello")
    (stage-response m "r2")
    ;; Install the real minibuffer-read tied to this session.
    (let ((limn/cmd:*minibuffer-read* (limn/runtime:make-minibuffer-reader sess)))
      (limn/cmd:defcommand echo-input (:interactive "sSay: ")
        (lambda (s) (format nil "got: ~a" s)))
      (assert-equal "got: hello"
                    (limn/cmd:call-interactively 'echo-input)))
    ;; Verify the wire actually saw minibuffer/open.
    (assert-true (search "\"cmd\":\"minibuffer/open\"" (first (mock-outgoing m)))
                 "minibuffer/open was sent")
    (assert-true (search "\"prompt\":\"Say: \"" (first (mock-outgoing m)))
                 "prompt forwarded to wire")
    ;; minibuffer/close must follow — backend always closes per SPEC §5.4
    (assert-true (some (lambda (line)
                         (search "\"cmd\":\"minibuffer/close\"" line))
                       (mock-outgoing m))
                 "minibuffer/close was sent after submit")))

(deftest defcommand-s-spec-cancel-signals
  "minibuffer-cancel must propagate as an error so callers know the
   command was aborted (Emacs' quit semantics)."
  (limn/cmd:clear-commands)
  (limn/hooks:clear-all-hooks)
  (multiple-value-bind (sess m) (new-mock-session)
    (stage-response m "r1")    ; minibuffer/open
    (stage-cancel   m)
    (stage-response m "r2")    ; minibuffer/close (still sent)
    (let ((limn/cmd:*minibuffer-read* (limn/runtime:make-minibuffer-reader sess)))
      (limn/cmd:defcommand cancellable (:interactive "sX: ")
        (lambda (s) (declare (ignore s)) :should-not-reach))
      (assert-error error
        (limn/cmd:call-interactively 'cancellable)))))
