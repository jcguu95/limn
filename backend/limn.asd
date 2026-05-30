;;;; limn.asd — ASDF system definition for the Limn backend.
;;;;
;;;; v0.37 A2: replaces the dolist-based load-as-source bring-up in
;;;; backend/repl.lisp + backend/tests/unit/run-unit.lisp.  ASDF
;;;; compile-then-loads each file in topological-dependency order, so
;;;; forward references resolve at load time and the smoke output
;;;; stays clean (zero STYLE-WARNING).
;;;;
;;;; The dependency chain is LINEAR — each module depends on its
;;;; predecessor in the historical load order from repl.lisp.  This is
;;;; conservative (a true DAG would allow more parallelism) but matches
;;;; the previous bring-up behaviour exactly, so the conversion is a
;;;; pure refactor: same load order, same eventual symbol environment,
;;;; just no forward-reference noise during compile.
;;;;
;;;; FASL files cache under ASDF's user output cache (~/.cache/common-
;;;; lisp/), so subsequent loads after the first compile are instant.
;;;;
;;;; Usage:
;;;;   (require :asdf)
;;;;   (asdf:load-system :limn)
;;;;
;;;; To rebuild from scratch (e.g. after a code change to an early
;;;; module that cascades):
;;;;   (asdf:clear-system :limn)
;;;;   (asdf:load-system :limn :force t)

(defsystem #:limn
  :description "Limn — Common Lisp backend for the Sioyek-core PDF + text editor."
  :version "0.37"
  :license "Same as Sioyek-core (see philosophy.org)."
  :author "Jin <jcguu95>"
  :depends-on (#:cl-ppcre)
  :pathname "."
  :serial nil    ; explicit :depends-on per component instead
  :components
  (
    (:file "limn-hooks")
    (:file "limn-log" :depends-on ("limn-hooks"))
    (:file "limn-error" :depends-on ("limn-log"))
    (:file "limn-timer" :depends-on ("limn-error"))
    (:file "limn-process" :depends-on ("limn-timer"))
    (:file "limn-buffer" :depends-on ("limn-process"))
    (:file "limn-bridge" :depends-on ("limn-buffer"))
    (:file "limn-undo" :depends-on ("limn-bridge"))
    (:file "limn-buffer-undo" :depends-on ("limn-undo"))
    (:file "limn-keys" :depends-on ("limn-buffer-undo"))
    (:file "limn-search" :depends-on ("limn-keys"))
    (:file "limn-client" :depends-on ("limn-search"))
    (:file "limn-dispatch" :depends-on ("limn-client"))
    (:file "limn-mode" :depends-on ("limn-dispatch"))
    (:file "limn-cmd" :depends-on ("limn-mode"))
    (:file "limn-runtime" :depends-on ("limn-cmd"))
    (:file "limn-introspect" :depends-on ("limn-runtime"))
    (:file "limn-text-mode" :depends-on ("limn-introspect"))
    (:file "limn-kill" :depends-on ("limn-text-mode"))
    (:file "limn-mark" :depends-on ("limn-kill"))
    (:file "limn-register" :depends-on ("limn-mark"))
    (:file "limn-kmacro" :depends-on ("limn-register"))
    (:file "limn-file" :depends-on ("limn-kmacro"))
    (:file "limn-auto-save" :depends-on ("limn-file"))
    (:file "limn-backup" :depends-on ("limn-auto-save"))
    (:file "limn-recentf" :depends-on ("limn-backup"))
    (:file "limn-history" :depends-on ("limn-recentf"))
    (:file "limn-custom" :depends-on ("limn-history"))
    (:file "limn-advice" :depends-on ("limn-custom"))
    (:file "limn-face" :depends-on ("limn-advice"))
    (:file "limn-text-props" :depends-on ("limn-face"))
    (:file "limn-help" :depends-on ("limn-text-props"))
    (:file "limn-completion" :depends-on ("limn-help"))
    (:file "limn-isearch" :depends-on ("limn-completion"))
    (:file "limn-occur" :depends-on ("limn-isearch"))
    (:file "limn-pdf-mode" :depends-on ("limn-occur"))
    (:file "limn-text-nav" :depends-on ("limn-pdf-mode"))
    (:file "limn-map-macro" :depends-on ("limn-text-nav"))
    (:file "limn-which-key" :depends-on ("limn-map-macro"))
    (:file "limn-marker" :depends-on ("limn-which-key"))
    (:file "limn-local" :depends-on ("limn-marker"))
    (:file "limn-syntax" :depends-on ("limn-local"))
    (:file "limn-coding" :depends-on ("limn-syntax"))
    (:file "limn-excursion" :depends-on ("limn-coding"))
    (:file "limn-overlays" :depends-on ("limn-excursion"))
    (:file "limn-region" :depends-on ("limn-overlays"))
    (:file "limn-regex" :depends-on ("limn-region"))
    (:file "limn-file-notify" :depends-on ("limn-regex"))
    (:file "limn-auto-revert" :depends-on ("limn-file-notify"))
    (:file "limn-indent" :depends-on ("limn-auto-revert"))
    (:file "limn-query-replace" :depends-on ("limn-indent"))
    ;; v0.37 "bookmark everywhere" — cross-buffer named bookmarks
    ;; (Emacs bookmark.el analog).  Per-mode jump handlers register
    ;; themselves later in their own modules.  Pure Lisp; coexists
    ;; with limn-pdf-mode §E's per-doc single-char bookmark system.
    (:file "limn-bookmark" :depends-on ("limn-query-replace"))
    ;; bookmark-cmds: M-x bookmark-set/jump/list/delete/rename + the
    ;; keymap installer.  Needs limn/cmd, limn/keys, limn/completion,
    ;; and the limn/bookmark core — so loaded right after them.
    (:file "limn-bookmark-cmds" :depends-on ("limn-bookmark"))
    ;; v0.37 Phase B: ships sane defaults (M-x, M-r, which-key on).
    ;; Late in chain so it can use completion + which-key directly.
    (:file "limn-default-config" :depends-on ("limn-bookmark-cmds"))
    (:file "limn" :depends-on ("limn-default-config"))))
