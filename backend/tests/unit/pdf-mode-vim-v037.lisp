;;;; v0.37 Phase D — pdf-mode vim keymap regression coverage
;;;;
;;;; Locks in the v0.37 additions so a refactor can't silently drop
;;;; them.  Each test guards a specific keybinding + its underlying
;;;; defcommand.

(in-package #:limn/unit-test)

;;; Re-install pdf-mode commands in case an earlier test wiped the
;;; registry via limn/cmd:clear-commands.
(defun %ensure-pdf-commands-registered ()
  (let* ((pkg (find-package '#:limn/pdf-mode))
         (re  (and pkg (find-symbol "%REGISTER-PDF-COMMANDS" pkg))))
    (when (and re (fboundp re))
      (funcall (symbol-function re)))))

(defun %pdf-cmd (name)
  "Return the defcommand struct for cl-user::NAME, or NIL."
  (let ((sym (find-symbol (string-upcase name) :cl-user)))
    (and sym (limn/cmd:find-command sym))))

;;; ── new defcommands registered ──────────────────────────────────────────

(deftest pdf-vim-half-page-down-defined
  "pdf-half-page-down registered as a defcommand."
  (%ensure-pdf-commands-registered)
  (check (not (null (%pdf-cmd "PDF-HALF-PAGE-DOWN")))
         "PDF-HALF-PAGE-DOWN registered" nil))

(deftest pdf-vim-half-page-up-defined
  "pdf-half-page-up registered."
  (%ensure-pdf-commands-registered)
  (check (not (null (%pdf-cmd "PDF-HALF-PAGE-UP")))
         "PDF-HALF-PAGE-UP registered" nil))

(deftest pdf-vim-close-defined
  "pdf-close registered."
  (%ensure-pdf-commands-registered)
  (check (not (null (%pdf-cmd "PDF-CLOSE")))
         "PDF-CLOSE registered" nil))

(deftest pdf-vim-isearch-backward-defined
  "pdf-isearch-backward registered."
  (%ensure-pdf-commands-registered)
  (check (not (null (%pdf-cmd "PDF-ISEARCH-BACKWARD")))
         "PDF-ISEARCH-BACKWARD registered" nil))

;;; ── keymap bindings present ─────────────────────────────────────────────
;;;
;;; install builds a keymap with the v0.37 bindings; this test creates
;;; a fresh pdf-mode by calling install and inspects the resulting
;;; mode-keymap.

(deftest pdf-vim-keymap-bindings
  "After (limn/pdf-mode:install), pdf-mode's keymap contains the new
   v0.37 vim bindings: C-d, C-u, l, ?, o, q, :"
  (let* ((pm-pkg (find-package '#:limn/pdf-mode))
         (inst   (and pm-pkg (find-symbol "INSTALL" pm-pkg)))
         (mode-pkg (find-package '#:limn/mode))
         (find-mode (and mode-pkg (find-symbol "FIND-MODE" mode-pkg)))
         (mode-keymap (and mode-pkg (find-symbol "MODE-KEYMAP" mode-pkg)))
         (sym-pm (find-symbol "PDF-MODE" :cl-user)))
    (assert-true inst "limn/pdf-mode:install present")
    (assert-true find-mode "limn/mode:find-mode present")
    (when (and inst find-mode mode-keymap sym-pm)
      (funcall (symbol-function inst))
      (let* ((mode (funcall (symbol-function find-mode) sym-pm))
             (km   (and mode (funcall (symbol-function mode-keymap) mode))))
        (assert-true km "pdf-mode has a keymap")
        (when km
          (dolist (spec '("C-d" "C-u" "l" "?" "o" "q"))
            (check (functionp (limn/keys:lookup-sequence km (list spec)))
                   (format nil "binding present for ~s" spec)
                   nil)))))))
