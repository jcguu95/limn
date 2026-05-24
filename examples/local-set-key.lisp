;;;; examples/local-set-key.lisp — dogfood v0.19 β mode-buffer local-keymap.
;;;;
;;;; Equivalent of Emacs's (local-set-key KEY CMD): per-buffer override
;;;; that beats minor + major mode bindings, scoped to one mode-buffer.
;;;;
;;;; Usage:
;;;;   (load "examples/local-set-key.lisp")
;;;;   (limn.examples.local-set-key:local-set-key buf "C-q"
;;;;     (lambda (_) (kill-buffer)))
;;;;
;;;; Or batch via (with-local-keymap buf ...).
;;;;
;;;; NOTE on multi-key: v0.19 routed local-keymap into lookup-key
;;;; (single key) but not yet into the %dispatch-key multi-key
;;;; sequence walker. Multi-key local bindings like "C-c C-c" are
;;;; stored correctly but won't fire until lookup-sequence also walks
;;;; the local layer (queued for the next layer-walk pass — single-
;;;; key suffices for demonstrating the v0.19 β contract).

(defpackage #:limn.examples.local-set-key
  (:use #:cl)
  (:export #:local-set-key #:local-unset-key #:with-local-keymap))

(in-package #:limn.examples.local-set-key)

(defun %ensure-local-keymap (buf)
  "Return BUF's local-keymap, creating an empty one if needed."
  (or (limn/mode:mode-buffer-local-keymap buf)
      (let ((km (limn/keys:make-keymap)))
        (limn/mode:set-local-keymap buf km)
        km)))

(defun local-set-key (buf key-spec action)
  "Bind ACTION on KEY-SPEC in BUF's local-keymap. Beats minor / major
   for this buffer only. ACTION can be a function or symbol (looked up
   via fboundp at dispatch time, mimicking Emacs's command binding)."
  (limn/keys:define-key (%ensure-local-keymap buf) key-spec action))

(defun local-unset-key (buf key-spec)
  "Remove a local binding. If the local-keymap becomes empty, leave it
   in place (caller can call set-local-keymap nil if they want to fully
   reset back to mode-only lookup)."
  (let ((km (limn/mode:mode-buffer-local-keymap buf)))
    (when km
      (limn/keys:undefine-key km key-spec))))

(defmacro with-local-keymap (buf &body bindings)
  "Convenience: install a batch of bindings on BUF as buffer-local.

   (with-local-keymap *buf*
     (\"C-c C-c\" 'save-close)
     (\"C-c k\"   'kill-buffer))"
  `(progn
     ,@(loop for (k a) in bindings
             collect `(local-set-key ,buf ,k ,a))))

;;; Self-test (single-key only — see file-top note on multi-key).
(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  (let ((buf (limn/mode:make-mode-buffer)))
    (local-set-key buf "C-q" 'my-quit)
    (assert (eq 'my-quit (limn/mode:lookup-key buf "C-q")) () "local binding wins")
    (local-unset-key buf "C-q")
    (assert (null (limn/mode:lookup-key buf "C-q")) () "unset clears")
    (with-local-keymap buf
      ("j" 'jj)
      ("k" 'kk))
    (assert (eq 'jj (limn/mode:lookup-key buf "j")) () "batch j")
    (assert (eq 'kk (limn/mode:lookup-key buf "k")) () "batch k"))
  (format t "local-set-key self-test ok~%"))
