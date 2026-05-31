;;;; Pure-Lisp unit test runner
;;;;
;;;; Runs all tests in backend/tests/unit/ without needing a running Limn.
;;;; Tests target the backend modules (limn-keys, limn-undo, etc.) — most
;;;; will fail until those modules are implemented. That's TDD by design.
;;;;
;;;; Usage:
;;;;   sbcl --script backend/tests/unit/run-unit.lisp

(in-package #:cl-user)

;; limn-runtime uses sb-posix:getenv for init-file lookup; load before
;; importing it. (The integration runner gets this via repl.lisp.)
(require :sb-posix)

(defparameter *unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun rel (p)
  (namestring (merge-pathnames p *unit-dir*)))

;; Framework
(load (rel "unit-framework.lisp"))

;; v0.37 A2: load backend via ASDF system — compile-then-load in
;; topological order, zero forward-ref STYLE-WARNING.  cl-ppcre comes
;; in via the system's :depends-on, no manual (require) needed.
;;
;; sb-bsd-sockets MUST be required before ASDF compiles limn-client
;; (whose defpackage :uses #:sb-bsd-sockets — the use list resolves at
;; compile time, before its own top-level (require ...) has a chance
;; to run under FASL semantics).
;; Muffle nix sbcl-wrapper's CL_SOURCE_REGISTRY contrib-dup warnings.
;; See backend/repl.lisp for full explanation.  Split into two forms
;; so the reader doesn't choke on asdf:* symbols before asdf loads.
(defvar *muffle-asd-dup*
  (lambda (w)
    (let ((msg (princ-to-string w)))
      (when (and (search "found several entries" msg)
                 (search "lib/sbcl" msg))
        (muffle-warning w)))))

(handler-bind ((warning *muffle-asd-dup*))
  (require :asdf)
  (require :sb-bsd-sockets))

(handler-bind ((warning *muffle-asd-dup*))
  (let ((backend-dir (namestring (merge-pathnames "../../" *unit-dir*))))
    (push backend-dir asdf:*central-registry*))
  ;; Force the source-registry scan now so the warnings emit INSIDE
  ;; the muffler — otherwise it's lazy and the first wireup test's
  ;; asdf:find-system call triggers the scan post-muffler.
  (asdf:initialize-source-registry)
  (asdf:load-system :limn))

;; v0.23 shared helpers (with-timeout-bound, fake-clock, mock-buffer).
;; Loaded AFTER the backend (which provides limn/cmd etc.) so the
;; helpers can reference real packages, not stubs.
(load (rel "v023-helpers.lisp"))

;; v0.24 shared helpers (cursor-aware mock-buf24, with-kill-buf, with-mark-buf)
(load (rel "v024-helpers.lisp"))

;; All unit-test files
(dolist (file '("bridge-client.lisp"
                "keymap.lisp"
                "keymap-v019.lisp"
                "text-mode-v022.lisp"
                "undo.lisp"
                "hooks.lisp"
                "buffer-registry.lisp"
                "search.lisp"
                "dispatch.lisp"
                "mode.lisp"
                "defcommand.lisp"
                "runtime.lisp"
                "minibuffer-read.lisp"
                "keyboard-quit.lisp"
                "init-load.lisp"
                "introspect.lisp"
                ;; v0.23 RED tests — expected to fail until impl lands
                "process-v023.lisp"
                "timer-v023.lisp"
                "condition-v023.lisp"
                "buffer-undo-v023.lisp"
                "logging-v023.lisp"
                ;; v0.24 RED tests — expected to fail until impl lands
                "kill-ring-v024.lisp"
                "mark-ring-v024.lisp"
                "registers-v024.lisp"
                "kmacro-v024.lisp"
                "file-io-v024.lisp"
                "auto-save-v024.lisp"
                "backup-v024.lisp"
                "recentf-v024.lisp"
                ;; v0.25 tests (GREEN)
                "defface-v025.lisp"
                "text-props-v025.lisp"
                "history-v025.lisp"
                "help-v025.lisp"
                "advice-v025.lisp"
                "defcustom-v025.lisp"
                "completion-v025.lisp"
                ;; v0.39 fuzzy-selector tests (§5–§6 Vertico + Orderless)
                "fuzzy-selector.lisp"
                ;; v0.26 RED tests — expected to fail until impl lands
                "isearch-v026.lisp"
                "occur-v026.lisp"
                "ibuffer.lisp"
                ;; v0.27 tests
                "pdf-mode-v027.lisp"
                ;; v0.28 tests
                "text-nav-v028.lisp"
                "map-macro-v028.lisp"
                "which-key-v028.lisp"
                ;; v0.29 wiring tests
                "runtime-wireup-v028.lisp"
                ;; v0.37 Phase E keymap discipline regression
                "keymap-discipline-v037.lisp"
                ;; v0.37 Phase B default-config + reload-init regression
                "default-config-v037.lisp"
                ;; v0.37 Phase D pdf-mode vim keymap regression
                "pdf-mode-vim-v037.lisp"
                ;; v0.37 logging hierarchical ns + wire mirror
                "logging-v037.lisp"
                ;; v0.30 tests
                "markers-v030.lisp"
                "buffer-local-v030.lisp"
                ;; v0.31 RED tests
                "syntax-v031.lisp"
                "coding-v031.lisp"
                ;; v0.32 RED tests — expected to fail until impl lands
                "excursion-v032.lisp"
                ;; v0.33 RED tests — overlay data + view/overlays :face + region
                "overlays-v033.lisp"
                ;; v0.33b RED tests — buffer-kind dispatch + codepoint-rects
                "overlays-v033b.lisp"
                ;; v0.34 RED tests — expected to fail until impl lands
                "regex-v034.lisp"
                ;; v0.35 tests (GREEN — file-notify + auto-revert + process-coding)
                "file-notify-v035.lisp"
                "auto-revert-v035.lisp"
                "process-coding-v035.lisp"
                ;; v0.36 tests — indent + query-replace
                "indent-v036.lisp"
                "query-replace-v036.lisp"
                ;; v0.38 tests
                "key-spec-v038.lisp"
                ;; v0.37 bookmark-everywhere
                "bookmark-v037.lisp"
                "bookmark-cmds-v037.lisp"
                "bookmark-handlers-v037.lisp"
                ;; narrow/widen §1.1 — text-nav narrow-aware (depends on
                ;; with-excursion-ctx from excursion-v032.lisp)
                "text-nav-narrow.lisp"
                ;; narrow/widen §1.2 — mark narrow-aware
                "mark-narrow.lisp"
                ;; narrow/widen §1.3 — isearch narrow-aware
                "isearch-narrow.lisp"
                ;; narrow/widen §1.4 — regex narrow-aware
                "regex-narrow.lisp"
                ;; narrow/widen §1.5 — kill narrow-aware
                "kill-narrow.lisp"
                ;; narrow/widen §1.6 — occur narrow-aware
                "occur-narrow.lisp"
                ;; narrow/widen §2.1 — narrow-to-region / widen commands + keymap
                "narrow-cmd.lisp"
                ;; narrow/widen §2.2 — modeline narrow indicator
                "narrow-modeline.lisp"
                ;; narrow/widen §2.3 — dim overlay for inaccessible region
                "narrow-dim.lisp"
                ;; narrow/widen §2.4 — narrow-to-defun via reader
                "narrow-defun.lisp"
                ;; narrow/widen §2.5 — text-mode modeline formatter
                "narrow-text-modeline.lisp"
                ;; limn-client §1–§3 — eval-server socket eval
                "eval-server.lisp"
                ;; orderless 比對引擎 — P1 Fuzzy Selector 的比對核心
                "orderless.lisp"
                ;; vertico 補全 UI 狀態機 — P2 Vertico 後端
                "vertico.lisp"
                ;; minad P4: Corfu (in-buffer popup) + Cape (backends) + Embark (actions)
                "corfu.lisp"
                "cape.lisp"
                "embark.lisp"
                ;; minad P3: Consult + Marginalia
                "consult.lisp"
                "marginalia.lisp"))
  (format t "[loading unit] ~a~%" file)
  (handler-case (load (rel file))
    (error (e) (format t "  !! ~a: ~a~%" file e))))

(in-package #:limn/unit-test)

(let ((ok (run-suite)))
  (sb-ext:exit :code (if ok 0 1)))
