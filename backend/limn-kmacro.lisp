;;;; limn-kmacro — keyboard macro recording / replay (v0.24 §D).
;;;;
;;;; Recording captures keys appended to the dispatch loop while
;;;; *defining-kbd-macro* is non-nil; the dispatch hook calls
;;;; record-key. Replay walks the saved key vector and calls
;;;; *kmacro-replay-fn* on each spec — the runtime layer wires this
;;;; back to the dispatcher; tests inject a mock.
;;;;
;;;; name-last-kbd-macro registers a normal defcommand whose body
;;;; replays a snapshot of *last-kbd-macro*.

(defpackage #:limn/kmacro
  (:use #:cl)
  (:export #:*defining-kbd-macro*
           #:*current-kbd-macro*
           #:*last-kbd-macro*
           #:start-kbd-macro
           #:end-kbd-macro
           #:record-key
           #:call-last-kbd-macro
           #:name-last-kbd-macro
           #:*kmacro-counter*
           #:kmacro-insert-counter
           #:*kmacro-replay-fn*
           #:*insert-at-point-fn*))

(in-package #:limn/kmacro)

(defvar *defining-kbd-macro* nil)

(defun %fresh-vec ()
  (make-array 0 :adjustable t :fill-pointer 0))

(defvar *current-kbd-macro* (%fresh-vec))
(defvar *last-kbd-macro*    (%fresh-vec))

(defvar *kmacro-counter* 0)

(defvar *kmacro-replay-fn*    (lambda (spec) (declare (ignore spec))))
(defvar *insert-at-point-fn* (lambda (text) (declare (ignore text))))

(defun start-kbd-macro ()
  "Begin recording. *defining-kbd-macro* becomes t and any in-progress
   recording is discarded."
  (setf *defining-kbd-macro* t
        *current-kbd-macro*  (%fresh-vec))
  t)

(defun end-kbd-macro ()
  "Stop recording. Copies the recording into *last-kbd-macro*."
  (setf *defining-kbd-macro* nil
        *last-kbd-macro*     (copy-seq *current-kbd-macro*))
  t)

(defun record-key (spec)
  "Append SPEC to the in-progress recording. No-op when not recording."
  (when *defining-kbd-macro*
    (let ((vec *current-kbd-macro*))
      (unless (and (arrayp vec) (array-has-fill-pointer-p vec))
        (setf *current-kbd-macro* (%fresh-vec)
              vec *current-kbd-macro*))
      (vector-push-extend spec vec)))
  spec)

(defun %replay-vector (vec)
  (loop for spec across vec do
    (handler-case (funcall *kmacro-replay-fn* spec)
      (error () nil))))

(defun call-last-kbd-macro (&optional (count 1))
  "Replay *last-kbd-macro* COUNT times. No-op when the macro is empty
   or COUNT is non-positive. While replaying, *defining-kbd-macro* is
   bound to nil so replayed keys aren't re-recorded."
  (when (and (plusp count)
             *last-kbd-macro*
             (> (length *last-kbd-macro*) 0))
    (let ((*defining-kbd-macro* nil))
      (dotimes (_ count)
        (%replay-vector *last-kbd-macro*)))
    (incf *kmacro-counter*))
  nil)

(defun name-last-kbd-macro (name)
  "Register NAME as a no-arg command that replays a snapshot of the
   current *last-kbd-macro*."
  (let ((snapshot (copy-seq *last-kbd-macro*))
        (cmd-pkg  (find-package '#:limn/cmd)))
    (when cmd-pkg
      (let ((reg (find-symbol "REGISTER-COMMAND" cmd-pkg)))
        (when reg
          (funcall reg name nil nil
                   (lambda ()
                     (let ((*last-kbd-macro* snapshot)
                           (*defining-kbd-macro* nil))
                       (call-last-kbd-macro))))))))
  name)

(defun kmacro-insert-counter ()
  "Insert *kmacro-counter* (as a decimal string) at point."
  (funcall *insert-at-point-fn* (princ-to-string *kmacro-counter*)))
