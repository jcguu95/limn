;;;; Batch 27: v0.17 bookmark wire primitives — OS-level e2e.
;;;;
;;;; Verifies the full bookmark/* contract end-to-end against the real
;;;; binary (container Xvfb + mupdf fixture), not just Qt-tier mock.
;;;; Mirrors the Qt-tier shape with focus on:
;;;;   - set / get / delete / list round-trip (Ω1)
;;;;   - update via set (upsert, not duplicate) (Ω2)
;;;;   - per-buffer isolation across 2 simultaneously open docs (Ω3)
;;;;   - page validation against real document num_pages (Ω4)
;;;;   - delete + get fails (Ω5)
;;;;   - CJK / non-BMP in name + note (Ω6, regression with v0.16)

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-bm"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;;; ── wrappers ──────────────────────────────────────────────────────────

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun bm-set! (buf name &key (page 0) (x 0.0) (y 0.0) (note ""))
  (limn:call "bookmark/set" :|buffer-id| buf :|name| name
              :|page| page :|x| x :|y| y :|note| note))
(defun bm-get  (buf name) (limn:call "bookmark/get"   :|buffer-id| buf :|name| name))
(defun bm-del! (buf name) (limn:call "bookmark/delete" :|buffer-id| buf :|name| name))
(defun bm-list (buf)     (limn:call "bookmark/list"   :|buffer-id| buf))

;;; ── session ───────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-bm-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-bm.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let ((b (engine-load (b/ "tests/fixtures/test.pdf"))))
    (check (format nil "setup — buffer-id (~a)" b) (stringp b))

;;; ── Ω1: set → get → list → delete full round-trip ───────────────

    (format t "~%── Ω1: full round-trip ──~%")
    (check "Ω1a — set ok"
           (ok? (bm-set! b "intro" :page 0 :note "start here")))
    (let ((d (data (bm-get b "intro"))))
      (check (format nil "Ω1b — get returns stored record (~a)" d)
             (and d (string= (getf d :|name|) "intro")
                    (eql (getf d :|page|) 0)
                    (string= (getf d :|note|) "start here"))))
    (let ((items (getf (data (bm-list b)) :|items|)))
      (check (format nil "Ω1c — list shows 1 entry (got ~a)"
                     (length items))
             (= 1 (length items))))
    (check "Ω1d — delete ok" (ok? (bm-del! b "intro")))
    (check "Ω1e — get after delete fails"
           (not (ok? (bm-get b "intro"))))

;;; ── Ω2: set twice with same name = upsert (no duplicate) ────────

    (format t "~%── Ω2: upsert ──~%")
    (bm-set! b "k" :page 0 :note "first")
    (bm-set! b "k" :page 3 :note "second")
    (let ((items (getf (data (bm-list b)) :|items|))
          (d     (data (bm-get b "k"))))
      (check (format nil "Ω2a — list has 1 entry (got ~a)" (length items))
             (= 1 (length items)))
      (check (format nil "Ω2b — get returns latest (page=~a, note=~s)"
                     (getf d :|page|) (getf d :|note|))
             (and (eql (getf d :|page|) 3)
                  (string= (getf d :|note|) "second"))))
    (bm-del! b "k")

;;; ── Ω3: per-buffer isolation across two docs ────────────────────

    (format t "~%── Ω3: per-buffer isolation ──~%")
    ;; Open same fixture again on w2 to get a fresh buffer-id.
    (limn:call "bridge/win-split" :|win-id| "w1" :|dir| "h")
    (let* ((b2-resp (limn:call "bridge/engine-load"
                                :|engine| "mupdf"
                                :|path| (b/ "tests/fixtures/test.pdf")
                                :|win-id| "w2"))
           (b2 (getf (data b2-resp) :|buffer-id|)))
      (check (format nil "Ω3a — second buffer-id allocated (~a vs ~a)" b b2)
             (and (stringp b2) (not (string= b b2))))
      (bm-set! b  "only-in-A" :page 0)
      (let ((a-items (getf (data (bm-list b))  :|items|))
            (b-items (getf (data (bm-list b2)) :|items|)))
        (check (format nil "Ω3b — bufA has 1 bookmark (~a)" (length a-items))
               (= 1 (length a-items)))
        (check (format nil "Ω3c — bufB has 0 (no leak) (~a)" (length b-items))
               (= 0 (length b-items))))
      (bm-del! b "only-in-A"))

;;; ── Ω4: page validation against real doc ────────────────────────

    (format t "~%── Ω4: page validation (fixture is 6 pages) ──~%")
    (check "Ω4a — set page=0 ok"
           (ok? (bm-set! b "p0" :page 0)))
    (check "Ω4b — set page=5 ok (last)"
           (ok? (bm-set! b "p5" :page 5)))
    (check "Ω4c — set page=-1 rejected"
           (not (ok? (bm-set! b "neg" :page -1))))
    (check "Ω4d — set page=99 rejected"
           (not (ok? (bm-set! b "huge" :page 99))))
    (bm-del! b "p0") (bm-del! b "p5")

;;; ── Ω5: get/delete on unknown name ──────────────────────────────

    (format t "~%── Ω5: unknown-name semantics ──~%")
    (check "Ω5a — get unknown fails"
           (not (ok? (bm-get b "ghost"))))
    (check "Ω5b — delete unknown fails (strict)"
           (not (ok? (bm-del! b "ghost"))))

;;; ── Ω6: CJK + emoji name / note roundtrip ───────────────────────

    (format t "~%── Ω6: CJK / non-BMP fields ──~%")
    (check "Ω6a — set with CJK name + emoji note ok"
           (ok? (bm-set! b "第一章" :page 0 :note "🌟 起點")))
    (let ((d (data (bm-get b "第一章"))))
      (check (format nil "Ω6b — name roundtrips (got ~s)" (getf d :|name|))
             (and d (string= (getf d :|name|) "第一章")))
      (check (format nil "Ω6c — note roundtrips (got ~s)" (getf d :|note|))
             (and d (string= (getf d :|note|) "🌟 起點"))))
    (bm-del! b "第一章"))

    ;; ── summary ─────────────────────────────────────────────────
    (format t "~%~%── bookmark e2e results ──~%")
    (if (null *failures*)
        (format t "✓ ALL CHECKS PASSED~%")
        (progn
          (format t "✗ ~a FAILURE(s):~%" (length *failures*))
          (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
    (limn:stop)
    (sb-ext:process-kill proc 15)
    (sb-ext:process-wait proc)
    (sb-ext:exit :code (if *failures* 1 0)))
