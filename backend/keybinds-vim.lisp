;;;; keybinds-vim — minimal Vim-flavoured key bindings for limn.
;;;;
;;;; Bindings:
;;;;   h j k l       move (left/down/up/right by *vim-scroll-step* px)
;;;;   + - =         zoom in / out / reset to 1.0
;;;;   C-d / C-u     scroll half page down / up
;;;;   C-f / C-b     scroll full page down / up (next/prev page)
;;;;   gg            jump to first page
;;;;   G             jump to last page
;;;;   5g, 15g       digit-prefix then g → jump to that page
;;;;   /             prompt for search query (reads stdin)
;;;;   n / p         next / prev search match
;;;;
;;;; To activate, after `(limn:start ...)` (which the REPL already does),
;;;; just `(vim/install)`.

(in-package #:cl-user)

;;; ── tunable state ──────────────────────────────────────────────────────

(defvar *vim-win*         "w1"
  "Window id all vim bindings operate on. Override per-session if you want.")
(defvar *vim-scroll-step* 80
  "Pixels moved per h/j/k/l. Tweak to taste.")
(defvar *vim-zoom-step*   1.15
  "Multiplicative zoom factor per +/-.")
(defvar *vim-half-px*     400
  "Pixels offset-y moves per C-d / C-u (vim's 'half-page' analogue).")

;;; ── transient state (digit count + g-prefix) ──────────────────────────

(defvar *vim-count*      0)         ; numeric prefix accumulator
(defvar *vim-pending-g*  nil)       ; t after first g (awaiting second g)

(defun vim/reset-state ()
  (setf *vim-count* 0
        *vim-pending-g* nil))

(defun vim/take-count (&optional (default 1))
  "Consume the numeric prefix (or DEFAULT if none)."
  (let ((n (if (zerop *vim-count*) default *vim-count*)))
    (setf *vim-count* 0)
    n))

;;; ── view I/O helpers ───────────────────────────────────────────────────

(defun vim/state ()
  "Current view state as a plist (or NIL on failure)."
  (let ((r (limn:view-get *vim-win*)))
    (and (limn/bridge:response-ok? r)
         (limn/bridge:response-data r))))

(defun vim/set (&rest fields)
  "view/set on *vim-win* with FIELDS. Logs ok/fail briefly."
  (let ((r (apply #'limn:view-set *vim-win* fields)))
    (unless (limn/bridge:response-ok? r)
      (format t "  ✗ view/set ~a: ~a~%" fields (limn/bridge:response-error r)))
    r))

(defun vim/clamp (val lo hi)
  (max lo (min hi val)))

(defun vim/page-count ()
  (or (let ((s (vim/state)))
        (and s (or (getf s :|page-count|) (getf s :|num-pages|))))
      1))

;;; ── motions ────────────────────────────────────────────────────────────

(defun vim/move (dx dy)
  (setf *vim-pending-g* nil)        ; any motion cancels the g-prefix
  (let* ((s   (vim/state))
         (ox  (or (getf s :|offset-x|) 0))
         (oy  (or (getf s :|offset-y|) 0))
         (n   (vim/take-count 1)))
    (when *vim-debug*
      (format t "  [vim/move] dx=~a dy=~a × ~a~%" dx dy n))
    (vim/set :|offset-x| (+ ox (* dx n))
             :|offset-y| (+ oy (* dy n)))))

;; Note on h/l direction: sioyek's offset-x convention is "how far the page
;; has been panned to the right" — so to make the user SEE more content on
;; the LEFT (vim's "h"), we need to DECREASE the pan, which actually means
;; offset-x decreases. Empirically the previous mapping felt backwards in
;; the real viewer, so we swapped the signs. If your viewer convention is
;; different, just flip these.
(defun vim/left  (_) (declare (ignore _)) (vim/move    *vim-scroll-step*  0))
(defun vim/right (_) (declare (ignore _)) (vim/move (- *vim-scroll-step*) 0))
(defun vim/up    (_) (declare (ignore _)) (vim/move 0 (- *vim-scroll-step*)))
(defun vim/down  (_) (declare (ignore _)) (vim/move 0    *vim-scroll-step*))

;;; ── page-step (C-d / C-u / C-f / C-b) ─────────────────────────────────

(defun vim/page-step (page-delta)
  "Advance/regress by an INTEGER number of pages (delta × count)."
  (setf *vim-pending-g* nil)        ; any page move cancels the g-prefix
  (let* ((s    (vim/state))
         (p    (or (getf s :|page|) 0))
         (last (1- (vim/page-count)))
         (n    (vim/take-count 1))
         (new  (vim/clamp (+ p (* page-delta n)) 0 last)))
    (when *vim-debug*
      (format t "  [vim/page-step] ~a→~a (Δ=~a × ~a)~%" p new page-delta n))
    (vim/set :|page| new)))

;; C-d / C-u : scroll by half a notional page worth of pixels (offset-y).
;; C-f / C-b : advance one full page.
(defun vim/half-down (_) (declare (ignore _)) (vim/move 0    *vim-half-px*))
(defun vim/half-up   (_) (declare (ignore _)) (vim/move 0 (- *vim-half-px*)))
(defun vim/full-down (_) (declare (ignore _)) (vim/page-step  1))
(defun vim/full-up   (_) (declare (ignore _)) (vim/page-step -1))

;;; ── zoom ───────────────────────────────────────────────────────────────

(defun vim/zoom-in    (_) (declare (ignore _))
  (setf *vim-pending-g* nil)
  (let* ((s (vim/state)) (z (or (getf s :|zoom|) 1.0)))
    (vim/set :|zoom| (* z *vim-zoom-step*))))
(defun vim/zoom-out   (_) (declare (ignore _))
  (setf *vim-pending-g* nil)
  (let* ((s (vim/state)) (z (or (getf s :|zoom|) 1.0)))
    (vim/set :|zoom| (/ z *vim-zoom-step*))))
(defun vim/zoom-reset (_) (declare (ignore _))
  (setf *vim-pending-g* nil)
  (vim/set :|zoom| 1.0))

;;; ── jumps (gg / G / 5g) ────────────────────────────────────────────────

(defun vim/jump-page (zero-indexed)
  (let* ((last (1- (vim/page-count)))
         (p    (vim/clamp zero-indexed 0 last)))
    (vim/set :|page| p)))

(defvar *vim-debug* t
  "When true, vim handlers print which branch they take. Default ON until
   the MainWidget viewport is wired to view/set — without that you can't
   see the bindings 'work', so we print so you know they fired.")

(defun vim/g (_)
  "g: if count → jump to page (count-1); else if pending-g → first page;
   else mark pending-g."
  (declare (ignore _))
  (when *vim-debug*
    (format t "  [vim/g] count=~a pending=~a~%" *vim-count* *vim-pending-g*))
  (cond
    ((plusp *vim-count*)
     (let ((target (1- (vim/take-count 1))))
       (when *vim-debug* (format t "    ↳ count branch → ~a~%" target))
       (vim/jump-page target))
     (setf *vim-pending-g* nil))
    (*vim-pending-g*
     (when *vim-debug* (format t "    ↳ pending branch → 0~%"))
     (vim/jump-page 0)
     (setf *vim-pending-g* nil))
    (t
     (when *vim-debug* (format t "    ↳ set-pending branch~%"))
     (setf *vim-pending-g* t))))

;; NOTE: Common Lisp's default reader UPCASES symbols, so vim/g and vim/G
;; collide on the same symbol VIM/G. We call this one `vim/end` to keep
;; them distinct — it still binds to the literal "G" key string.
(defun vim/end (_)
  (declare (ignore _))
  (cond
    ((plusp *vim-count*)
     (vim/jump-page (1- (vim/take-count 1))))
    (t (vim/jump-page (1- (vim/page-count)))))
  (setf *vim-pending-g* nil))

;;; ── digit accumulator ─────────────────────────────────────────────────

(defun vim/push-digit (d)
  (setf *vim-count* (+ (* *vim-count* 10) d))
  (setf *vim-pending-g* nil)
  (format t "  [count] ~a~%" *vim-count*))

;;; ── search ─────────────────────────────────────────────────────────────

(defvar *vim-search-results* '()
  "List of (page . word-index) for current query.")
(defvar *vim-search-index*   0)
(defvar *vim-search-query*   nil)

(defun vim/buffer-id ()
  (getf (vim/state) :|buffer-id|))

(defun vim/search-all (query)
  "Search every page for QUERY, return list of (page . word-idx) tuples."
  (let ((buf (vim/buffer-id))
        (results '()))
    (unless buf (format t "  ✗ no buffer to search~%") (return-from vim/search-all nil))
    (dotimes (p (vim/page-count))
      (let* ((r     (limn:call "buffer/text" :|buffer-id| buf :|page| p))
             (words (and (limn/bridge:response-ok? r)
                         (getf (limn/bridge:response-data r) :|words|))))
        (dolist (m (limn/search:find-matches words query))
          (push (cons p (getf m :|word-index|)) results))))
    (nreverse results)))

(defun vim/search (_)
  "TODO: implement properly via a Qt-side input modal.
   The old implementation tried (read-line *standard-input*) but that
   competes with the SBCL REPL for the same stdin — neither ESC nor RET
   could escape the read because both go to a different reader.

   The right design is: '/' fires an event the frontend listens for, the
   frontend opens an input field, the user types into Qt (with proper ESC
   handling), and the frontend pushes a 'search-query' event back. We
   don't have that wired yet.

   For now this is a no-op stub so you don't get stuck in a broken state.
   Use (vim/search-and-jump \"query\") from the REPL as a workaround."
  (declare (ignore _))
  (format t "  [/] search not yet wired to a Qt input modal.~%")
  (format t "      Use (vim/search-and-jump \"your-query\") from REPL instead.~%"))

(defun vim/search-and-jump (q)
  "Programmatic search: takes Q directly, no terminal prompt.
   Runs the all-pages search, then jumps to first match. n / p still work."
  (when (or (null q) (zerop (length q)))
    (format t "  empty query~%")
    (return-from vim/search-and-jump))
  (setf *vim-search-query*   q
        *vim-search-results* (vim/search-all q)
        *vim-search-index*   0)
  (format t "  ~a hit~:p for ~s~%" (length *vim-search-results*) q)
  (vim/jump-to-current-match))

(defun vim/jump-to-current-match ()
  (when (null *vim-search-results*) (return-from vim/jump-to-current-match))
  (let ((m (nth *vim-search-index* *vim-search-results*)))
    (format t "  [~a/~a] page ~a word ~a~%"
            (1+ *vim-search-index*) (length *vim-search-results*)
            (car m) (cdr m))
    (vim/jump-page (car m))))

(defun vim/next-match (_)
  (declare (ignore _))
  (when *vim-search-results*
    (setf *vim-search-index*
          (mod (1+ *vim-search-index*) (length *vim-search-results*)))
    (vim/jump-to-current-match)))

(defun vim/prev-match (_)
  (declare (ignore _))
  (when *vim-search-results*
    (setf *vim-search-index*
          (mod (1- *vim-search-index*) (length *vim-search-results*)))
    (vim/jump-to-current-match)))

;;; ── installer ──────────────────────────────────────────────────────────

(defun vim/install ()
  "Install all vim bindings on the active global keymap. Also resets any
   stale transient state (count, pending-g) so reinstalling is idempotent."
  (vim/reset-state)
  (limn:bind "h" #'vim/left)
  (limn:bind "j" #'vim/down)
  (limn:bind "k" #'vim/up)
  (limn:bind "l" #'vim/right)

  (limn:bind "+" #'vim/zoom-in)
  (limn:bind "-" #'vim/zoom-out)
  (limn:bind "=" #'vim/zoom-reset)

  (limn:bind "C-d" #'vim/half-down)
  (limn:bind "C-u" #'vim/half-up)
  (limn:bind "C-f" #'vim/full-down)
  (limn:bind "C-b" #'vim/full-up)

  (limn:bind "g" #'vim/g)
  (limn:bind "G" #'vim/end)

  (limn:bind "/" #'vim/search)
  (limn:bind "n" #'vim/next-match)
  (limn:bind "p" #'vim/prev-match)

  ;; Digits 0–9 for numeric prefix.
  (dotimes (n 10)
    (let ((d n))
      (limn:bind (format nil "~a" d)
                 (lambda (_) (declare (ignore _)) (vim/push-digit d)))))

  (format t "  vim bindings installed on win ~s~%" *vim-win*)
  (format t "  hjkl  +/-/=  C-d/u/f/b  gg/G  5g  /n/p~%"))

(defun vim/uninstall ()
  (dolist (s '("h" "j" "k" "l" "+" "-" "="
               "C-d" "C-u" "C-f" "C-b"
               "g" "G" "/" "n" "p"
               "0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
    (limn:unbind s))
  (vim/reset-state)
  (format t "  vim bindings removed~%"))
