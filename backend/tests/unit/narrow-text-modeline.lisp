;;;; v0.40 §2.5 — text-mode modeline format tests.
;;;;
;;;; Pure-string formatter tests for limn/text:text-format-modeline.
;;;; The wire-pushing half (text-mode-update-modeline) needs a running
;;;; Limn and is covered by integration tests.

(in-package #:limn/unit-test)

;;; ── basename extraction ─────────────────────────────────────────────

(deftest text-modeline-format-shows-basename-only
  "Label uses basename, not full path."
  (let ((label (limn/text:text-format-modeline "/tmp/foo/bar.txt" "")))
    (check (search "Text: bar.txt" label)
           "basename in label" "got: ~a" label)
    (check (null (search "/tmp" label))
           "no full path leaked" "got: ~a" label)))

(deftest text-modeline-format-scratch-when-no-path
  "PATH=nil → \"Text: *scratch*\"。"
  (let ((label (limn/text:text-format-modeline nil "")))
    (assert-equal "Text: *scratch*" label
                  "nil path → *scratch*")))

(deftest text-modeline-format-empty-path-is-scratch
  "PATH=\"\" → \"Text: *scratch*\"。"
  (let ((label (limn/text:text-format-modeline "" "")))
    (assert-equal "Text: *scratch*" label
                  "empty path → *scratch*")))

;;; ── narrow indicator append ─────────────────────────────────────────

(deftest text-modeline-format-appends-narrow-when-narrow
  "NARROW=\"Narrow\" → label 結尾出現 \"Narrow\"。"
  (let ((label (limn/text:text-format-modeline "/tmp/foo.txt" "Narrow")))
    (check (search "Narrow" label) "Narrow in label" "got: ~a" label)
    (check (search "Text: foo.txt" label) "name still there"
           "got: ~a" label)))

(deftest text-modeline-format-omits-narrow-when-empty
  "NARROW=\"\" → label 沒有 \"Narrow\"。"
  (let ((label (limn/text:text-format-modeline "/tmp/foo.txt" "")))
    (check (null (search "Narrow" label))
           "no Narrow in label" "got: ~a" label)))

(deftest text-modeline-format-omits-narrow-when-nil
  "NARROW=nil → label 沒有 \"Narrow\"。"
  (let ((label (limn/text:text-format-modeline "/tmp/foo.txt" nil)))
    (check (null (search "Narrow" label))
           "no Narrow in label" "got: ~a" label)))
