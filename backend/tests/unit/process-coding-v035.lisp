;;;; v0.35 §C — process I/O coding RED tests (~16 tests)
;;;;
;;;; 覆蓋（SPEC v0.35 §C）：
;;;;   limn/process new keyword args on make-process:
;;;;     :coding-system           (both directions)
;;;;     :decode-coding-system    (stdout only)
;;;;     :encode-coding-system    (stdin only)
;;;;
;;;;   New dynvars / buffer-local:
;;;;     *default-process-coding-system* = '(utf-8 . utf-8)  (read . write)
;;;;     *buffer-process-coding-system*
;;;;
;;;; 內部實作：limn/process 讀 stdout 改成 raw bytes、靠 v0.31
;;;; limn/coding:decode-coding-string 解；寫 stdin 反向 encode。
;;;;
;;;; 全部 RED — limn-process.lisp 未加 coding 支援前 fail。

;; ── pre-intern new symbols on existing v0.23 limn/process ───────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/process)
    (make-package '#:limn/process :use '(#:cl)))
  (dolist (sym '("*DEFAULT-PROCESS-CODING-SYSTEM*"
                 "*BUFFER-PROCESS-CODING-SYSTEM*"
                 "PROCESS-DECODE-CODING"
                 "PROCESS-ENCODE-CODING"))
    (export (intern sym '#:limn/process) '#:limn/process)))

(in-package #:limn/unit-test)

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-coding-ready (&body body)
  "Run BODY only when both limn/process and limn/coding are loaded; skip
   if either is missing (used so the test file can READ before either
   module's coding extension is in place)."
  `(let ((proc-pkg (find-package '#:limn/process))
         (cod-pkg  (find-package '#:limn/coding)))
     (cond ((null proc-pkg)
            (format t "  (skipped: limn/process not loaded)~%"))
           ((null cod-pkg)
            (format t "  (skipped: limn/coding not loaded)~%"))
           ((null (find-symbol "FIND-CODING-SYSTEM" cod-pkg))
            (format t "  (skipped: coding API not available)~%"))
           (t ,@body))))

(defun %wait (p)
  (let ((wait (find-symbol "PROCESS-WAIT" '#:limn/process)))
    (when wait (funcall wait p :timeout 5))))

(defun %stdout (p)
  (funcall (symbol-function (find-symbol "PROCESS-STDOUT" '#:limn/process))
           p))

(defun %make-proc (&rest kw)
  (apply (symbol-function (find-symbol "MAKE-PROCESS" '#:limn/process)) kw))

(defun %send (p s)
  (funcall (symbol-function (find-symbol "PROCESS-SEND-STRING" '#:limn/process))
           p s))

(defun %send-eof (p)
  (funcall (symbol-function (find-symbol "PROCESS-SEND-EOF" '#:limn/process)) p))

;;; UTF-8 byte sequence for "中文" (E4 B8 AD E6 96 87) — used in many tests.

(defun %utf8-bytes (str)
  (sb-ext:string-to-octets str :external-format :utf-8))

(defun %hex (bytes)
  (with-output-to-string (s)
    (loop for b across bytes do (format s "~2,'0X" b))))

;;; ─── C1. :coding-system both directions ─────────────────────────────────

(deftest process-coding-c1-utf8-roundtrip-via-cat
  "spawn /bin/cat; send UTF-8 string '中文'; stdout should decode to '中文'."
  (with-coding-ready
    (let ((p (%make-proc :command '("/bin/cat") :coding-system 'utf-8)))
      (%send p "中文")
      (%send-eof p)
      (%wait p)
      (assert-true (search "中文" (%stdout p))
                   "stdout decoded as utf-8 contains 中文"))))

(deftest process-coding-c1-coding-system-keyword-accepted
  "Just verifying the kwarg is accepted (the very first thing to break)."
  (with-coding-ready
    (assert-no-error
      (let ((p (%make-proc :command '("/usr/bin/true")
                           :coding-system 'utf-8)))
        (%wait p)))))

;;; ─── C2. split decode / encode ──────────────────────────────────────────

(deftest process-coding-c2-decode-coding-only-stdout
  "When only :decode-coding-system is given, stdout is decoded as such."
  (with-coding-ready
    ;; printf "%b" '\xe4\xb8\xad\xe6\x96\x87' produces UTF-8 bytes for 中文.
    (let ((p (%make-proc
              :command '("/bin/sh" "-c"
                         "printf '\\xe4\\xb8\\xad\\xe6\\x96\\x87'")
              :decode-coding-system 'utf-8)))
      (%wait p)
      (assert-true (search "中文" (%stdout p))
                   "stdout decoded as utf-8"))))

(deftest process-coding-c2-encode-coding-only-stdin
  "Only :encode-coding-system → stdout left as default decode (utf-8 default)."
  (with-coding-ready
    (let ((p (%make-proc :command '("/bin/cat")
                         :encode-coding-system 'utf-8)))
      (%send p "中文")
      (%send-eof p)
      (%wait p)
      ;; default *default-process-coding-system* read side is utf-8.
      (assert-true (search "中文" (%stdout p))))))

;;; ─── C3. *default-process-coding-system* ───────────────────────────────

(deftest process-coding-c3-default-var-exists
  (with-coding-ready
    (let ((sym (find-symbol "*DEFAULT-PROCESS-CODING-SYSTEM*"
                            '#:limn/process)))
      (assert-true sym "var exported")
      (assert-true (boundp sym) "var has a value"))))

(deftest process-coding-c3-default-is-utf8-pair
  (with-coding-ready
    (let* ((sym (find-symbol "*DEFAULT-PROCESS-CODING-SYSTEM*"
                             '#:limn/process))
           (v (symbol-value sym)))
      (assert-true (consp v) "default is a cons (read . write)")
      ;; Implementation might use keyword or coding-system object; we
      ;; just check that both sides exist and are non-nil.
      (assert-true (car v) "read side non-nil")
      (assert-true (cdr v) "write side non-nil"))))

(deftest process-coding-c3-default-applies-when-no-kwarg
  "When neither :coding-system nor :decode-coding-system is given, the
   default applies (= utf-8 read, utf-8 write)."
  (with-coding-ready
    (let ((p (%make-proc :command '("/bin/sh" "-c"
                                    "printf '\\xe4\\xb8\\xad\\xe6\\x96\\x87'"))))
      (%wait p)
      (assert-true (search "中文" (%stdout p))))))

(deftest process-coding-c3-rebound-default-honoured
  "Rebinding *default-process-coding-system* changes new processes' default."
  (with-coding-ready
    (let* ((sym (find-symbol "*DEFAULT-PROCESS-CODING-SYSTEM*"
                             '#:limn/process)))
      ;; Bind read side to latin-1; bytes E4 B8 AD then decode as latin-1
      ;; → 3 latin-1 chars, NOT 中.
      (progv (list sym) (list (cons 'latin-1 'latin-1))
        (let ((p (%make-proc
                  :command '("/bin/sh" "-c" "printf '\\xe4\\xb8'"))))
          (%wait p)
          (assert-false (search "中" (%stdout p))
                        "latin-1 decode does NOT yield 中"))))))

;;; ─── C4. buffer-local coding override ──────────────────────────────────

(deftest process-coding-c4-buffer-coding-var-exists
  (with-coding-ready
    (let ((sym (find-symbol "*BUFFER-PROCESS-CODING-SYSTEM*"
                            '#:limn/process)))
      (assert-true sym "var exported"))))

;;; ─── C5. decode failure → safe fallback ────────────────────────────────

(deftest process-coding-c5-undecodable-bytes-do-not-kill-reader
  "If raw stdout bytes are invalid for the chosen decoder, the read thread
   must not die silently (process still reaches :exit)."
  (with-coding-ready
    (let ((p (%make-proc
              :command '("/bin/sh" "-c" "printf '\\xff\\xfe\\xfd'")
              :decode-coding-system 'utf-8)))
      (%wait p)
      (assert-eq :exit
                 (funcall (symbol-function
                           (find-symbol "PROCESS-STATUS" '#:limn/process))
                          p)
                 "process still transitions to :exit"))))

;;; ─── C6. encode-system error path ──────────────────────────────────────

(deftest process-coding-c6-encode-failure-signals
  "Encoding a CJK string into us-ascii must error (or otherwise be
   detectable — defer to the impl, but it must not silently corrupt)."
  (with-coding-ready
    (let* ((p (%make-proc :command '("/bin/cat")
                          :encode-coding-system 'us-ascii)))
      (handler-case
          (progn (%send p "中文")
                 (%send-eof p)
                 (%wait p)
                 ;; Either send signalled, or stdout doesn't contain 中文
                 ;; (because the bytes weren't valid encoding of it).
                 (assert-false (search "中文" (%stdout p))
                               "no CJK round-trip through us-ascii"))
        (error () (check t "encode failure signalled cleanly"))))))

;;; ─── C7. backward compat — old call still works ────────────────────────

(deftest process-coding-c7-no-coding-kwarg-behaves-like-v023
  "make-process without any coding kwarg behaves exactly as before
   (default = utf-8 . utf-8): ASCII passes through unchanged."
  (with-coding-ready
    (let ((p (%make-proc :command '("/bin/echo" "hello"))))
      (%wait p)
      (assert-true (search "hello" (%stdout p))))))

;;; ─── C8. extra extrapolation ────────────────────────────────────────────

(deftest process-coding-c8-conflict-coding-and-decode-honours-explicit
  "If user passes both :coding-system AND :decode-coding-system, the
   more-specific :decode-coding-system wins for the read side."
  (with-coding-ready
    (let ((p (%make-proc
              :command '("/bin/sh" "-c" "printf '\\xe4\\xb8\\xad'")
              :coding-system 'us-ascii
              :decode-coding-system 'utf-8)))
      (%wait p)
      (assert-true (search "中" (%stdout p))
                   "decode-coding-system wins"))))

(deftest process-coding-c8-raw-text-coding-passes-bytes-through
  "Coding system 'raw-text (or :no-conversion / 'binary, per impl) should
   pass bytes through with no decoding."
  (with-coding-ready
    (let* ((cs-sym (or (find-symbol "FIND-CODING-SYSTEM" '#:limn/coding)))
           (has-raw (and cs-sym
                         (or (funcall cs-sym 'raw-text)
                             (funcall cs-sym 'binary)
                             (funcall cs-sym 'no-conversion)))))
      (if (not has-raw)
          (format t "  (skipped: no raw passthrough coding)~%")
          (let ((p (%make-proc
                    :command '("/bin/echo" "ascii-data")
                    :coding-system (cond ((funcall cs-sym 'raw-text) 'raw-text)
                                          ((funcall cs-sym 'binary)  'binary)
                                          (t 'no-conversion)))))
            (%wait p)
            (assert-true (search "ascii-data" (%stdout p))))))))

(deftest process-coding-c8-process-accessor-returns-coding
  "After spawn, process-decode-coding / process-encode-coding should
   return the actual coding system in use (for introspection)."
  (with-coding-ready
    (let ((p (%make-proc :command '("/usr/bin/true")
                         :coding-system 'utf-8)))
      (%wait p)
      (let* ((dec-fn (find-symbol "PROCESS-DECODE-CODING" '#:limn/process))
             (enc-fn (find-symbol "PROCESS-ENCODE-CODING" '#:limn/process)))
        (assert-true dec-fn "accessor exported")
        (assert-true (funcall dec-fn p))
        (assert-true (funcall enc-fn p))))))
