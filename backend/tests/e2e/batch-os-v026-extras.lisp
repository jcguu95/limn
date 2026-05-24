;;;; v0.26 — isearch + occur OS-tier extras (edges + integration)
;;;;
;;;; Companion to batch-os-v026-isearch.lisp + batch-os-v026-occur.lisp.
;;;; Those two cover happy paths. This file covers what got dropped from
;;;; the original plan: backward direction, wrap-around, empty queries,
;;;; state immutability, *highlight-fn* invocation tracking, per-line
;;;; semantics for occur, and cross-module integration (isearch ↔ occur
;;;; results consistency; isearch-exit + shared *search-history*; buffer
;;;; edits during an isearch session).
;;;;
;;;; No Xvfb needed.
;;;;
;;;; ── Section A: isearch edges
;;;; Ω1   backward direction (:forward nil) lands on the LAST match
;;;; Ω2a  isearch-next on last match wraps to first
;;;; Ω2b  isearch-prev on first match wraps to last
;;;; Ω3   isearch-update with "" → matches = (); cursor does NOT move
;;;; Ω4   isearch-update returns NEW state; original is untouched
;;;; Ω5   *highlight-fn* called twice per match-bearing update
;;;;        (all spans + current span); *clear-highlights-fn* fires
;;;;        on exit and on abort
;;;;
;;;; ── Section B: occur edges
;;;; Ω6   occur-prev wraps from index 0 to last index
;;;; Ω7   line with multiple matches counts as 1 result (per-line)
;;;; Ω8   empty source buffer → count=0; occur-current = nil
;;;;
;;;; ── Section C: cross-module
;;;; Ω9   isearch + occur on single-match-per-line buffer → equal counts
;;;; Ω10  isearch *history-push-fn* → limn/history built-in *search-history*
;;;; Ω11  isearch-update re-reads buffer text after wire-level insert
;;;;
;;;; ── Section D: incremental UX
;;;; Ω12  growing query: each char shrinks match set; cursor follows
;;;; Ω13  switching to no-match query mid-session → cursor stays put

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v026ex"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-history.lisp" "limn-isearch.lisp" "limn-occur.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (bid)
  (let ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (bid)
  (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| bid))
            :|offset|)
      0))

(defun fresh-text-buf ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun fill-buf (bid str)
  ;; Erase whatever was there first, then insert.
  (let ((cur (or (buf-text bid) "")))
    (when (> (length cur) 0)
      (limn:call "buffer/delete" :|buffer-id| bid
                  :|from| 0 :|to| (length cur))))
  (when (> (length str) 0)
    (limn:call "buffer/insert" :|buffer-id| bid :|at| 0 :|text| str)))

(format t "~%=== batch-os-v026-extras ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v026ex-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v026ex.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── shared vtables (re-installed in each Ω that needs a fresh buf) ──
  (defun wire-isearch-vtable (bid)
    (setf limn/isearch:*buffer-text-fn*
          (lambda (b) (or (buf-text b) "")))
    (setf limn/isearch:*buffer-cursor-fn*
          (lambda (b) (buf-cursor b)))
    (setf limn/isearch:*buffer-set-cursor-fn*
          (lambda (b off)
            (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
    (setf limn/isearch:*highlight-fn*
          (lambda (b spans face) (declare (ignore b spans face))))
    (setf limn/isearch:*clear-highlights-fn*
          (lambda (b) (declare (ignore b))))
    (setf limn/isearch:*history-push-fn*
          (lambda (q) (declare (ignore q))))
    bid)

  (defun wire-occur-vtable (src occ)
    (setf limn/occur:*buffer-text-fn*
          (lambda (b) (or (buf-text b) "")))
    (setf limn/occur:*buffer-set-cursor-fn*
          (lambda (b off)
            (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
    (setf limn/occur:*occur-write-fn*
          (lambda (obid content)
            (declare (ignore obid))
            (let ((cur (or (buf-text occ) "")))
              (when (> (length cur) 0)
                (limn:call "buffer/delete" :|buffer-id| occ
                            :|from| 0 :|to| (length cur))))
            (when (> (length content) 0)
              (limn:call "buffer/insert" :|buffer-id| occ
                          :|at| 0 :|text| content))))
    (values src occ))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; Section A: isearch edges
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω1: backward direction ──────────────────────────────────────────
  (format t "~%── Ω1: isearch :forward nil → last match ──~%")
  ;; Buffer: "hello world\nhello again\ngoodbye\n"
  ;; Two "hello" matches at offsets 0 and 12.
  ;; Place cursor at end of buffer (32), start with :forward nil.
  ;; Backward search picks the LAST match at or before saved-cursor →
  ;; offset 12 (the second hello), not 0.
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "hello world
hello again
goodbye
")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 32)
    (let* ((st  (limn/isearch:isearch-start bid :forward nil))
           (st2 (limn/isearch:isearch-update st "hello")))
      (declare (ignorable st2))
      (check (format nil "Ω1 backward saved-cursor recorded as 32 (got ~a)"
                     (limn/isearch:isearch-saved-cursor st))
             (= (limn/isearch:isearch-saved-cursor st) 32))
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω1 backward lands on LAST match offset 12 (got ~a)" c)
               (= c 12)))))

  ;;; ── Ω2: wrap-around next/prev ───────────────────────────────────────
  (format t "~%── Ω2: wrap-around next / prev ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "hello world
hello again
goodbye
")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (let* ((st  (limn/isearch:isearch-start bid))
           (st2 (limn/isearch:isearch-update st "hello"))    ; idx=0, cursor=0
           ;; idx=1 → cursor=12
           (st3 (limn/isearch:isearch-next st2))
           ;; idx=2 wraps to idx=0; cursor → 0
           (st4 (limn/isearch:isearch-next st3))
           (c-after-wrap (buf-cursor bid)))
      (declare (ignorable st4))
      (check (format nil "Ω2a next wraps last→first (cursor at 0; got ~a)" c-after-wrap)
             (= c-after-wrap 0))
      ;; Now from idx=0, prev should wrap to idx=last=1 → cursor=12
      (let* ((st5 (limn/isearch:isearch-prev st4))
             (c   (buf-cursor bid)))
        (declare (ignorable st5))
        (check (format nil "Ω2b prev wraps first→last (cursor at 12; got ~a)" c)
               (= c 12)))))

  ;;; ── Ω3: empty query keeps cursor put ───────────────────────────────
  (format t "~%── Ω3: empty query, cursor doesn't move ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "alpha beta gamma")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 7)
    (let* ((st  (limn/isearch:isearch-start bid))
           (st2 (limn/isearch:isearch-update st "")))
      (check (format nil "Ω3a matches empty (got ~s)"
                     (limn/isearch:isearch-matches st2))
             (null (limn/isearch:isearch-matches st2)))
      (check (format nil "Ω3b cursor unchanged at 7 (got ~a)" (buf-cursor bid))
             (= (buf-cursor bid) 7))))

  ;;; ── Ω4: state immutability ─────────────────────────────────────────
  (format t "~%── Ω4: isearch-update returns NEW state ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "hello hello hello")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (let* ((st1 (limn/isearch:isearch-start bid))
           (q1  (limn/isearch:isearch-query st1))
           (m1  (limn/isearch:isearch-matches st1))
           (st2 (limn/isearch:isearch-update st1 "hello")))
      (declare (ignorable st2))
      (check (format nil "Ω4a original state's query still \"\" (got ~s)" q1)
             (equal q1 ""))
      (check (format nil "Ω4b original state's matches still empty (got ~s)" m1)
             (null m1))
      ;; And after update, st1 still reads as its old self.
      (check "Ω4c original state's query unchanged post-update"
             (equal (limn/isearch:isearch-query st1) ""))
      (check "Ω4d original state's matches unchanged post-update"
             (null (limn/isearch:isearch-matches st1)))))

  ;;; ── Ω5: highlight-fn / clear-highlights-fn call counts ─────────────
  (format t "~%── Ω5: highlight + clear call tracking ──~%")
  (let ((bid (fresh-text-buf))
        (hl-calls 0)
        (cl-calls 0))
    (wire-isearch-vtable bid)
    (fill-buf bid "abc abc abc")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (setf limn/isearch:*highlight-fn*
          (lambda (b spans face) (declare (ignore b spans face))
            (incf hl-calls)))
    (setf limn/isearch:*clear-highlights-fn*
          (lambda (b) (declare (ignore b)) (incf cl-calls)))
    (let* ((st (limn/isearch:isearch-start bid))
           ;; First update with matches → highlight-fn fires 2× (all + current)
           (st2 (limn/isearch:isearch-update st "abc")))
      (check (format nil "Ω5a highlight fired twice per update with matches (got ~a)" hl-calls)
             (= hl-calls 2))
      ;; isearch-exit fires clear-highlights once.
      (limn/isearch:isearch-exit st2)
      (check (format nil "Ω5b clear fired once on exit (got ~a)" cl-calls)
             (= cl-calls 1))
      ;; Now start fresh and abort — abort also clears.
      (let* ((st3 (limn/isearch:isearch-start bid))
             (st4 (limn/isearch:isearch-update st3 "abc")))
        (declare (ignorable st4))
        (limn/isearch:isearch-abort st4)
        (check (format nil "Ω5c clear fires once more on abort (got ~a)" cl-calls)
               (= cl-calls 2)))))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; Section B: occur edges
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω6: occur-prev wrap ─────────────────────────────────────────────
  (format t "~%── Ω6: occur-prev wraps 0 → last ──~%")
  (let ((src (fresh-text-buf))
        (occ (fresh-text-buf)))
    (wire-occur-vtable src occ)
    (fill-buf src "match a
nope
match b
match c")
    ;; 3 matches on lines 1, 3, 4.
    (let* ((st  (limn/occur:occur src "match"))
           (n   (limn/occur:occur-count st)))
      (check (format nil "Ω6a 3 matches found (got ~a)" n) (= n 3))
      ;; occur-current starts at 0.
      (check (format nil "Ω6b occur-current = 0 initially (got ~s)"
                     (limn/occur:occur-current st))
             (eql (limn/occur:occur-current st) 0))
      ;; prev from current=0 should wrap to current=2 (last index).
      (let* ((st2 (limn/occur:occur-prev st))
             (cur (limn/occur:occur-current st2)))
        (check (format nil "Ω6c prev from 0 wraps to last index 2 (got ~s)" cur)
               (eql cur 2)))))

  ;;; ── Ω7: per-line semantics (multiple matches collapse to 1) ────────
  (format t "~%── Ω7: multi-match line → 1 result ──~%")
  (let ((src (fresh-text-buf))
        (occ (fresh-text-buf)))
    (wire-occur-vtable src occ)
    (fill-buf src "hello hello hello
other
hello")
    ;; Line 1 has 3 "hello"s; line 3 has 1.
    ;; Per-line semantic: 2 results (one per line that has any hit).
    (let* ((st (limn/occur:occur src "hello"))
           (n  (limn/occur:occur-count st)))
      (check (format nil "Ω7 per-line: 2 results despite 4 occurrences (got ~a)" n)
             (= n 2))
      ;; The first result should be for line 1.
      (let* ((r1 (first (limn/occur:occur-results st)))
             (ln (limn/occur:occur-match-line-num r1)))
        (check (format nil "Ω7b first result is line 1 (got ~a)" ln)
               (= ln 1)))))

  ;;; ── Ω8: empty source buffer ─────────────────────────────────────────
  (format t "~%── Ω8: empty buffer → 0 results, current = nil ──~%")
  (let ((src (fresh-text-buf))
        (occ (fresh-text-buf)))
    (wire-occur-vtable src occ)
    ;; Don't write anything into src — leave it empty.
    (let* ((st (limn/occur:occur src "anything"))
           (n  (limn/occur:occur-count st))
           (c  (limn/occur:occur-current st)))
      (check (format nil "Ω8a empty buffer → count = 0 (got ~a)" n) (= n 0))
      (check (format nil "Ω8b empty buffer → current = nil (got ~s)" c) (null c))))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; Section C: cross-module integration
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω9: isearch + occur counts equal on single-match-per-line ─────
  (format t "~%── Ω9: isearch ⇔ occur consistency ──~%")
  (let ((src (fresh-text-buf))
        (occ (fresh-text-buf)))
    (wire-isearch-vtable src)
    (wire-occur-vtable src occ)
    (fill-buf src "alpha needle beta
gamma needle delta
epsilon plain phi
zeta needle eta")
    ;; 3 lines contain "needle", each exactly once.
    (limn:call "buffer/cursor-set" :|buffer-id| src :|offset| 0)
    (let* ((isr  (limn/isearch:isearch-update
                  (limn/isearch:isearch-start src) "needle"))
           (i-n  (length (limn/isearch:isearch-matches isr)))
           (ocr  (limn/occur:occur src "needle"))
           (o-n  (limn/occur:occur-count ocr)))
      (check (format nil "Ω9a isearch matches = 3 (got ~a)" i-n) (= i-n 3))
      (check (format nil "Ω9b occur count = 3 (got ~a)" o-n)     (= o-n 3))
      (check (format nil "Ω9c counts agree (i=~a, o=~a)" i-n o-n)
             (= i-n o-n))))

  ;;; ── Ω10: isearch *history-push-fn* → *search-history* ──────────────
  (format t "~%── Ω10: isearch-exit pushes to limn/history *search-history* ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "needle haystack")
    ;; Production wire: route push to the built-in *search-history* ring.
    (setf limn/isearch:*history-push-fn*
          (lambda (q) (limn/history:add-to-history '*search-history* q)))
    (let* ((before (limn/history:history-items '*search-history*))
           (st  (limn/isearch:isearch-start bid))
           (st2 (limn/isearch:isearch-update st "needle")))
      (declare (ignorable before))
      (limn/isearch:isearch-exit st2)
      (let ((after (limn/history:history-items '*search-history*)))
        (check (format nil "Ω10 *search-history* contains \"needle\" (items=~s)" after)
               (member "needle" after :test #'equal)))))

  ;;; ── Ω11: isearch-update re-reads buffer after edit ─────────────────
  (format t "~%── Ω11: buffer edit mid-search → update reflects ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "hello world")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (let* ((st  (limn/isearch:isearch-start bid))
           (st2 (limn/isearch:isearch-update st "hello")))
      (check (format nil "Ω11a pre-edit: cursor at 0 (got ~a)" (buf-cursor bid))
             (= (buf-cursor bid) 0))
      ;; Inject 2 chars at the beginning via wire.
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0 :|text| "XY")
      ;; Same query, but text is now "XYhello world" → match at offset 2.
      (let* ((st3 (limn/isearch:isearch-update st2 "hello"))
             (m   (first (limn/isearch:isearch-matches st3))))
        (check (format nil "Ω11b update re-reads text: match start = 2 (got ~s)" m)
               (and m (= (car m) 2)))
        (check (format nil "Ω11c cursor moved to new match offset 2 (got ~a)"
                       (buf-cursor bid))
               (= (buf-cursor bid) 2)))))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; Section D: incremental UX
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω12: growing query shrinks match set ───────────────────────────
  (format t "~%── Ω12: incremental typing ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    ;; "hat hatch hate" has lots of overlapping prefixes.
    (fill-buf bid "hat hatch hate hi")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (let* ((st  (limn/isearch:isearch-start bid))
           (s1  (limn/isearch:isearch-update st  "h"))
           ;; "h" matches at: 0, 4, 6 (in "hatch"), 10, 15 → 5 matches
           (n1  (length (limn/isearch:isearch-matches s1)))
           (s2  (limn/isearch:isearch-update s1  "ha"))
           ;; "ha" matches at: 0, 4, 10 → 3 matches
           (n2  (length (limn/isearch:isearch-matches s2)))
           (s3  (limn/isearch:isearch-update s2  "hat"))
           ;; "hat" matches at: 0, 4, 10 → 3 matches
           (n3  (length (limn/isearch:isearch-matches s3)))
           (s4  (limn/isearch:isearch-update s3  "hate")))
      ;; "hate" matches at: 10 → 1 match
      (declare (ignorable s4))
      (check (format nil "Ω12a \"h\" → 5 matches (got ~a)" n1) (= n1 5))
      (check (format nil "Ω12b \"ha\" → 3 matches (got ~a)" n2) (= n2 3))
      (check (format nil "Ω12c \"hat\" → 3 matches (got ~a)" n3) (= n3 3))
      (check (format nil "Ω12d \"hate\" → 1 match (got ~a)"
                     (length (limn/isearch:isearch-matches s4)))
             (= (length (limn/isearch:isearch-matches s4)) 1))))

  ;;; ── Ω13: switching to no-match mid-session ─────────────────────────
  (format t "~%── Ω13: no-match mid-session, cursor stays ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-isearch-vtable bid)
    (fill-buf bid "alpha beta gamma")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (let* ((st  (limn/isearch:isearch-start bid))
           (s1  (limn/isearch:isearch-update st  "beta"))
           ;; cursor now at 6 (start of "beta")
           (cur-after-match (buf-cursor bid))
           (s2  (limn/isearch:isearch-update s1  "zzzzzz")))
      ;; No matches found. Per module: cursor should NOT change.
      (declare (ignorable s2))
      (check (format nil "Ω13a post-match cursor at 6 (got ~a)" cur-after-match)
             (= cur-after-match 6))
      (check (format nil "Ω13b after no-match update, cursor still 6 (got ~a)"
                     (buf-cursor bid))
             (= (buf-cursor bid) 6))))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
