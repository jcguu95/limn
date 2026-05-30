;;;; v0.37 — logging / *Messages* hierarchical ns + wire mirror RED tests.
;;;;
;;;; Adds on top of v0.23 §E:
;;;;   - log-record struct (time / level / ns / text) + get-records
;;;;   - hierarchical namespace verbosity via dotted symbols
;;;;     (e.g. 'pdf-mode.annotation.edit inherits from 'pdf-mode.annotation
;;;;     then 'pdf-mode then *default-log-level*)
;;;;   - set-level / unset-level / get-level / effective-level
;;;;   - with-log-levels macro for dynamic per-ns overrides
;;;;   - *log-wire-sender* hook so messages mirror to the C++ *messages*
;;;;     GapBuffer per-message (NIL in unit tests = no wire side effect)
;;;;
;;;; Backward-compat: all v0.23 call shapes ((message "x") /
;;;; (message :warn "x" args)) still pass.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/log)
    (make-package '#:limn/log :use '(#:cl)))
  (dolist (sym '("MESSAGE"
                 "*MESSAGES-RING-SIZE*"
                 "GET-MESSAGES" "CLEAR-MESSAGES"
                 "*LOG-LEVEL*" "WITH-LOG-LEVEL" "LEVEL>="
                 ;; v0.37 additions
                 "LOG-RECORD" "MAKE-LOG-RECORD"
                 "LOG-RECORD-TIME" "LOG-RECORD-LEVEL"
                 "LOG-RECORD-NS" "LOG-RECORD-TEXT"
                 "GET-RECORDS"
                 "*DEFAULT-LOG-LEVEL*" "*LOG-LEVELS*"
                 "SET-LEVEL" "UNSET-LEVEL" "GET-LEVEL"
                 "EFFECTIVE-LEVEL" "WITH-LOG-LEVELS"
                 "*LOG-WIRE-SENDER*"))
    (let ((s (intern sym '#:limn/log)))
      (export s '#:limn/log))))

(in-package #:limn/unit-test)

(defmacro with-clean-log-v037 (&body body)
  `(progn
     (limn/log:clear-messages)
     (when (hash-table-p limn/log:*log-levels*)
       (clrhash limn/log:*log-levels*))
     ,@body))

;;; ─── H. hierarchical ns / verbosity ──────────────────────────────────

(deftest log-h1-default-fallback
  "Unset ns resolves to *default-log-level*."
  (with-clean-log-v037
    (let ((limn/log:*default-log-level* :info))
      (assert-eql :info (limn/log:effective-level 'pdf-mode.annotation)))))

(deftest log-h2-explicit-overrides-default
  "set-level on an ns makes effective-level return that level."
  (with-clean-log-v037
    (let ((limn/log:*default-log-level* :info))
      (limn/log:set-level 'pdf-mode :debug)
      (assert-eql :debug (limn/log:effective-level 'pdf-mode)))))

(deftest log-h3-leaf-inherits-from-parent
  "A ns with no explicit binding inherits the nearest ancestor's."
  (with-clean-log-v037
    (let ((limn/log:*default-log-level* :info))
      (limn/log:set-level 'pdf-mode :debug)
      (assert-eql :debug
                  (limn/log:effective-level 'pdf-mode.annotation)))))

(deftest log-h4-deeper-wins-over-shallower
  "More specific ns binding wins over an ancestor."
  (with-clean-log-v037
    (let ((limn/log:*default-log-level* :info))
      (limn/log:set-level 'pdf-mode :warn)
      (limn/log:set-level 'pdf-mode.annotation :debug)
      (assert-eql :debug
                  (limn/log:effective-level 'pdf-mode.annotation.edit))
      (assert-eql :warn
                  (limn/log:effective-level 'pdf-mode.other)))))

(deftest log-h5-unset-level-restores-inheritance
  "unset-level removes an explicit binding; effective-level falls back."
  (with-clean-log-v037
    (let ((limn/log:*default-log-level* :warn))
      (limn/log:set-level 'pdf-mode :debug)
      (limn/log:unset-level 'pdf-mode)
      (assert-eql :warn (limn/log:effective-level 'pdf-mode)))))

(deftest log-h6-get-level-explicit-only
  "get-level returns only the exact binding (NIL if merely inherited)."
  (with-clean-log-v037
    (limn/log:set-level 'pdf-mode :debug)
    (assert-eql :debug (limn/log:get-level 'pdf-mode))
    (assert-eql nil    (limn/log:get-level 'pdf-mode.annotation))))

(deftest log-h7-with-log-levels-shadows-and-restores
  "with-log-levels dynamically rebinds; values restore after BODY."
  (with-clean-log-v037
    (limn/log:set-level 'pdf-mode :warn)
    (limn/log:with-log-levels ((pdf-mode :debug)
                               (auto-revert :error))
      (assert-eql :debug (limn/log:effective-level 'pdf-mode))
      (assert-eql :error (limn/log:effective-level 'auto-revert)))
    (assert-eql :warn (limn/log:effective-level 'pdf-mode))
    (assert-eql limn/log:*default-log-level*
                (limn/log:effective-level 'auto-revert))))

(deftest log-h8-ns-symbol-package-irrelevant
  "Ns is canonicalised by symbol-name — different packages, same name."
  (with-clean-log-v037
    (limn/log:set-level (intern "PDF-MODE" :keyword) :debug)
    ;; 'pdf-mode interns in CL-USER (or current package); name still PDF-MODE
    (assert-eql :debug (limn/log:effective-level 'pdf-mode))))

;;; ─── R. log-record struct ────────────────────────────────────────────

(deftest log-r1-get-records-returns-structs
  "get-records returns log-record structs newest-first."
  (with-clean-log-v037
    (limn/log:message :warn "boom")
    (let ((recs (limn/log:get-records)))
      (assert-eql 1 (length recs))
      (let ((r (first recs)))
        (assert-eql :warn (limn/log:log-record-level r))
        (assert-true (search "boom" (limn/log:log-record-text r)))))))

(deftest log-r2-record-carries-ns
  "message with :ns sets the record's ns slot."
  (with-clean-log-v037
    (limn/log:message :level :info :ns 'pdf-mode.annotation "x")
    (let ((r (first (limn/log:get-records))))
      (assert-equal "PDF-MODE.ANNOTATION"
                    (string (limn/log:log-record-ns r))))))

(deftest log-r3-record-default-ns
  "Omitting :ns yields the default ns."
  (with-clean-log-v037
    (limn/log:message "no-ns")
    (let ((r (first (limn/log:get-records))))
      (assert-equal "DEFAULT"
                    (string (limn/log:log-record-ns r))))))

(deftest log-r4-record-has-universal-time
  "log-record-time is a positive integer (universal-time)."
  (with-clean-log-v037
    (limn/log:message "stamped")
    (let ((r (first (limn/log:get-records))))
      (assert-true (and (integerp (limn/log:log-record-time r))
                        (plusp   (limn/log:log-record-time r)))))))

;;; ─── W. wire sender ──────────────────────────────────────────────────

(deftest log-w1-sender-called-when-level-passes
  "*log-wire-sender* fires exactly once per visible message."
  (with-clean-log-v037
    (let ((calls '()))
      (let ((limn/log:*log-wire-sender*
             (lambda (rec) (push rec calls))))
        (limn/log:message "hi")
        (assert-eql 1 (length calls))))))

(deftest log-w2-sender-not-called-when-filtered
  "Filtered messages still hit the ring but NOT the wire sender."
  (with-clean-log-v037
    (let ((calls '())
          (limn/log:*default-log-level* :warn))
      (let ((limn/log:*log-wire-sender*
             (lambda (rec) (push rec calls))))
        (limn/log:message :info "below-threshold")
        (assert-eql 0 (length calls))
        (assert-true (find "below-threshold"
                           (limn/log:get-messages)
                           :test #'search))))))

(deftest log-w3-sender-nil-no-crash
  "With *log-wire-sender* NIL (default), message must not crash."
  (with-clean-log-v037
    (let ((limn/log:*log-wire-sender* nil))
      (assert-no-error (limn/log:message "no wire installed")))))

(deftest log-w4-sender-receives-log-record
  "Sender receives a log-record, not a raw string."
  (with-clean-log-v037
    (let (received)
      (let ((limn/log:*log-wire-sender*
             (lambda (rec) (setf received rec))))
        (limn/log:message :level :warn :ns 'pdf-mode "x"))
      (assert-true received)
      (assert-eql :warn (limn/log:log-record-level received))
      (assert-equal "PDF-MODE"
                    (string (limn/log:log-record-ns received))))))

(deftest log-w5-sender-errors-do-not-corrupt-ring
  "If the wire sender throws, the message still landed in the ring."
  (with-clean-log-v037
    (let ((limn/log:*log-wire-sender*
           (lambda (rec) (declare (ignore rec))
             (error "boom from sender"))))
      (assert-no-error (limn/log:message "survives-sender-crash"))
      (assert-true (find "survives-sender-crash"
                         (limn/log:get-messages)
                         :test #'search)))))

;;; ─── M. message API with ns ──────────────────────────────────────────

(deftest log-m1-ns-filtered-by-effective-level
  "Per-ns level threshold filters wire and event but not ring."
  (with-clean-log-v037
    (let ((calls '())
          (limn/log:*default-log-level* :info))
      (limn/log:set-level 'noisy :error)
      (let ((limn/log:*log-wire-sender*
             (lambda (rec) (push rec calls))))
        (limn/log:message :level :info :ns 'noisy "stifled")
        (assert-eql 0 (length calls))
        (assert-true (find "stifled" (limn/log:get-messages)
                           :test #'search))))))

(deftest log-m2-ns-passes-when-set-permissive
  "A per-ns :debug binding lets :info pass even when default is :error."
  (with-clean-log-v037
    (let ((calls '())
          (limn/log:*default-log-level* :error))
      (limn/log:set-level 'verbose :debug)
      (let ((limn/log:*log-wire-sender*
             (lambda (rec) (push rec calls))))
        (limn/log:message :level :info :ns 'verbose "shown")
        (assert-eql 1 (length calls))))))

(deftest log-m3-old-call-shape-still-works
  "v0.23 call shapes (no :ns / no :level keyword) still pass through."
  (with-clean-log-v037
    (limn/log:message "plain")
    (limn/log:message :warn "warn-y ~A" 1)
    (let ((msgs (limn/log:get-messages)))
      (assert-true (find "plain" msgs :test #'search))
      (assert-true (find "warn-y 1" msgs :test #'search)))))

(deftest log-m4-keyword-message-shape
  "New keyword-style (message :level L :ns N fmt args) works."
  (with-clean-log-v037
    (limn/log:message :level :warn :ns 'pdf-mode "x=~A" 42)
    (let ((r (first (limn/log:get-records))))
      (assert-eql :warn (limn/log:log-record-level r))
      (assert-equal "PDF-MODE"
                    (string (limn/log:log-record-ns r)))
      (assert-true (search "x=42" (limn/log:log-record-text r))))))
