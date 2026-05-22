;;;; limn-client — Unix-socket I/O to a running Limn frontend.
;;;;
;;;; This is the "live" transport (NOT the test framework). Pure plumbing:
;;;;   - connect / disconnect
;;;;   - write-line  (sends one JSON-encoded request per line)
;;;;   - try-read-line (non-blocking; returns NIL if no full line waiting)
;;;;   - read-line-blocking (blocks until a line or stream EOF)
;;;;
;;;; No JSON, no request/response correlation — that lives in limn-dispatch.
;;;; By exposing only line-based I/O we keep this trivially mockable: tests
;;;; can drive the dispatch layer with a fake client that just shuffles strings.

(require 'sb-bsd-sockets)

(defpackage #:limn/client
  (:use #:cl #:sb-bsd-sockets)
  (:export #:client #:client-p
           #:connect #:disconnect #:connected-p
           #:write-line! #:try-read-line #:read-line-blocking
           #:client-stream))

(in-package #:limn/client)

(defstruct (client (:conc-name client-) (:copier nil))
  socket
  stream
  path)

(defun connect (path &key (retry 30) (delay 0.2))
  "Open a Unix socket connection to PATH. Retries up to RETRY times if the
   socket isn't there yet (frontend may still be starting). Returns a CLIENT."
  (let ((sock nil))
    (loop repeat retry do
      (handler-case
          (progn
            (setf sock (make-instance 'local-socket :type :stream))
            (socket-connect sock path)
            (return))
        (error ()
          (ignore-errors (socket-close sock))
          (setf sock nil)
          (sleep delay))))
    (unless sock
      (error "limn/client: could not connect to ~a after ~a attempts" path retry))
    (let ((stream (socket-make-stream sock
                                      :element-type 'character
                                      :input t :output t
                                      :buffering :line
                                      :external-format :utf-8)))
      (make-client :socket sock :stream stream :path path))))

(defun connected-p (c)
  (and c (client-socket c) (client-stream c) t))

(defun disconnect (c)
  (when c
    (ignore-errors (close (client-stream c)))
    (ignore-errors (socket-close (client-socket c)))
    (setf (client-socket c) nil
          (client-stream c) nil))
  t)

(defun write-line! (c line)
  "Send LINE (no trailing newline needed) over the socket."
  (let ((s (client-stream c)))
    (write-line line s)
    (force-output s)
    t))

(defun try-read-line (c)
  "Non-blocking: return the next complete line, or NIL if none ready.
   Returns :eof if the peer closed."
  (let ((s (client-stream c)))
    (cond
      ((not (listen s)) nil)
      (t (let ((line (read-line s nil :eof)))
           (if (eq line :eof) :eof line))))))

(defun read-line-blocking (c)
  "Block until a line arrives. Returns :eof on close."
  (let ((line (read-line (client-stream c) nil :eof)))
    (if (eq line :eof) :eof line)))
