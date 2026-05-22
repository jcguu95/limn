;;;; limn-bridge — JSON encoder/decoder + request/response/event helpers.
;;;;
;;;; The pure-logic part of the Backend↔Frontend protocol. No socket I/O
;;;; lives here — that's plumbing in run-tests.sh or the real Lisp client.

(defpackage #:limn/bridge
  (:use #:cl)
  (:export #:encode-message #:decode-message
           #:make-request #:match-response
           #:response-ok? #:response-error #:response-data
           #:event-type))

(in-package #:limn/bridge)

;;; ── encoder ─────────────────────────────────────────────────────────────

(defun encode-message (v)
  (with-output-to-string (out) (encode-value v out)))

(defun encode-value (v out)
  (cond
    ((null v)              (write-string "null" out))
    ((eq v t)              (write-string "true" out))
    ((eq v :false)         (write-string "false" out))
    ((eq v :null)          (write-string "null" out))
    ((integerp v)          (format out "~d" v))
    ((floatp v)            (format out "~,6f" v))
    ((stringp v)           (encode-string v out))
    ((symbolp v)           (encode-string (string-downcase (symbol-name v)) out))
    ((listp v)             (if (plist-p v)
                               (encode-object v out)
                               (encode-array v out)))
    (t (error "Cannot encode JSON value: ~s" v))))

(defun plist-p (lst)
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
           (encode-string (string-downcase (symbol-name k)) out)
           (write-char #\: out)
           (encode-value v out))
  (write-char #\} out))

(defun encode-array (items out)
  (write-char #\[ out)
  (loop for x in items for first = t then nil
        do (unless first (write-char #\, out))
           (encode-value x out))
  (write-char #\] out))

;;; ── decoder ────────────────────────────────────────────────────────────

(defun decode-message (str)
  (when (or (null str) (zerop (length str)))
    (error "decode-message: empty input"))
  (let ((pos (skip-ws str 0)))
    (when (>= pos (length str))
      (error "decode-message: only whitespace"))
    (multiple-value-bind (v _) (read-json str pos)
      (declare (ignore _))
      v)))

(defun skip-ws (s i)
  (loop while (and (< i (length s))
                   (member (char s i) '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun read-json (s i)
  (setf i (skip-ws s i))
  (when (>= i (length s)) (error "Unexpected EOF in JSON"))
  (let ((c (char s i)))
    (cond
      ((char= c #\{) (read-object s i))
      ((char= c #\[) (read-array s i))
      ((char= c #\") (read-string-token s i))
      ((or (char= c #\-) (digit-char-p c)) (read-number s i))
      ((and (char= c #\t) (>= (length s) (+ i 4))
            (string= (subseq s i (+ i 4)) "true"))
       (values t (+ i 4)))
      ((and (char= c #\f) (>= (length s) (+ i 5))
            (string= (subseq s i (+ i 5)) "false"))
       (values :false (+ i 5)))
      ((and (char= c #\n) (>= (length s) (+ i 4))
            (string= (subseq s i (+ i 4)) "null"))
       (values :null (+ i 4)))
      (t (error "Unexpected JSON character: ~c at ~d" c i)))))

(defun read-object (s i)
  (incf i)
  (setf i (skip-ws s i))
  (let ((acc '()))
    (when (and (< i (length s)) (char= (char s i) #\}))
      (return-from read-object (values nil (1+ i))))
    (loop
      (setf i (skip-ws s i))
      (multiple-value-bind (key i1) (read-string-token s i)
        (setf i (skip-ws s i1))
        (unless (and (< i (length s)) (char= (char s i) #\:))
          (error "Expected : in object"))
        (incf i)
        (multiple-value-bind (val i2) (read-json s i)
          (push (intern key :keyword) acc)
          (push val acc)
          (setf i (skip-ws s i2))))
      (cond
        ((and (< i (length s)) (char= (char s i) #\,)) (incf i))
        ((and (< i (length s)) (char= (char s i) #\}))
         (incf i)
         (return-from read-object (values (nreverse acc) i)))
        (t (error "Expected , or } in object — got '~a' at ~d in ~s"
                  (if (< i (length s)) (char s i) #\?) i s))))))

(defun read-array (s i)
  (incf i)
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
        ((and (< i (length s)) (char= (char s i) #\,)) (incf i))
        ((and (< i (length s)) (char= (char s i) #\]))
         (incf i)
         (return-from read-array (values (nreverse acc) i)))
        (t (error "Expected , or ] in array"))))))

(defun read-string-token (s i)
  (assert (char= (char s i) #\"))
  (incf i)
  (let ((out (make-string-output-stream)))
    (loop while (< i (length s)) do
      (let ((c (char s i)))
        (cond
          ((char= c #\")
           (return-from read-string-token
             (values (get-output-stream-string out) (1+ i))))
          ((char= c #\\)
           (incf i)
           (when (>= i (length s)) (error "Bad escape at EOF"))
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
             (incf i)))))
    (error "Unterminated string")))

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

;;; ── request/response helpers ───────────────────────────────────────────

(defvar *request-counter* 0)

(defun make-request (cmd &rest args)
  (let ((id (format nil "r~d" (incf *request-counter*))))
    (list* :|id| id :|cmd| cmd args)))

(defun match-response (request response)
  (let ((req-id  (getf request :|id|))
        (resp-id (getf response :|id|)))
    (and req-id resp-id (string= req-id resp-id))))

(defun response-ok? (resp)
  (eq t (getf resp :|ok|)))

(defun response-data (resp)
  (getf resp :|data|))

(defun response-error (resp)
  (getf resp :|error|))

(defun event-type (ev)
  (getf ev :|event|))
