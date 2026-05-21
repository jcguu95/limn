;;;; Limn Test Framework
;;;;
;;;; A self-contained test framework for Limn's bridge protocol.
;;;; Tests assume a Limn process is running with --headless --socket <path>.
;;;;
;;;; Design goals:
;;;;   - No external dependencies (pure SBCL + sb-bsd-sockets)
;;;;   - Robust JSON encoder/decoder (handles nested objects/arrays)
;;;;   - Request/response matching via id
;;;;   - Separate event queue (events arrive interleaved with responses)
;;;;   - Setup/teardown hooks per test
;;;;   - Rich assertions with informative failure messages
;;;;
;;;; Usage:
;;;;   (load "framework.lisp")
;;;;   (in-package #:limn/test)
;;;;   (deftest my-test ...)
;;;;   (run-suite)

(require 'sb-bsd-sockets)

(defpackage #:limn/test
  (:use #:cl #:sb-bsd-sockets)
  (:export
   ;; configuration
   #:*socket-path* #:*fixture-pdf* #:*verbose*
   ;; connection
   #:connect! #:disconnect! #:connected?
   ;; messaging
   #:send! #:send-raw! #:next-id
   #:read-response #:read-event #:drain-events
   ;; assertions
   #:assert-ok #:assert-fail
   #:assert-equal #:assert-true #:assert-false
   #:assert-has-key #:assert-type #:assert-numeric
   #:assert-list-of #:assert-contains
   #:check-assertion
   ;; test definition / running
   #:deftest #:run-test #:run-all #:run-suite
   #:reset-counters #:print-summary
   #:*pass* #:*fail* #:*errors*
   ;; helpers
   #:with-buffer #:with-fresh-window
   #:json-get #:json-get* #:json-array
   #:setup-hook #:teardown-hook))

(in-package #:limn/test)

;;; ─────────────────────────────────────────────────────────────────────────
;;; Configuration
;;; ─────────────────────────────────────────────────────────────────────────

(defvar *socket-path* "/tmp/limn-test"
  "Unix socket path the test Limn instance listens on.")

(defvar *fixture-pdf*
  (namestring (merge-pathnames
               "fixtures/test.pdf"
               (or *load-pathname* *default-pathname-defaults*)))
  "Path to test PDF fixture (must be placed by the user).")

(defvar *verbose* nil
  "When true, log every wire message.")

;;; ─────────────────────────────────────────────────────────────────────────
;;; JSON encoder
;;; ─────────────────────────────────────────────────────────────────────────
;;;
;;; In-memory representation:
;;;   object → plist with keyword keys (downcased symbol name = JSON key)
;;;            e.g. (:cmd "view/set" :win-id "w1" :page 5)
;;;   array  → list   (use json-array to disambiguate from plist if empty)
;;;   bool   → t / :false
;;;   null   → :null
;;;   string, number → as-is
;;;
;;; A tag :|array| can be used in code: (:|array| 1 2 3) but we mostly use plain
;;; lists for arrays since unambiguous in our use.

(defstruct json-array items)        ; explicit array wrapper for empty/disambig

(defun ja (&rest items) (make-json-array :items items))

(defun encode-json (v)
  "Encode a Lisp value as a JSON string."
  (with-output-to-string (out) (encode-value v out)))

(defun encode-value (v out)
  (cond
    ((null v)              (write-string "null" out))
    ((eq v t)              (write-string "true" out))
    ((eq v :false)         (write-string "false" out))
    ((eq v :null)          (write-string "null" out))
    ((integerp v)          (format out "~d" v))
    ((floatp v)            (format out "~,6f" v))
    ((rationalp v)         (format out "~,6f" (coerce v 'float)))
    ((stringp v)           (encode-string v out))
    ((symbolp v)           (encode-string (string-downcase (symbol-name v)) out))
    ((json-array-p v)      (encode-array (json-array-items v) out))
    ((listp v)             (if (plist-p v)
                               (encode-object v out)
                               (encode-array v out)))
    (t (error "Cannot encode JSON value: ~s" v))))

(defun plist-p (lst)
  "True if LST looks like a plist (even length, keyword keys)."
  (and (listp lst)
       (evenp (length lst))
       (every #'keywordp (loop for k in lst by #'cddr collect k))))

(defun encode-string (s out)
  (write-char #\" out)
  (loop for c across s do
    (case c
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return  (write-string "\\r" out))
      (#\Tab     (write-string "\\t" out))
      (t (if (< (char-code c) 32)
             (format out "\\u~4,'0x" (char-code c))
             (write-char c out)))))
  (write-char #\" out))

(defun encode-object (plist out)
  (write-char #\{ out)
  (loop for (k v) on plist by #'cddr
        for first = t then nil
        do (unless first (write-char #\, out))
           (encode-string (json-key-string k) out)
           (write-char #\: out)
           (encode-value v out))
  (write-char #\} out))

(defun encode-array (items out)
  (write-char #\[ out)
  (loop for x in items for first = t then nil
        do (unless first (write-char #\, out))
           (encode-value x out))
  (write-char #\] out))

(defun json-key-string (k)
  "Map a keyword to its JSON key. Keywords with explicit names (e.g. :|win-id|)
   are passed through; otherwise downcase + dashes."
  (string-downcase (symbol-name k)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; JSON decoder (recursive descent)
;;; ─────────────────────────────────────────────────────────────────────────

(defun decode-json (str)
  "Parse a JSON string. Returns a Lisp value (plist for objects, list for arrays)."
  (let ((pos 0))
    (multiple-value-bind (v p) (read-json str pos)
      (declare (ignore p))
      v)))

(defun read-json (s i)
  (setf i (skip-ws s i))
  (when (>= i (length s)) (error "Unexpected EOF in JSON"))
  (let ((c (char s i)))
    (cond
      ((char= c #\{) (read-object s i))
      ((char= c #\[) (read-array s i))
      ((char= c #\") (read-string-token s i))
      ((or (char= c #\-) (digit-char-p c)) (read-number s i))
      ((and (char= c #\t)
            (>= (length s) (+ i 4))
            (string= (subseq s i (+ i 4)) "true"))
       (values t (+ i 4)))
      ((and (char= c #\f)
            (>= (length s) (+ i 5))
            (string= (subseq s i (+ i 5)) "false"))
       (values :false (+ i 5)))
      ((and (char= c #\n)
            (>= (length s) (+ i 4))
            (string= (subseq s i (+ i 4)) "null"))
       (values :null (+ i 4)))
      (t (error "Unexpected JSON character: ~c at ~d" c i)))))

(defun skip-ws (s i)
  (loop while (and (< i (length s))
                   (member (char s i) '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun read-object (s i)
  (incf i)                              ; consume {
  (setf i (skip-ws s i))
  (let ((acc '()))
    (when (and (< i (length s)) (char= (char s i) #\}))
      (return-from read-object (values nil (1+ i))))
    (loop
      (setf i (skip-ws s i))
      (multiple-value-bind (key i1) (read-string-token s i)
        (setf i (skip-ws s i1))
        (unless (and (< i (length s)) (char= (char s i) #\:))
          (error "Expected : after key in object at ~d" i))
        (incf i)
        (setf i (skip-ws s i))
        (multiple-value-bind (val i2) (read-json s i)
          (push (intern key :keyword) acc)
          (push val acc)
          (setf i (skip-ws s i2))))
      (cond
        ((and (< i (length s)) (char= (char s i) #\,))
         (incf i))
        ((and (< i (length s)) (char= (char s i) #\}))
         (incf i)
         (return-from read-object (values (nreverse acc) i)))
        (t (error "Expected , or } in object at ~d" i))))))

(defun read-array (s i)
  (incf i)                              ; consume [
  (setf i (skip-ws s i))
  (let ((acc '()))
    (when (and (< i (length s)) (char= (char s i) #\]))
      (return-from read-array (values nil (1+ i))))
    (loop
      (setf i (skip-ws s i))
      (multiple-value-bind (val i1) (read-json s i)
        (push val acc)
        (setf i (skip-ws s i1)))
      (cond
        ((and (< i (length s)) (char= (char s i) #\,))
         (incf i))
        ((and (< i (length s)) (char= (char s i) #\]))
         (incf i)
         (return-from read-array (values (nreverse acc) i)))
        (t (error "Expected , or ] in array at ~d" i))))))

(defun read-string-token (s i)
  (assert (char= (char s i) #\"))
  (incf i)
  (with-output-to-string (out)
    (loop while (< i (length s)) do
      (let ((c (char s i)))
        (cond
          ((char= c #\") (return-from read-string-token (values (get-output-stream-string out) (1+ i))))
          ((char= c #\\)
           (incf i)
           (let ((e (char s i)))
             (case e
               (#\" (write-char #\" out))
               (#\\ (write-char #\\ out))
               (#\/ (write-char #\/ out))
               (#\n (write-char #\Newline out))
               (#\r (write-char #\Return out))
               (#\t (write-char #\Tab out))
               (#\b (write-char #\Backspace out))
               (#\f (write-char #\Page out))
               (#\u
                (let ((cp (parse-integer s :start (+ i 1) :end (+ i 5) :radix 16)))
                  (write-char (code-char cp) out)
                  (incf i 4)))
               (t (write-char e out))))
           (incf i))
          (t (write-char c out)
             (incf i)))))))

(defun read-number (s i)
  (let ((start i))
    (when (char= (char s i) #\-) (incf i))
    (loop while (and (< i (length s)) (digit-char-p (char s i))) do (incf i))
    (let ((float? nil))
      (when (and (< i (length s)) (char= (char s i) #\.))
        (setf float? t) (incf i)
        (loop while (and (< i (length s)) (digit-char-p (char s i))) do (incf i)))
      (when (and (< i (length s)) (member (char s i) '(#\e #\E)))
        (setf float? t) (incf i)
        (when (member (char s i) '(#\+ #\-)) (incf i))
        (loop while (and (< i (length s)) (digit-char-p (char s i))) do (incf i)))
      (let ((token (subseq s start i)))
        (values (if float?
                    (let ((*read-default-float-format* 'double-float))
                      (read-from-string token))
                    (parse-integer token))
                i)))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Helpers for navigating decoded JSON
;;; ─────────────────────────────────────────────────────────────────────────

(defun json-get (obj key)
  "Get a value from a decoded JSON object (plist)."
  (getf obj key))

(defun json-get* (obj &rest keys)
  "Walk through nested objects: (json-get* r :|data| :|buffer-id|)."
  (reduce (lambda (acc k) (when acc (getf acc k))) keys :initial-value obj))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Connection
;;; ─────────────────────────────────────────────────────────────────────────

(defvar *socket*         nil)
(defvar *stream*         nil)
(defvar *counter*        0)
(defvar *event-queue*    '())   ; events arriving while we wait for responses
(defvar *response-queue* '())   ; responses for ids we haven't waited on yet

(defun connected? ()
  (and *socket* *stream*))

(defun connect! (&key (path *socket-path*) (retry 30) (delay 0.2))
  "Connect to Limn socket. Retries while waiting for Limn to start."
  (when *socket* (disconnect!))
  (let ((sock nil))
    (loop repeat retry do
      (handler-case
          (progn
            (setf sock (make-instance 'local-socket :type :stream))
            (socket-connect sock path)
            (return))
        (error (e)
          (declare (ignore e))
          (ignore-errors (socket-close sock))
          (setf sock nil)
          (sleep delay))))
    (unless sock
      (error "Could not connect to Limn socket at ~a after ~a attempts" path retry))
    (setf *socket* sock
          *stream* (socket-make-stream sock
                                       :element-type 'character
                                       :input t :output t
                                       :buffering :line
                                       :external-format :utf-8))
    (setf *event-queue* '() *response-queue* '())
    (format t "[framework] connected: ~a~%" path)
    t))

(defun disconnect! ()
  (when *socket*
    (ignore-errors (close *stream*))
    (ignore-errors (socket-close *socket*))
    (setf *socket* nil *stream* nil))
  t)

;;; ─────────────────────────────────────────────────────────────────────────
;;; Sending & receiving
;;; ─────────────────────────────────────────────────────────────────────────

(defun next-id ()
  (format nil "t~d" (incf *counter*)))

(defun send-raw! (plist &key id)
  "Send a JSON request, return the id. If plist has no :|id|, a fresh one is added."
  (let* ((id   (or id (getf plist :|id|) (next-id)))
         (plist (if (getf plist :|id|) plist (list* :|id| id plist)))
         (line (encode-json plist)))
    (when *verbose* (format t "[→] ~a~%" line))
    (write-line line *stream*)
    (force-output *stream*)
    id))

(defun send! (cmd &rest args)
  "Send command, wait for matching response. Returns decoded plist."
  (let ((id (send-raw! (list* :|cmd| cmd args))))
    (read-response id)))

(defun read-response (id &key (timeout 10))
  "Read messages until we get a response with the given id.
   Spontaneous events get queued in *event-queue*. Responses for OTHER
   ids get queued in *response-queue* (read-response will find them later)."
  ;; First: check if we already have this response queued.
  (let ((cached (find id *response-queue*
                      :key (lambda (r) (getf r :|id|))
                      :test #'equal)))
    (when cached
      (setf *response-queue* (remove cached *response-queue*))
      (return-from read-response cached)))
  ;; Otherwise: read from socket until we find it or time out.
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline)
        (error "Timeout (~a s) waiting for response to ~s" timeout id))
      (let ((line (read-line *stream* nil nil)))
        (unless line
          (error "Connection closed while waiting for response to ~s" id))
        (when *verbose* (format t "[←] ~a~%" line))
        (let ((parsed (handler-case (decode-json line)
                        (error (e)
                          (format t "  [bad JSON] ~a: ~a~%" e line)
                          nil))))
          (when parsed
            (cond
              ((and (getf parsed :|id|)
                    (string= (getf parsed :|id|) id))
               (return parsed))
              ((getf parsed :|event|)
               (push parsed *event-queue*))
              ((getf parsed :|id|)
               ;; response for a different id — queue it for later
               (push parsed *response-queue*))
              (t nil))))))))

(defun read-event (&key (timeout 3) type)
  "Wait for the next event (optionally of a specific type).
   Returns NIL on timeout.
   IMPORTANT: while waiting we may read responses (id-bearing messages)
   destined for read-response — those get queued in *response-queue*,
   not dropped."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    ;; First check queued events (oldest-first: queue is built via push,
    ;; so find-if naturally returns newest; reverse to honor FIFO order).
    (let ((found (find-if (lambda (e) (or (null type) (string= (getf e :|event|) type)))
                          (reverse *event-queue*))))
      (when found
        (setf *event-queue* (remove found *event-queue* :count 1))
        (return-from read-event found)))
    ;; Otherwise read from socket until one arrives or timeout
    (loop
      (when (> (get-internal-real-time) deadline)
        (return-from read-event nil))
      (when (listen *stream*)
        (let ((line (read-line *stream* nil nil)))
          (when line
            (let ((parsed (ignore-errors (decode-json line))))
              (when parsed
                (cond
                  ;; event of desired type → return
                  ((and (getf parsed :|event|)
                        (or (null type) (string= (getf parsed :|event|) type)))
                   (return parsed))
                  ;; event of different type → queue for later
                  ((getf parsed :|event|)
                   (push parsed *event-queue*))
                  ;; response with id → queue for read-response
                  ((getf parsed :|id|)
                   (push parsed *response-queue*))))))))
      (sleep 0.05))))

(defun drain-events ()
  "Return all queued events and clear the queue."
  (prog1 (nreverse *event-queue*) (setf *event-queue* '())))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Assertions
;;; ─────────────────────────────────────────────────────────────────────────

(defvar *pass*   0)
(defvar *fail*   0)
(defvar *errors* '())
(defvar *current-test* nil)

(defun reset-counters ()
  (setf *pass* 0 *fail* 0 *errors* '()))

(defun check-assertion (ok msg &rest detail-args)
  (if ok
      (progn (incf *pass*)
             (format t "  ✓ ~a~%" msg))
      (progn (incf *fail*)
             (push (cons *current-test* msg) *errors*)
             (format t "  ✗ ~a~%" msg)
             (when detail-args
               (format t "      → ~?~%" (car detail-args) (cdr detail-args))))))

(defmacro assert-ok (response &optional msg)
  (let ((r (gensym)))
    `(let ((,r ,response))
       (check-assertion (eq (getf ,r :|ok|) t)
                        (or ,msg "response: ok=true")
                        "got ok=~s, error=~s"
                        (getf ,r :|ok|) (getf ,r :|error|)))))

(defmacro assert-fail (response &optional msg)
  (let ((r (gensym)))
    `(let ((,r ,response))
       (check-assertion (eq (getf ,r :|ok|) :false)
                        (or ,msg "response: ok=false")
                        "expected ok=false, got ok=~s" (getf ,r :|ok|)))))

(defmacro assert-equal (expected actual &optional msg)
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,actual))
       (check-assertion (equal ,e ,a)
                        (or ,msg (format nil "~s == ~s" ',actual ,e))
                        "expected ~s, got ~s" ,e ,a))))

(defmacro assert-true (form &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,form))
       (check-assertion (and ,v (not (eq ,v :false)))
                        (or ,msg (format nil "~s is true" ',form))
                        "value was ~s" ,v))))

(defmacro assert-false (form &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,form))
       (check-assertion (or (null ,v) (eq ,v :false))
                        (or ,msg (format nil "~s is false" ',form))
                        "value was ~s" ,v))))

(defmacro assert-has-key (key obj &optional msg)
  (let ((o (gensym)) (k (gensym)))
    `(let ((,o ,obj) (,k ,key))
       (check-assertion (and (listp ,o) (not (eq :missing (getf ,o ,k :missing))))
                        (or ,msg (format nil "key ~s present in ~s" ',key ',obj))
                        "key ~s missing; have ~s" ,k
                        (loop for (k v) on ,o by #'cddr collect k)))))

(defmacro assert-type (value type &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,value))
       (check-assertion (typep ,v ',type)
                        (or ,msg (format nil "~s : ~s" ',value ',type))
                        "expected type ~s, got ~s (~s)" ',type (type-of ,v) ,v))))

(defmacro assert-numeric (value &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,value))
       (check-assertion (numberp ,v)
                        (or ,msg (format nil "~s is numeric" ',value))
                        "value was ~s (~s)" ,v (type-of ,v)))))

(defmacro assert-list-of (predicate value &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,value))
       (check-assertion (and (listp ,v) (every ,predicate ,v))
                        (or ,msg (format nil "all elements of ~s satisfy ~s" ',value ',predicate))
                        "got ~s" ,v))))

(defmacro assert-contains (item collection &optional msg)
  (let ((i (gensym)) (c (gensym)))
    `(let ((,i ,item) (,c ,collection))
       (check-assertion (find ,i ,c :test #'equal)
                        (or ,msg (format nil "~s contains ~s" ',collection ,i))
                        "~s not found in ~s" ,i ,c))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Setup / teardown / test registration
;;; ─────────────────────────────────────────────────────────────────────────

(defvar *tests*           '())
(defvar *setup-hooks*     '())
(defvar *teardown-hooks*  '())

(defmacro setup-hook (&body body)
  `(push (lambda () ,@body) *setup-hooks*))

(defmacro teardown-hook (&body body)
  `(push (lambda () ,@body) *teardown-hooks*))

(defmacro deftest (name &body body)
  `(progn
     (defun ,name ()
       (let ((*current-test* ',name)
             (test-pass-before *pass*)
             (test-fail-before *fail*))
         (format t "~%┌─ ~a~%" ',name)
         (handler-case (progn ,@body)
           (error (e)
             (incf *fail*)
             (push (cons ',name (format nil "ERROR: ~a" e)) *errors*)
             (format t "  ✗ test threw: ~a~%" e)))
         (let ((p (- *pass* test-pass-before))
               (f (- *fail* test-fail-before)))
           (format t "└─ ~a: ~a passed, ~a failed~%" ',name p f))))
     (pushnew ',name *tests*)))

(defun run-test (name)
  (funcall name))

(defun run-suite (&key (tests (reverse *tests*)) verbose)
  "Run all registered tests in order. Connects/disconnects automatically."
  (let ((*verbose* verbose))
    (reset-counters)
    (connect!)
    (unwind-protect
         (progn
           (dolist (hook (reverse *setup-hooks*))
             (handler-case (funcall hook)
               (error (e) (format t "[setup error] ~a~%" e))))
           (dolist (test tests)
             (run-test test))
           (dolist (hook (reverse *teardown-hooks*))
             (handler-case (funcall hook)
               (error (e) (format t "[teardown error] ~a~%" e)))))
      (disconnect!))
    (print-summary)
    (zerop *fail*)))

(defun run-all () (run-suite))

(defun print-summary ()
  (format t "~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t "  TOTAL: ~a passed, ~a failed  (~a assertions)~%"
          *pass* *fail* (+ *pass* *fail*))
  (when *errors*
    (format t "~%  FAILURES:~%")
    (dolist (e (reverse *errors*))
      (format t "    [~a] ~a~%" (car e) (cdr e))))
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%"))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Convenience helpers for tests
;;; ─────────────────────────────────────────────────────────────────────────

(defmacro with-buffer ((var &key (engine "mupdf") (path '*fixture-pdf*) (win "w1"))
                       &body body)
  "Load a buffer, bind its buffer-id to VAR, run BODY, then close the buffer."
  (let ((r (gensym)))
    `(let* ((,r (send! "bridge/engine-load"
                       :|win-id| ,win :|engine| ,engine :|path| ,path))
            (,var (json-get* ,r :|data| :|buffer-id|)))
       (unwind-protect
            (progn ,@body)
         (when ,var
           (ignore-errors (send! "buffer/close" :|buffer-id| ,var)))))))

(defmacro with-fresh-window ((var) &body body)
  "Allocate a fresh window via split, bind its id to VAR."
  (let ((r (gensym)))
    `(let* ((,r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
            (,var (json-get* ,r :|data| :|win-b|)))
       (unwind-protect
            (progn ,@body)
         (when ,var
           (ignore-errors (send! "bridge/win-close" :|win-id| ,var)))))))
