;;;; minibuffer tests — SPEC §5.4 commands + §6 minibuffer events.
;;;;
;;;; All RED until v0.7 implements the minibuffer widget + command
;;;; handlers + the event-routing rules in the input filter.

(in-package #:limn/test)

;;; ── §5.4 minibuffer/ commands ─────────────────────────────────────────

(deftest test-minibuffer-open-close-cycle
  "open → get shows {open:true}; close → get shows {open:false}."
  ;; ensure starts closed (idempotent close)
  (ignore-errors (send! "minibuffer/close"))
  (let ((r (send! "minibuffer/get")))
    (assert-equal :false (json-get* r :|data| :|open|)
                  "starts closed"))
  (assert-ok (send! "minibuffer/open" :|prompt| "/"))
  (let* ((r (send! "minibuffer/get"))
         (d (json-get* r :|data|)))
    (assert-equal t   (getf d :|open|)   "open=true after open")
    (assert-equal "/" (getf d :|prompt|) "prompt persisted"))
  (assert-ok (send! "minibuffer/close"))
  (let ((r (send! "minibuffer/get")))
    (assert-equal :false (json-get* r :|data| :|open|)
                  "closed after close")))

(deftest test-minibuffer-set-prompt-while-open
  (send! "minibuffer/open" :|prompt| "/")
  (assert-ok (send! "minibuffer/set-prompt" :|prompt| "Search: "))
  (assert-equal "Search: "
                (json-get* (send! "minibuffer/get") :|data| :|prompt|))
  (send! "minibuffer/close"))

(deftest test-minibuffer-set-text-replaces-content
  (send! "minibuffer/open" :|prompt| "/")
  (assert-ok (send! "minibuffer/set-text" :|text| "hello world"))
  (assert-equal "hello world"
                (json-get* (send! "minibuffer/get") :|data| :|text|))
  (send! "minibuffer/close"))

(deftest test-minibuffer-set-prompt-while-closed-fails
  "Per SPEC, set-prompt only meaningful while open."
  (ignore-errors (send! "minibuffer/close"))
  (let ((r (send! "minibuffer/set-prompt" :|prompt| "Search: ")))
    (assert-false (eq t (getf r :|ok|))
                  "set-prompt on closed minibuffer should fail")))

;;; ── §6 minibuffer events ───────────────────────────────────────────────

(deftest test-printable-keystroke-emits-minibuffer-input-not-key
  "Per SPEC §6: while minibuffer is open, a printable char emits
   minibuffer-input (with cumulative text) and NOT key."
  (drain-events)
  (send! "minibuffer/open" :|prompt| "/")
  (send! "test/inject-qt-key" :|key| "h")
  (let ((mi (read-event :type "minibuffer-input" :timeout 1)))
    (assert-true mi "got minibuffer-input")
    (when mi
      (assert-equal "h" (getf mi :|text|) "text=\"h\"")))
  ;; And NO key event for the same press
  (let ((stray (read-event :type "key" :timeout 0.3)))
    (assert-false stray "no spurious key event for printable"))
  (send! "minibuffer/close"))

(deftest test-minibuffer-input-accumulates-text
  "Each printable keystroke pushes the cumulative text."
  (drain-events)
  (send! "minibuffer/open" :|prompt| "/")
  (send! "test/inject-qt-key" :|key| "h")
  (send! "test/inject-qt-key" :|key| "i")
  (let ((ev1 (read-event :type "minibuffer-input" :timeout 1)))
    (assert-equal "h" (getf ev1 :|text|) "first event has \"h\""))
  (let ((ev2 (read-event :type "minibuffer-input" :timeout 1)))
    (assert-equal "hi" (getf ev2 :|text|) "second event has \"hi\""))
  (send! "minibuffer/close"))

(deftest test-RET-emits-minibuffer-submit
  (drain-events)
  (send! "minibuffer/open" :|prompt| "/")
  (send! "test/inject-qt-key" :|key| "y")
  (send! "test/inject-qt-key" :|key| "o")
  (send! "test/inject-qt-key" :|key| "RET")
  (let ((submit (read-event :type "minibuffer-submit" :timeout 1)))
    (assert-true submit "got minibuffer-submit")
    (when submit
      (assert-equal "yo" (getf submit :|text|) "submitted text=\"yo\""))))

(deftest test-ESC-emits-minibuffer-cancel
  (drain-events)
  (send! "minibuffer/open" :|prompt| "/")
  (send! "test/inject-qt-key" :|key| "a")
  (send! "test/inject-qt-key" :|key| "ESC")
  (let ((cancel (read-event :type "minibuffer-cancel" :timeout 1)))
    (assert-true cancel "got minibuffer-cancel")))

(deftest test-modifier-combo-still-emits-key-event
  "C-g during minibuffer still produces a normal key event so global
   bindings (cancel, history-prev, etc) remain reachable."
  (drain-events)
  (send! "minibuffer/open" :|prompt| "/")
  (send! "test/inject-qt-key" :|key| "g" :|mods| (list "ctrl"))
  (let ((kev (read-event :type "key" :timeout 1)))
    (assert-true kev "C-g still emits key event during minibuffer")
    (when kev
      (assert-equal "g" (getf kev :|key|))
      (assert-contains "ctrl" (getf kev :|mods|))))
  (ignore-errors (send! "minibuffer/close")))

(deftest test-closed-minibuffer-passes-keys-through
  "When minibuffer is closed, a printable keystroke is a normal key
   event (sanity check the routing is conditional)."
  (ignore-errors (send! "minibuffer/close"))
  (drain-events)
  (send! "test/inject-qt-key" :|key| "j")
  (let ((kev (read-event :type "key" :timeout 1)))
    (assert-true kev "j emits key event when minibuffer closed")))
