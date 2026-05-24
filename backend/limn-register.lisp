;;;; limn-register — Emacs-style registers (v0.24 §C).
;;;;
;;;; A register is a (key . value) entry where value's car distinguishes
;;;; type: 'string, 'position (buf-id . offset cons), 'window-config, etc.
;;;; *register-alist* is the single global store, indexed by key
;;;; (typically a character or symbol).

(defpackage #:limn/register
  (:use #:cl)
  (:export #:*register-alist*
           #:set-register #:get-register
           #:point-to-register #:jump-to-register
           #:copy-to-register #:insert-register
           #:window-configuration-to-register
           #:register-read-with-preview
           #:list-registers
           #:*buffer-cursor-fn* #:*buffer-set-cursor-fn*
           #:*buffer-text-fn*   #:*buffer-insert-fn*))

(in-package #:limn/register)

(defvar *register-alist* '())

(defvar *buffer-cursor-fn*     (lambda (bid) (declare (ignore bid)) 0))
(defvar *buffer-set-cursor-fn* (lambda (bid off) (declare (ignore bid off))))
(defvar *buffer-text-fn*       (lambda (bid from to) (declare (ignore bid from to)) ""))
(defvar *buffer-insert-fn*     (lambda (bid off str) (declare (ignore bid off str))))

(defun set-register (key value)
  "Store VALUE under KEY in *register-alist*, replacing any existing entry."
  (let ((cell (assoc key *register-alist* :test #'equal)))
    (if cell
        (setf (cdr cell) value)
        (push (cons key value) *register-alist*)))
  value)

(defun get-register (key)
  "Return the value stored under KEY, or nil if none."
  (cdr (assoc key *register-alist* :test #'equal)))

(defun list-registers ()
  "Return a copy of the register alist."
  (copy-alist *register-alist*))

(defun point-to-register (key buf-id)
  "Store the current cursor of BUF-ID under KEY as a position value
   of the form (position buf-id . offset)."
  (let ((pos (funcall *buffer-cursor-fn* buf-id)))
    (set-register key (cons 'position (cons buf-id pos)))))

(defun jump-to-register (key)
  "Move cursor to the position stored under KEY. Errors if KEY is
   unset. For 'window-config values this is currently a no-op stub."
  (let ((val (get-register key)))
    (unless val
      (error "limn/register: register ~s is empty" key))
    (case (car val)
      (position
       (let ((bid (cadr val))
             (off (cddr val)))
         (funcall *buffer-set-cursor-fn* bid off)))
      (window-config
       nil)
      (t
       nil))))

(defun copy-to-register (key from to buf-id)
  "Copy buffer text [FROM, TO) into register KEY as a 'string value."
  (let ((text (if (= from to) ""
                  (funcall *buffer-text-fn* buf-id from to))))
    (set-register key (cons 'string text))))

(defun insert-register (key buf-id)
  "Insert the string register KEY at point in BUF-ID. Errors if KEY
   is unset."
  (let ((val (get-register key)))
    (unless val
      (error "limn/register: register ~s is empty" key))
    (case (car val)
      (string
       (let ((pos (funcall *buffer-cursor-fn* buf-id)))
         (funcall *buffer-insert-fn* buf-id pos (cdr val))))
      (t
       (error "limn/register: register ~s is not insertable (type ~s)"
              key (car val))))))

(defun window-configuration-to-register (key)
  "Store an opaque snapshot of current window layout under KEY. v0.24
   stores only the type tag; v0.25 will provide a real restore path."
  (set-register key (cons 'window-config nil)))

(defun register-read-with-preview (prompt)
  "Read a register key from the minibuffer with preview. v0.24 stub:
   bypasses the minibuffer and returns nil. Real wiring lands when
   limn/cmd's minibuffer protocol is extended."
  (declare (ignore prompt))
  nil)
