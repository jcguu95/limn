;;;; Unit tests for limn/runtime — the layer that connects wire buffer-ids
;;;; to Lisp-side mode-buffers, and walks the mode keymap stack on key
;;;; dispatch.
;;;;
;;;; SPEC v0.5 §9.1: each wire buffer-id has a corresponding mode-buffer.
;;;; Key event → win-id → active buffer-id → mode-buffer → minor → major →
;;;; global keymap stack.
;;;;
;;;; This module is pure-Lisp (no I/O). The wire glue in limn.lisp calls
;;;; into it from %dispatch-key and from event/buffer-opened hooks.

(in-package #:limn/unit-test)

;;; ── buffer-id ↔ mode-buffer registry ───────────────────────────────────

(deftest runtime-register-and-find-mode-buffer
  (limn/runtime:reset-all)
  (let ((mb (limn/mode:make-mode-buffer)))
    (limn/runtime:register-mode-buffer "b1" mb)
    (assert-eq mb (limn/runtime:find-mode-buffer "b1")
               "find-mode-buffer returns the registered object")))

(deftest runtime-find-unknown-mode-buffer-returns-nil
  (limn/runtime:reset-all)
  (assert-equal nil (limn/runtime:find-mode-buffer "nope")))

(deftest runtime-unregister-mode-buffer
  (limn/runtime:reset-all)
  (let ((mb (limn/mode:make-mode-buffer)))
    (limn/runtime:register-mode-buffer "b1" mb)
    (limn/runtime:unregister-mode-buffer "b1")
    (assert-equal nil (limn/runtime:find-mode-buffer "b1"))))

;;; ── window → active buffer-id ──────────────────────────────────────────

(deftest runtime-window-active-buffer
  (limn/runtime:reset-all)
  (limn/runtime:set-window-active-buffer "w1" "b7")
  (assert-equal "b7" (limn/runtime:window-active-buffer "w1")))

(deftest runtime-window-with-no-buffer-returns-nil
  (limn/runtime:reset-all)
  (assert-equal nil (limn/runtime:window-active-buffer "w-missing")))

;;; ── engine → default major mode ────────────────────────────────────────

(deftest runtime-engine-default-mode
  (limn/runtime:reset-all)
  (limn/runtime:register-engine-default-mode "mupdf" 'pdf-mode)
  (assert-equal 'pdf-mode
                (limn/runtime:engine-default-mode "mupdf")))

(deftest runtime-engine-default-mode-unknown
  (limn/runtime:reset-all)
  (assert-equal nil (limn/runtime:engine-default-mode "no-such-engine")))

;;; ── dispatch via mode stack ────────────────────────────────────────────
;;;
;;; dispatch-key-via-stack: given (mode-buffer, global-keymap, key-spec)
;;; walk minor → major → global. Returns the matched action (function or
;;; value), or NIL if nothing bound.

(deftest runtime-dispatch-prefers-minor-over-major
  (limn/runtime:reset-all)
  (limn/mode:clear-modes)
  (let* ((global  (limn/keys:make-keymap))
         (pdf-km  (limn/keys:make-keymap))
         (srch-km (limn/keys:make-keymap)))
    (limn/keys:define-key pdf-km  "j" :pdf-j)
    (limn/keys:define-key srch-km "j" :search-j)
    (limn/mode:define-mode 'pdf-mode    :type :major)
    (limn/mode:define-mode 'search-mode :type :minor)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'pdf-mode))    pdf-km)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'search-mode)) srch-km)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'pdf-mode)
      (limn/mode:activate buf 'search-mode)
      (assert-equal :search-j
                    (limn/runtime:dispatch-key-via-stack buf global "j")
                    "minor mode wins over major"))))

(deftest runtime-dispatch-falls-to-major
  (limn/runtime:reset-all)
  (limn/mode:clear-modes)
  (let* ((global (limn/keys:make-keymap))
         (pdf-km (limn/keys:make-keymap)))
    (limn/keys:define-key pdf-km "j" :pdf-j)
    (limn/mode:define-mode 'pdf-mode :type :major)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'pdf-mode)) pdf-km)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'pdf-mode)
      (assert-equal :pdf-j
                    (limn/runtime:dispatch-key-via-stack buf global "j")))))

(deftest runtime-dispatch-falls-to-global
  (limn/runtime:reset-all)
  (limn/mode:clear-modes)
  (let ((global (limn/keys:make-keymap))
        (pdf-km (limn/keys:make-keymap)))
    (limn/keys:define-key global "x" :global-x)
    (limn/mode:define-mode 'pdf-mode :type :major)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'pdf-mode)) pdf-km)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'pdf-mode)
      (assert-equal :global-x
                    (limn/runtime:dispatch-key-via-stack buf global "x")
                    "neither minor nor major has x — global wins"))))

(deftest runtime-dispatch-with-no-mode-buffer-uses-global-only
  (limn/runtime:reset-all)
  (let ((global (limn/keys:make-keymap)))
    (limn/keys:define-key global "q" :quit)
    (assert-equal :quit
                  (limn/runtime:dispatch-key-via-stack nil global "q")
                  "nil mode-buffer falls straight through to global")))

(deftest runtime-dispatch-returns-nil-when-unbound
  (limn/runtime:reset-all)
  (let ((global (limn/keys:make-keymap)))
    (assert-equal nil
                  (limn/runtime:dispatch-key-via-stack nil global "z"))))

;;; ── high-level: dispatch given a win-id ────────────────────────────────
;;;
;;; mode-buffer-for-window: win-id → (or mode-buffer nil). Composes
;;; window-active-buffer + find-mode-buffer.

(deftest runtime-mode-buffer-for-window
  (limn/runtime:reset-all)
  (let ((mb (limn/mode:make-mode-buffer)))
    (limn/runtime:register-mode-buffer "b1" mb)
    (limn/runtime:set-window-active-buffer "w1" "b1")
    (assert-eq mb (limn/runtime:mode-buffer-for-window "w1"))))

(deftest runtime-mode-buffer-for-window-with-no-binding
  (limn/runtime:reset-all)
  (assert-equal nil (limn/runtime:mode-buffer-for-window "w-missing")))

;;; ── chrome buffers bootstrapped on reset/init ──────────────────────────

(deftest runtime-bootstrap-chrome-mode-buffers
  "After init-chrome-buffers, the three chrome buffer-ids each have a
   mode-buffer registered."
  (limn/runtime:reset-all)
  (limn/mode:clear-modes)
  ;; Pre-define the modes init-chrome-buffers will activate so it doesn't
  ;; error on missing modes.
  (limn/mode:define-mode 'limn/runtime:fundamental-mode :type :major)
  (limn/mode:define-mode 'limn/runtime:minibuffer-mode  :type :major)
  (limn/runtime:init-chrome-buffers)
  (assert-true (limn/runtime:find-mode-buffer "*minibuffer*")
               "*minibuffer* registered")
  (assert-true (limn/runtime:find-mode-buffer "*messages*")
               "*messages* registered")
  (assert-true (limn/runtime:find-mode-buffer "*echo-area*")
               "*echo-area* registered")
  (assert-eq 'limn/runtime:minibuffer-mode
             (limn/mode:major-mode
              (limn/runtime:find-mode-buffer "*minibuffer*"))
             "*minibuffer* has minibuffer-mode as major"))
