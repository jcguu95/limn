;;;; Unit tests for limn/mode (SPEC §1.1 + §9.1).
;;;;
;;;; This file pins the contract; every test will be RED until the real
;;;; implementation lands in v0.7. They test the Backend-side abstraction:
;;;;
;;;;   - define-mode registers a named bundle of (keymap, hooks,
;;;;     modeline-name) and find-mode retrieves it
;;;;   - each "mode buffer" (a buffer abstraction local to this module —
;;;;     real Limn buffers will adopt this once the bridge is wired)
;;;;     tracks exactly one major mode and an ordered list of minors
;;;;   - keymap lookup walks minors (newest first) → major → global
;;;;   - activation fires :on-enter; replacing the major mode fires
;;;;     :on-exit on the outgoing one
;;;;
;;;; The tests deliberately don't touch how mode "owns" a real frontend
;;;; buffer — that connection happens elsewhere. limn/mode is pure logic
;;;; over its own toy buffer type.

(in-package #:limn/unit-test)

;; A clean fixture per test — limn/mode currently has no clear-modes
;; helper; we add one once define-mode exists.

(deftest test-mode-define-and-find
  (let ((m (limn/mode:define-mode 'pdf-mode :type :major :modeline "PDF")))
    (assert-eq m (limn/mode:find-mode 'pdf-mode))
    (assert-equal :major (limn/mode:mode-type m))
    (assert-equal "PDF"  (limn/mode:mode-modeline-name m))))

(deftest test-mode-unknown-find-returns-nil
  (assert-equal nil (limn/mode:find-mode 'unknown-mode-9999)))

(deftest test-mode-buffer-tracks-major-and-minors
  (limn/mode:define-mode 'pdf-mode    :type :major)
  (limn/mode:define-mode 'search-mode :type :minor)
  (limn/mode:define-mode 'hint-mode   :type :minor)
  (let ((buf (limn/mode:make-mode-buffer)))
    (limn/mode:activate buf 'pdf-mode)
    (limn/mode:activate buf 'search-mode)
    (limn/mode:activate buf 'hint-mode)
    (assert-equal 'pdf-mode (limn/mode:major-mode buf))
    (assert-equal '(hint-mode search-mode)         ; newest first
                  (limn/mode:minor-modes buf))))

(deftest test-mode-deactivate-removes-minor
  (limn/mode:define-mode 'pdf-mode    :type :major)
  (limn/mode:define-mode 'search-mode :type :minor)
  (let ((buf (limn/mode:make-mode-buffer)))
    (limn/mode:activate buf 'pdf-mode)
    (limn/mode:activate buf 'search-mode)
    (limn/mode:deactivate buf 'search-mode)
    (assert-equal '() (limn/mode:minor-modes buf))))

(deftest test-mode-activate-major-replaces-existing
  "Activating a new major mode swaps out the old one."
  (limn/mode:define-mode 'pdf-mode :type :major)
  (limn/mode:define-mode 'presentation-mode :type :major)
  (let ((buf (limn/mode:make-mode-buffer)))
    (limn/mode:activate buf 'pdf-mode)
    (limn/mode:activate buf 'presentation-mode)
    (assert-equal 'presentation-mode (limn/mode:major-mode buf))))

(deftest test-mode-on-enter-and-on-exit-hooks
  "Activating fires :on-enter; replacing major fires the old's :on-exit."
  (let* ((log '())
         (push-log (lambda (msg) (push msg log))))
    (limn/mode:define-mode 'pdf-mode
      :type :major
      :on-enter (lambda () (funcall push-log :enter-pdf))
      :on-exit  (lambda () (funcall push-log :exit-pdf)))
    (limn/mode:define-mode 'presentation-mode
      :type :major
      :on-enter (lambda () (funcall push-log :enter-pres)))
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'pdf-mode)
      (limn/mode:activate buf 'presentation-mode))
    (assert-equal '(:enter-pdf :exit-pdf :enter-pres)
                  (reverse log))))

(deftest test-mode-keymap-lookup-walks-stack
  "lookup-key: minors (newest first) → major → global."
  (let* ((global (limn/keys:make-keymap))
         (pdf    (limn/keys:make-keymap))
         (search (limn/keys:make-keymap)))
    (limn/keys:define-key global "x" :global-x)
    (limn/keys:define-key pdf    "j" :pdf-j)
    (limn/keys:define-key search "j" :search-j)
    (limn/mode:define-mode 'pdf-mode    :type :major)
    (limn/mode:define-mode 'search-mode :type :minor)
    ;; Wire keymaps onto modes (API TBD — tests will inform shape)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'pdf-mode))    pdf)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'search-mode)) search)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'pdf-mode)
      (assert-equal :pdf-j (limn/mode:lookup-key buf "j")
                    "no minor: major handles j")
      (limn/mode:activate buf 'search-mode)
      (assert-equal :search-j (limn/mode:lookup-key buf "j")
                    "minor takes precedence over major")
      ;; x not in any mode → fall to global (when wired)
      ;; assert-equal :global-x (limn/mode:lookup-key buf "x") for now skipped
      )))
