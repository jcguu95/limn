;;;; v0.19 keymap α + β — pure-Lisp RED tests.
;;;;
;;;; SPEC §12 v0.19 + §9.1 extension:
;;;;
;;;;   α — fill in existing SPEC contract (no contract change):
;;;;     A. (define-mode :parent ...) actually wires the keymap-parent
;;;;        link automatically (currently the :parent arg is declared
;;;;        ignored — user has to manually setf mode-keymap with a
;;;;        keymap whose parent points at another mode's keymap)
;;;;     B. (describe-bindings km) recursively walks prefix sub-keymaps
;;;;        and returns FLAT entries with "C-x f" multi-key strings
;;;;        (currently only returns top-level bindings)
;;;;     C. (lookup-key buf spec) auto-falls-back to *global-keymap*
;;;;        when neither minor nor major modes bind spec (currently
;;;;        caller has to do the fallback themselves)
;;;;
;;;;   β — new primitives (§9.1 extension, SPEC bumps v0.8 → v0.9 when
;;;;       v0.19 ships):
;;;;     D. *key-prefix* promoted from limn:: internal to limn/keys::
;;;;        exported var + key-prefix-changed hook → unlocks user-land
;;;;        which-key
;;;;     E. set-transient-map km [:on-exit fn] + *transient-keymap*
;;;;        looked up FIRST during dispatch → unlocks user-land
;;;;        hydra / repeat-mode
;;;;     F. mode-buffer gains :local-keymap slot + lookup-key consults
;;;;        it BEFORE minors → unlocks user-land local-set-key
;;;;
;;;; Pure Lisp, no C++. All tests RED until v0.19 ships.

(in-package #:limn/unit-test)

;;; Make sure every symbol we touch resolves. If v0.19 hasn't landed
;;; yet, these `find-symbol` calls return nil and the tests fall through
;;; to deliberate failure (vs a load-time package error). Once shipped,
;;; we tighten to direct package-qualified references.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/keys) (defpackage :limn/keys (:use :cl)))
  (unless (find-package :limn/mode) (defpackage :limn/mode (:use :cl)))
  (unless (find-package :limn/hooks) (defpackage :limn/hooks (:use :cl)))
  ;; Pre-intern the v0.19 symbols this file references so READ doesn't
  ;; error at load time when the impl hasn't landed yet. Tests still
  ;; FAIL at runtime (the symbols are unbound functions/vars), which
  ;; is the desired RED signal.
  (dolist (sym '("*GLOBAL-KEYMAP*" "MODE-BUFFER-LOCAL-KEYMAP"
                 "SET-LOCAL-KEYMAP"))
    (export (intern sym :limn/mode) :limn/mode))
  (dolist (sym '("*KEY-PREFIX*" "*TRANSIENT-KEYMAP*"
                 "SET-KEY-PREFIX" "SET-TRANSIENT-MAP"))
    (export (intern sym :limn/keys) :limn/keys)))

;;; ────────────────────────────────────────────────────────────────────
;;; A. (define-mode :parent X) wires keymap parent automatically
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-α-define-mode-parent-wires-keymap-parent
  "When user calls (define-mode 'child :parent 'base), the child mode's
   keymap should have keymap-parent set to base's keymap automatically."
  (limn/mode:clear-modes)
  (let ((base  (limn/mode:define-mode 'base  :type :major
                                            :modeline "Base"))
        (child (limn/mode:define-mode 'child :type :major
                                            :parent 'base
                                            :modeline "Child")))
    ;; Both modes need a keymap to test the link. define-mode currently
    ;; doesn't auto-create one; v0.19 α should either create lazily or
    ;; still let user supply one — either way, after both have keymaps,
    ;; child's parent must be base's.
    (setf (limn/mode:mode-keymap base)  (limn/keys:make-keymap))
    (setf (limn/mode:mode-keymap child) (limn/keys:make-keymap))
    ;; Re-trigger the link (post-v0.19 this happens inside define-mode
    ;; OR via a public re-link call). For now we check the contract:
    ;; the link must exist after define-mode :parent is honoured.
    (limn/mode:define-mode 'child :type :major
                                 :parent 'base
                                 :modeline "Child")
    (assert-eq (limn/mode:mode-keymap base)
               (limn/keys::keymap-parent (limn/mode:mode-keymap child))
               "child's keymap.parent === base's keymap")))

(deftest v019-α-lookup-walks-parent-chain
  "A key bound only on the parent should be lookup-able through the child."
  (limn/mode:clear-modes)
  (let ((base  (limn/mode:define-mode 'base  :type :major))
        (child (limn/mode:define-mode 'child :type :major :parent 'base))
        (bkm   (limn/keys:make-keymap))
        (ckm   (limn/keys:make-keymap)))
    (setf (limn/mode:mode-keymap base)  bkm)
    (setf (limn/mode:mode-keymap child) ckm)
    (limn/mode:define-mode 'child :type :major :parent 'base)  ; re-link
    (limn/keys:define-key bkm "C-s" 'search-from-base)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'child)
      (assert-eq 'search-from-base
                 (limn/mode:lookup-key buf "C-s")
                 "child inherits C-s via keymap parent chain"))))

(deftest v019-α-child-binding-shadows-parent
  "When both parent and child bind the same key, child wins."
  (limn/mode:clear-modes)
  (let ((base  (limn/mode:define-mode 'base  :type :major))
        (child (limn/mode:define-mode 'child :type :major :parent 'base))
        (bkm   (limn/keys:make-keymap))
        (ckm   (limn/keys:make-keymap)))
    (setf (limn/mode:mode-keymap base)  bkm)
    (setf (limn/mode:mode-keymap child) ckm)
    (limn/mode:define-mode 'child :type :major :parent 'base)
    (limn/keys:define-key bkm "C-s" 'base-search)
    (limn/keys:define-key ckm "C-s" 'child-search)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'child)
      (assert-eq 'child-search (limn/mode:lookup-key buf "C-s")
                 "child binding shadows parent"))))

;;; ────────────────────────────────────────────────────────────────────
;;; B. describe-bindings recursive walk
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-α-describe-bindings-top-level-still-works
  "Regression: top-level (non-prefix) bindings still appear as before."
  (let ((km (limn/keys:make-keymap)))
    (limn/keys:define-key km "j" 'next-line)
    (limn/keys:define-key km "k" 'prev-line)
    (let* ((bs   (limn/keys:describe-bindings km))
           (keys (mapcar #'car bs)))
      (assert-equal 2 (length bs))
      (assert-true (member "j" keys :test #'string=))
      (assert-true (member "k" keys :test #'string=)))))

(deftest v019-α-describe-bindings-walks-prefix
  "A binding under a prefix-keymap should appear as 'C-x f' (space-
   separated full key sequence), not as nested alist."
  (let ((km (limn/keys:make-keymap)))
    (limn/keys:define-key km "C-x f" 'find-file)
    (limn/keys:define-key km "C-x s" 'save-file)
    (let* ((bs   (limn/keys:describe-bindings km))
           (keys (mapcar #'car bs)))
      (assert-true (member "C-x f" keys :test #'string=)
                   "C-x f appears flat")
      (assert-true (member "C-x s" keys :test #'string=)
                   "C-x s appears flat")
      (assert-true (not (find-if (lambda (e) (limn/keys:keymap-p (cdr e)))
                                  bs))
                   "no raw sub-keymap leaks into the result"))))

(deftest v019-α-describe-bindings-walks-deep-prefix
  "Multi-level prefix: 'C-x 4 f' walks two prefix layers."
  (let ((km (limn/keys:make-keymap)))
    (limn/keys:define-key km "C-x 4 f" 'find-file-other-window)
    (let* ((bs (limn/keys:describe-bindings km)))
      (assert-true (assoc "C-x 4 f" bs :test #'string=)
                   "C-x 4 f appears as flat 3-key string"))))

(deftest v019-α-describe-bindings-mixes-top-and-prefix
  "Top-level + prefix bindings both appear; counts add."
  (let ((km (limn/keys:make-keymap)))
    (limn/keys:define-key km "j"       'next-line)
    (limn/keys:define-key km "C-x f"   'find-file)
    (limn/keys:define-key km "C-x C-s" 'save)
    (let ((bs (limn/keys:describe-bindings km)))
      (assert-equal 3 (length bs)
                    "j + C-x f + C-x C-s = 3 entries"))))

;;; ────────────────────────────────────────────────────────────────────
;;; C. lookup-key falls back to *global-keymap*
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-α-lookup-key-falls-back-to-global
  "When no mode binds spec, lookup-key consults *global-keymap*."
  (limn/mode:clear-modes)
  (let ((global (limn/keys:make-keymap))
        (buf    (limn/mode:make-mode-buffer)))
    (limn/keys:define-key global "C-g" 'keyboard-quit)
    (let ((limn/mode:*global-keymap* global))
      (assert-eq 'keyboard-quit
                 (limn/mode:lookup-key buf "C-g")
                 "C-g found in *global-keymap* even with empty buffer"))))

(deftest v019-α-mode-binding-shadows-global
  "When a mode AND global both bind a key, mode wins (global is fallback)."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'pdf :type :major))
         (kpdf  (limn/keys:make-keymap))
         (global (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) kpdf)
    (limn/keys:define-key kpdf   "j" 'pdf-next-page)
    (limn/keys:define-key global "j" 'global-down)
    (limn/mode:activate buf 'pdf)
    (let ((limn/mode:*global-keymap* global))
      (assert-eq 'pdf-next-page (limn/mode:lookup-key buf "j")
                 "mode binding wins over global"))))

(deftest v019-α-lookup-key-nil-when-neither-binds
  "Unknown key returns nil from lookup-key."
  (limn/mode:clear-modes)
  (let ((global (limn/keys:make-keymap))
        (buf    (limn/mode:make-mode-buffer)))
    (let ((limn/mode:*global-keymap* global))
      (assert-eq nil (limn/mode:lookup-key buf "C-q")
                 "no binding anywhere → nil"))))

;;; ────────────────────────────────────────────────────────────────────
;;; D. *key-prefix* promoted + key-prefix-changed hook
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-β-key-prefix-exported-from-limn-keys
  "*key-prefix* is a public symbol in limn/keys (not limn:: internal)."
  (assert-true (find-symbol "*KEY-PREFIX*" :limn/keys)
               "limn/keys:*key-prefix* exists")
  (let ((sym (find-symbol "*KEY-PREFIX*" :limn/keys)))
    (assert-true (and sym (boundp sym))
                 "symbol is bound")))

(deftest v019-β-key-prefix-default-empty-list
  "Default value of *key-prefix* is the empty list (start-of-sequence)."
  (assert-equal '() (symbol-value (find-symbol "*KEY-PREFIX*" :limn/keys))
                "*key-prefix* default = ()"))

(deftest v019-β-key-prefix-changed-hook-fires
  "Setting *key-prefix* (via the framework's accumulator) fires
   event/key-prefix-changed hook with the new value. User-land which-
   key implementations subscribe to this hook."
  (let ((fired nil)
        (sym   (find-symbol "*KEY-PREFIX*" :limn/keys)))
    (limn/hooks:add-hook "event/key-prefix-changed"
                         (lambda (info) (push info fired)))
    ;; Simulate the framework setting it (in real dispatch, %dispatch-key
    ;; calls a setter helper that fires the hook).
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '("C-x"))
    (unwind-protect
      (assert-true fired "hook fired on *key-prefix* change")
      ;; cleanup
      (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())
      (limn/hooks:remove-hook "event/key-prefix-changed"
                              (lambda (info) (push info fired))))))

(deftest v019-β-key-prefix-changed-hook-receives-old-and-new
  "Hook info plist contains :old and :new for differential rendering."
  (let ((captured nil))
    (limn/hooks:add-hook "event/key-prefix-changed"
                         (lambda (info) (setf captured info)))
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())   ; reset
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '("C-x"))
    (assert-equal '()      (getf captured :|old|) "old was empty")
    (assert-equal '("C-x") (getf captured :|new|) "new is ('C-x')")
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())))

;;; ────────────────────────────────────────────────────────────────────
;;; E. set-transient-map / *transient-keymap*
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-β-set-transient-map-defined
  "set-transient-map is a public symbol in limn/keys."
  (assert-true (find-symbol "SET-TRANSIENT-MAP" :limn/keys)
               "set-transient-map exists"))

(deftest v019-β-transient-keymap-default-nil
  "*transient-keymap* default value is NIL (no transient active)."
  (let ((sym (find-symbol "*TRANSIENT-KEYMAP*" :limn/keys)))
    (assert-true (and sym (boundp sym)) "symbol bound")
    (assert-eq nil (symbol-value sym) "default nil")))

(deftest v019-β-set-transient-map-sets-and-clears
  "After (set-transient-map km), *transient-keymap* = km.
   (set-transient-map nil) clears."
  (let ((km (limn/keys:make-keymap)))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) km)
    (assert-eq km (symbol-value (find-symbol "*TRANSIENT-KEYMAP*" :limn/keys))
               "active")
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)
    (assert-eq nil (symbol-value (find-symbol "*TRANSIENT-KEYMAP*" :limn/keys))
               "cleared")))

(deftest v019-β-transient-shadows-mode-and-global
  "When transient is set with a binding for K, lookup-key returns the
   transient binding even if mode / global also bind K."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'm :type :major))
         (mkm   (limn/keys:make-keymap))
         (gkm   (limn/keys:make-keymap))
         (tkm   (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mkm)
    (limn/keys:define-key mkm "j" 'mode-down)
    (limn/keys:define-key gkm "j" 'global-down)
    (limn/keys:define-key tkm "j" 'transient-down)
    (limn/mode:activate buf 'm)
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) tkm)
    (let ((limn/mode:*global-keymap* gkm))
      (assert-eq 'transient-down (limn/mode:lookup-key buf "j")
                 "transient beats mode + global"))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)))

(deftest v019-β-transient-falls-through-when-no-binding
  "Transient with NO binding for K → fall through to normal stack
   (mode → global). User-defined behaviour can opt to clear transient
   in that case via :on-exit; default = leave active."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'm :type :major))
         (mkm   (limn/keys:make-keymap))
         (tkm   (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mkm)
    (limn/keys:define-key mkm "k" 'mode-up)
    ;; transient binds only "j"
    (limn/keys:define-key tkm "j" 'transient-down)
    (limn/mode:activate buf 'm)
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) tkm)
    (assert-eq 'mode-up (limn/mode:lookup-key buf "k")
               "fall through to mode for unbound key")
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)))

(deftest v019-β-set-transient-map-on-exit-fires
  "set-transient-map :on-exit fn is called when transient is cleared."
  (let ((fired 0)
        (km (limn/keys:make-keymap)))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) km
             :on-exit (lambda () (incf fired)))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)
    (assert-equal 1 fired ":on-exit thunk fired once on clear")))

;;; ────────────────────────────────────────────────────────────────────
;;; F. mode-buffer :local-keymap slot + lookup layer
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-β-mode-buffer-has-local-keymap-slot
  "mode-buffer struct gains a :local-keymap slot accessible via
   mode-buffer-local-keymap (and settable via setf)."
  (let ((buf (limn/mode:make-mode-buffer)))
    (assert-true (find-symbol "MODE-BUFFER-LOCAL-KEYMAP" :limn/mode)
                 "accessor exists")
    (assert-eq nil (funcall (find-symbol "MODE-BUFFER-LOCAL-KEYMAP"
                                          :limn/mode) buf)
               "default nil")))

(deftest v019-β-local-keymap-shadows-minors-and-major
  "When local-keymap binds K, it wins over minor + major (matches
   Emacs's local-set-key semantics — buffer-local override)."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'm  :type :major))
         (minor (limn/mode:define-mode 'mi :type :minor))
         (mkm   (limn/keys:make-keymap))
         (mikm  (limn/keys:make-keymap))
         (lkm   (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mkm)
    (setf (limn/mode:mode-keymap minor) mikm)
    (limn/keys:define-key mkm  "C-c" 'major-handler)
    (limn/keys:define-key mikm "C-c" 'minor-handler)
    (limn/keys:define-key lkm  "C-c" 'local-handler)
    (limn/mode:activate buf 'm)
    (limn/mode:activate buf 'mi)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf lkm)
    (assert-eq 'local-handler (limn/mode:lookup-key buf "C-c")
               "local-keymap shadows minor + major")))

(deftest v019-β-local-keymap-falls-through-when-no-binding
  "When local-keymap has no binding for K, fall through to minors/major."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'm :type :major))
         (mkm   (limn/keys:make-keymap))
         (lkm   (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mkm)
    (limn/keys:define-key mkm "j" 'major-down)
    ;; local-keymap binds only "x"
    (limn/keys:define-key lkm "x" 'local-x)
    (limn/mode:activate buf 'm)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf lkm)
    (assert-eq 'major-down (limn/mode:lookup-key buf "j")
               "j falls through to major when local doesn't bind it")))

(deftest v019-β-local-keymap-per-buffer-isolated
  "Two mode-buffers with different local-keymaps don't share state."
  (let* ((bufA (limn/mode:make-mode-buffer))
         (bufB (limn/mode:make-mode-buffer))
         (kmA  (limn/keys:make-keymap))
         (kmB  (limn/keys:make-keymap)))
    (limn/keys:define-key kmA "k" 'in-A)
    (limn/keys:define-key kmB "k" 'in-B)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) bufA kmA)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) bufB kmB)
    (assert-eq 'in-A (limn/mode:lookup-key bufA "k"))
    (assert-eq 'in-B (limn/mode:lookup-key bufB "k"))))

;;; ────────────────────────────────────────────────────────────────────
;;; G. Full lookup precedence integration
;;; ────────────────────────────────────────────────────────────────────

(deftest v019-β-full-precedence-transient-local-minor-major-global
  "Full precedence: transient → local → minors (newest first) → major
   → global. Verify each layer wins when only it binds the key."
  (limn/mode:clear-modes)
  (let* ((global (limn/keys:make-keymap))
         (major  (limn/mode:define-mode 'maj  :type :major))
         (minor  (limn/mode:define-mode 'min  :type :minor))
         (mjkm   (limn/keys:make-keymap))
         (mnkm   (limn/keys:make-keymap))
         (lkm    (limn/keys:make-keymap))
         (tkm    (limn/keys:make-keymap))
         (buf    (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mjkm)
    (setf (limn/mode:mode-keymap minor) mnkm)
    (limn/mode:activate buf 'maj)
    (limn/mode:activate buf 'min)
    ;; bind same key K in each layer with distinct action
    (limn/keys:define-key global "K" 'g)
    (limn/keys:define-key mjkm   "K" 'mj)
    (limn/keys:define-key mnkm   "K" 'mn)
    (limn/keys:define-key lkm    "K" 'l)
    (limn/keys:define-key tkm    "K" 't)
    (let ((limn/mode:*global-keymap* global))
      ;; start: nothing local / transient → minor wins (newest)
      (assert-eq 'mn (limn/mode:lookup-key buf "K") "minor wins by default")
      ;; add local → local wins
      (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf lkm)
      (assert-eq 'l (limn/mode:lookup-key buf "K") "local beats minor")
      ;; add transient → transient wins
      (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) tkm)
      (assert-eq 't (limn/mode:lookup-key buf "K") "transient beats local")
      ;; cleanup
      (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)
      (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf nil))))


;;; ────────────────────────────────────────────────────────────────────
;;; Round 2 — coverage audit additions (Emacs-way semantics)
;;; ────────────────────────────────────────────────────────────────────

;;; ── A+. parent chain edge cases ─────────────────────────────────────

(deftest v019-α-define-mode-parent-unknown-fails
  "define-mode :parent pointing at a nonexistent mode signals an error
   (vs silently leaving keymap.parent = nil — that's a footgun)."
  (limn/mode:clear-modes)
  (assert-true
    (handler-case
      (progn
        (limn/mode:define-mode 'child :type :major :parent 'ghost)
        nil)
      (error () t))
    "unknown :parent → error"))

(deftest v019-α-grandparent-chain-walks
  "3-level parent chain: gp → p → c. Key bound only on gp is reachable
   from c via the full chain."
  (limn/mode:clear-modes)
  (let ((gp (limn/mode:define-mode 'gp :type :major))
        (p  (limn/mode:define-mode 'p  :type :major :parent 'gp))
        (c  (limn/mode:define-mode 'c  :type :major :parent 'p)))
    (setf (limn/mode:mode-keymap gp) (limn/keys:make-keymap))
    (setf (limn/mode:mode-keymap p)  (limn/keys:make-keymap))
    (setf (limn/mode:mode-keymap c)  (limn/keys:make-keymap))
    (limn/mode:define-mode 'p :type :major :parent 'gp)
    (limn/mode:define-mode 'c :type :major :parent 'p)
    (limn/keys:define-key (limn/mode:mode-keymap gp) "C-h" 'grandparent-help)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'c)
      (assert-eq 'grandparent-help (limn/mode:lookup-key buf "C-h")
                 "C-h walks c → p → gp"))))

(deftest v019-α-redefine-mode-with-new-parent-updates-link
  "Re-calling define-mode with a DIFFERENT :parent updates the link
   live (existing buffers see new chain immediately)."
  (limn/mode:clear-modes)
  (let ((a (limn/mode:define-mode 'a :type :major))
        (b (limn/mode:define-mode 'b :type :major))
        (c (limn/mode:define-mode 'c :type :major :parent 'a)))
    (setf (limn/mode:mode-keymap a) (limn/keys:make-keymap))
    (setf (limn/mode:mode-keymap b) (limn/keys:make-keymap))
    (setf (limn/mode:mode-keymap c) (limn/keys:make-keymap))
    (limn/mode:define-mode 'c :type :major :parent 'a)  ; link → a
    (limn/keys:define-key (limn/mode:mode-keymap a) "K" 'from-a)
    (limn/keys:define-key (limn/mode:mode-keymap b) "K" 'from-b)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'c)
      (assert-eq 'from-a (limn/mode:lookup-key buf "K") "initial parent a")
      ;; Re-define with parent b
      (limn/mode:define-mode 'c :type :major :parent 'b)
      (assert-eq 'from-b (limn/mode:lookup-key buf "K")
                 "parent re-link to b takes effect immediately"))))

(deftest v019-α-circular-parent-detected
  "define-mode :parent that would create a cycle (A→B→A) must error,
   not silently accept (would infinite-loop on lookup)."
  (limn/mode:clear-modes)
  (limn/mode:define-mode 'a :type :major)
  (limn/mode:define-mode 'b :type :major :parent 'a)
  (setf (limn/mode:mode-keymap (limn/mode:find-mode 'a)) (limn/keys:make-keymap))
  (setf (limn/mode:mode-keymap (limn/mode:find-mode 'b)) (limn/keys:make-keymap))
  (limn/mode:define-mode 'b :type :major :parent 'a)
  (assert-true
    (handler-case
      (progn (limn/mode:define-mode 'a :type :major :parent 'b) nil)
      (error () t))
    "cycle a→b→a rejected"))

;;; ── B+. describe-bindings edge cases ───────────────────────────────

(deftest v019-α-describe-bindings-empty-keymap
  "Empty keymap → empty alist (not nil-vs-empty confusion, deterministic)."
  (let* ((km (limn/keys:make-keymap))
         (bs (limn/keys:describe-bindings km)))
    (assert-equal 0 (length bs) "no entries for empty keymap")
    (assert-true (listp bs) "still a list, not nil-as-error")))

(deftest v019-α-describe-bindings-excludes-parent-by-default
  "describe-bindings returns OWN bindings only (matches Emacs's
   default — parent inheritance has its own section/API). Tests that
   we don't accidentally flatten parent into the same list."
  (let* ((parent (limn/keys:make-keymap))
         (child  (limn/keys:make-keymap)))
    (limn/keys:define-key parent "p" 'in-parent)
    (limn/keys:define-key child  "c" 'in-child)
    (limn/keys::define-parent child parent)
    (let* ((bs   (limn/keys:describe-bindings child))
           (keys (mapcar #'car bs)))
      (assert-true (member "c" keys :test #'string=) "own binding present")
      (assert-true (not (member "p" keys :test #'string=))
                   "parent binding NOT included (own-only semantics)"))))

;;; ── C+. lookup-key with nil global / no setup ───────────────────────

(deftest v019-α-lookup-key-no-global-nil-buffer-safe
  "*global-keymap* unbound / nil + empty mode-buffer → lookup returns
   nil cleanly (no crash, no infinite parent chain)."
  (limn/mode:clear-modes)
  (let ((buf (limn/mode:make-mode-buffer))
        (limn/mode:*global-keymap* nil))
    (assert-eq nil (limn/mode:lookup-key buf "anything")
               "no setup → nil")))

;;; ── D+. *key-prefix* hook semantics ─────────────────────────────────

(deftest v019-β-key-prefix-no-fire-when-unchanged
  "Setting *key-prefix* to the SAME value should NOT fire the hook —
   spam protection. Matches Emacs's setq-default behaviour for
   buffer-local var change hooks."
  (let ((fires 0))
    (limn/hooks:add-hook "event/key-prefix-changed"
                         (lambda (_) (incf fires)))
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())
    (let ((baseline fires))
      (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())  ; same
      (assert-equal baseline fires
                    "no fire when value unchanged"))))

(deftest v019-β-key-prefix-hook-multiple-subscribers
  "All hook subscribers fire on a change."
  (let ((a 0) (b 0))
    (limn/hooks:add-hook "event/key-prefix-changed"
                         (lambda (_) (incf a)))
    (limn/hooks:add-hook "event/key-prefix-changed"
                         (lambda (_) (incf b)))
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())  ; reset baseline
    (let ((a0 a) (b0 b))
      (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '("C-c"))
      (assert-true (and (> a a0) (> b b0))
                   "both subscribers fired"))))

(deftest v019-β-key-prefix-hook-removable
  "Removing a hook prevents it firing on subsequent changes."
  (let* ((fires 0)
         (handler (lambda (_) (incf fires))))
    (limn/hooks:add-hook    "event/key-prefix-changed" handler)
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '())
    (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '("X"))
    (let ((before-removal fires))
      (limn/hooks:remove-hook "event/key-prefix-changed" handler)
      (funcall (find-symbol "SET-KEY-PREFIX" :limn/keys) '("Y"))
      (assert-equal before-removal fires
                    "no further fires after remove-hook"))))

;;; ── E+. set-transient-map twice / replacement semantics ────────────

(deftest v019-β-set-transient-map-twice-fires-prev-on-exit
  "Calling set-transient-map AGAIN while one is active fires the
   previous map's :on-exit (Emacs convention — the old transient is
   'left'). The new map's :on-exit only fires when IT is later cleared."
  (let ((prev-fired 0)
        (new-fired  0)
        (km1 (limn/keys:make-keymap))
        (km2 (limn/keys:make-keymap)))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) km1
             :on-exit (lambda () (incf prev-fired)))
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) km2
             :on-exit (lambda () (incf new-fired)))
    (assert-equal 1 prev-fired "previous :on-exit fired on replacement")
    (assert-equal 0 new-fired  "new :on-exit not yet fired")
    (funcall (find-symbol "SET-TRANSIENT-MAP" :limn/keys) nil)
    (assert-equal 1 new-fired  "new :on-exit fires on final clear")))

;;; ── F+. local-keymap lifecycle vs mode activation ──────────────────

(deftest v019-β-local-keymap-set-to-nil-clears
  "(set-local-keymap buf nil) clears the slot — buffer reverts to
   normal minor / major lookup."
  (limn/mode:clear-modes)
  (let* ((major (limn/mode:define-mode 'm :type :major))
         (mkm   (limn/keys:make-keymap))
         (lkm   (limn/keys:make-keymap))
         (buf   (limn/mode:make-mode-buffer)))
    (setf (limn/mode:mode-keymap major) mkm)
    (limn/keys:define-key mkm "K" 'mode-K)
    (limn/keys:define-key lkm "K" 'local-K)
    (limn/mode:activate buf 'm)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf lkm)
    (assert-eq 'local-K (limn/mode:lookup-key buf "K"))
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf nil)
    (assert-eq 'mode-K (limn/mode:lookup-key buf "K")
               "cleared → reverts to mode binding")))

(deftest v019-β-local-keymap-survives-mode-switch
  "local-keymap is BUFFER-LOCAL — deactivating major and activating
   a different one does not clear local-keymap (it's orthogonal)."
  (limn/mode:clear-modes)
  (limn/mode:define-mode 'm1 :type :major)
  (limn/mode:define-mode 'm2 :type :major)
  (let* ((lkm (limn/keys:make-keymap))
         (buf (limn/mode:make-mode-buffer)))
    (limn/keys:define-key lkm "K" 'persistent)
    (limn/mode:activate buf 'm1)
    (funcall (find-symbol "SET-LOCAL-KEYMAP" :limn/mode) buf lkm)
    (assert-eq 'persistent (limn/mode:lookup-key buf "K"))
    (limn/mode:activate buf 'm2)         ; major mode switch
    (assert-eq 'persistent (limn/mode:lookup-key buf "K")
               "local-keymap binding survives major mode change")))
