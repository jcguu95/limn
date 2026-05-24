;;;; v0.25 §A — defface / theme RED tests  (~15 tests)
;;;;
;;;; Tests cover: defface storage, attribute set/get, inheritance,
;;;; theme define/enable/disable, and display/sync-faces payload.
;;;; All RED until limn/face is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/face)
    (make-package '#:limn/face :use '(#:cl)))
  (dolist (sym '("DEFFACE" "SET-FACE-ATTRIBUTE" "FACE-ATTRIBUTE"
                 "FACE-SPEC-SET"
                 "DEFTHEME" "ENABLE-THEME" "DISABLE-THEME"
                 "CUSTOM-THEME-SET-FACES"
                 "*FACE-TABLE*" "*ENABLED-THEME*"
                 "SYNC-FACES-PAYLOAD"))
    (let ((s (intern sym '#:limn/face)))
      (export s '#:limn/face))))

(in-package #:limn/unit-test)

;;; ─── A1. defface storage ──────────────────────────────────────────

(deftest defface-a1-stores-in-face-table
  (limn/face:defface 'test-face-a1
    '(:foreground "#ff0000" :background "#000000"))
  (assert-true (gethash 'test-face-a1 limn/face:*face-table*)
               "defface should store face in *face-table*"))

(deftest defface-a1-foreground-readable
  (limn/face:defface 'test-face-fg
    '(:foreground "#aabbcc"))
  (assert-equal "#aabbcc"
                (limn/face:face-attribute 'test-face-fg :foreground)))

(deftest defface-a1-background-readable
  (limn/face:defface 'test-face-bg
    '(:background "#112233"))
  (assert-equal "#112233"
                (limn/face:face-attribute 'test-face-bg :background)))

(deftest defface-a1-bold-readable
  (limn/face:defface 'test-face-bold '(:bold t))
  (assert-true (limn/face:face-attribute 'test-face-bold :bold)))

(deftest defface-a1-undefined-attribute-is-nil
  (limn/face:defface 'test-face-minimal '(:foreground "#ffffff"))
  (assert-false (limn/face:face-attribute 'test-face-minimal :strike-through)
                "absent attribute should return nil"))

;;; ─── A2. set-face-attribute ───────────────────────────────────────

(deftest defface-a2-set-face-attribute-updates
  (limn/face:defface 'test-face-set '(:foreground "#000000"))
  (limn/face:set-face-attribute 'test-face-set :foreground "#ffffff")
  (assert-equal "#ffffff"
                (limn/face:face-attribute 'test-face-set :foreground)))

(deftest defface-a2-set-multiple-attributes
  (limn/face:defface 'test-face-multi '())
  (limn/face:set-face-attribute 'test-face-multi :bold t)
  (limn/face:set-face-attribute 'test-face-multi :italic t)
  (assert-true (limn/face:face-attribute 'test-face-multi :bold))
  (assert-true (limn/face:face-attribute 'test-face-multi :italic)))

;;; ─── A3. face-spec-set ────────────────────────────────────────────

(deftest defface-a3-face-spec-set-replaces
  (limn/face:defface 'test-face-spec '(:foreground "#red"))
  (limn/face:face-spec-set 'test-face-spec '(:foreground "#blue" :bold t))
  (assert-equal "#blue"
                (limn/face:face-attribute 'test-face-spec :foreground))
  (assert-true (limn/face:face-attribute 'test-face-spec :bold)))

;;; ─── A4. deftheme / enable-theme / disable-theme ─────────────────

(deftest defface-a4-deftheme-defines-theme
  (limn/face:deftheme 'test-theme-a4 "A test theme")
  (assert-true (gethash 'test-theme-a4 limn/face:*face-table*)
               "deftheme should register theme"))

(deftest defface-a4-enable-theme-applies-faces
  (limn/face:defface 'test-face-themed '(:foreground "#000000"))
  (limn/face:deftheme 'test-theme-enable "Enable test")
  (limn/face:custom-theme-set-faces 'test-theme-enable
    '(test-face-themed (:foreground "#ff00ff")))
  (limn/face:enable-theme 'test-theme-enable)
  (assert-equal "#ff00ff"
                (limn/face:face-attribute 'test-face-themed :foreground)))

(deftest defface-a4-disable-theme-reverts
  (limn/face:defface 'test-face-revert '(:foreground "#original"))
  (limn/face:deftheme 'test-theme-disable "Disable test")
  (limn/face:custom-theme-set-faces 'test-theme-disable
    '(test-face-revert (:foreground "#theme-color")))
  (limn/face:enable-theme 'test-theme-disable)
  (limn/face:disable-theme 'test-theme-disable)
  (assert-equal "#original"
                (limn/face:face-attribute 'test-face-revert :foreground)))

;;; ─── A5. display/sync-faces payload ──────────────────────────────

(deftest defface-a5-sync-payload-is-list
  (limn/face:defface 'test-face-sync '(:foreground "#123456"))
  (let ((payload (limn/face:sync-faces-payload)))
    (assert-true (listp payload) "sync-faces-payload should return a list")))

(deftest defface-a5-sync-payload-contains-name
  (limn/face:defface 'test-face-sync2 '(:foreground "#abcdef"))
  (let ((payload (limn/face:sync-faces-payload)))
    (assert-true
     (find-if (lambda (entry)
                (equal (getf entry :name) "test-face-sync2"))
              payload)
     "sync payload should include face by name string")))

(deftest defface-a5-sync-payload-includes-attributes
  (limn/face:defface 'test-face-sync3 '(:foreground "#cafe00" :bold t))
  (let* ((payload (limn/face:sync-faces-payload))
         (entry (find-if (lambda (e) (equal (getf e :name) "test-face-sync3"))
                         payload)))
    (assert-true entry "entry should exist in payload")
    (assert-equal "#cafe00" (getf entry :foreground))
    (assert-true (getf entry :bold))))
