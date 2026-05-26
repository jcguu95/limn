;;;; v0.38 B12: %event-key-spec correctly handles Shift+uppercase letter
;;;;
;;;; Wire delivers {key:"G", mods:["shift"]} when user presses Shift+g.
;;;; In Emacs convention the uppercase letter already encodes the shift,
;;;; so the keymap lookup should be "G" — not "S-G".

(in-package #:limn/unit-test)

(defun %ks (key &optional mods)
  "Helper: invoke limn::%event-key-spec on a fake key plist."
  (let ((fn (find-symbol "%EVENT-KEY-SPEC" :limn)))
    (when (and fn (fboundp fn))
      (funcall (symbol-function fn) (list :|key| key :|mods| mods)))))

(deftest v038-b12-shift-letter-becomes-uppercase-not-S-prefix
  "{key:'G', mods:['shift']} → 'G' (not 'S-G')."
  (let ((spec (%ks "G" '("shift"))))
    (assert-equal "G" spec
                  "Shift+G should resolve to keymap key 'G'")))

(deftest v038-b12-shift-lowercase-non-letter-keeps-shift
  "{key:'5', mods:['shift']} → 'S-5' (numbers can't encode shift in case)."
  (let ((spec (%ks "5" '("shift"))))
    (assert-equal "S-5" spec
                  "Shift+5 should remain 'S-5'")))

(deftest v038-b12-ctrl-shift-letter-becomes-C-uppercase
  "{key:'G', mods:['ctrl','shift']} → 'C-G' (Ctrl + uppercase, Shift redundant)."
  (let ((spec (%ks "G" '("ctrl" "shift"))))
    (assert-equal "C-G" spec
                  "Ctrl+Shift+g should resolve to 'C-G' (shift redundant)")))

(deftest v038-b12-lowercase-with-shift-already-uppercase-encoding-edge
  "{key:'g', mods:['shift']} → 'S-g' (lowercase letter with shift mod —
   probably never emitted by Qt for letters, but harmless to preserve)."
  (let ((spec (%ks "g" '("shift"))))
    (assert-equal "S-g" spec
                  "lowercase g + shift → S-g (no special handling)")))

(deftest v038-b12-no-mods-returns-key-unchanged
  (assert-equal "j" (%ks "j" nil))
  (assert-equal "G" (%ks "G" nil)))

(deftest v038-b12-plain-ctrl-still-works
  "{key:'d', mods:['ctrl']} → 'C-d'."
  (assert-equal "C-d" (%ks "d" '("ctrl"))))
