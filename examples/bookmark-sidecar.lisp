;;;; examples/bookmark-sidecar.lisp — dogfood v0.17.0 bookmark/* primitive.
;;;;
;;;; Persists user bookmarks to a sidecar file per PDF (keyed by file
;;;; checksum), proving the "framework doesn't choose persistence"
;;;; philosophy from SPEC §12 v0.17 — user picks: native outline /
;;;; sidecar / hybrid. This example takes the sidecar route.
;;;;
;;;; File format: SBCL-readable plist list, one bookmark per element.
;;;; Example sidecar contents:
;;;;
;;;;   ((:name "intro"  :page 0  :x 0.0 :y 0.0 :note "start here")
;;;;    (:name "ch1"    :page 12 :x 0.0 :y 0.5 :note ""))
;;;;
;;;; Storage path: ~/.limn/bookmarks/<sha256-of-pdf>.lisp
;;;; (sha256 keying means moving the PDF doesn't lose bookmarks).
;;;;
;;;; Usage:
;;;;   (load "examples/bookmark-sidecar.lisp")
;;;;   ;; on buffer-opened: auto-load
;;;;   (limn.examples.bookmark-sidecar:enable-auto-load!)
;;;;   ;; manual:
;;;;   (limn.examples.bookmark-sidecar:save-bookmarks "b1" "/path/to.pdf")
;;;;   (limn.examples.bookmark-sidecar:load-bookmarks "b1" "/path/to.pdf")

(defpackage #:limn.examples.bookmark-sidecar
  (:use #:cl)
  (:export #:save-bookmarks #:load-bookmarks
           #:enable-auto-load! #:disable-auto-load!
           #:sidecar-path))

(in-package #:limn.examples.bookmark-sidecar)

(defun %sha256-of (path)
  "Compute sha256 hex of PATH's contents via shelling out to shasum.
   Returns nil on error (file missing etc.); caller falls back to path."
  (handler-case
      (let* ((out (with-output-to-string (s)
                    (sb-ext:run-program "shasum"
                                         (list "-a" "256" path)
                                         :search t :wait t :output s))))
        (and (plusp (length out))
             (subseq out 0 (or (position #\Space out) 64))))
    (error () nil)))

(defun sidecar-path (pdf-path)
  "~/.limn/bookmarks/<sha256-or-pathname>.lisp"
  (let* ((key (or (%sha256-of pdf-path)
                  ;; fallback: sanitised pathname (replace / with _)
                  (substitute #\_ #\/ pdf-path)))
         (dir (merge-pathnames ".limn/bookmarks/"
                               (user-homedir-pathname))))
    (ensure-directories-exist dir)
    (merge-pathnames (format nil "~a.lisp" key) dir)))

(defun save-bookmarks (buffer-id pdf-path)
  "Pull current user bookmarks from buffer via bookmark/list, write to
   sidecar file as readable s-expr list."
  (let* ((session (symbol-value (find-symbol "*SESSION*" :limn)))
         (call    (find-symbol "CALL" :limn/dispatch))
         (resp    (and session call
                       (funcall call session "bookmark/list"
                                :|buffer-id| buffer-id)))
         (items   (and resp (getf (getf resp :|data|) :|items|)))
         (path    (sidecar-path pdf-path)))
    (with-open-file (s path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (write items :stream s :readably t))
    (format t "saved ~a bookmarks to ~a~%" (length items) path)
    path))

(defun load-bookmarks (buffer-id pdf-path)
  "Read sidecar file and replay each bookmark via bookmark/set into
   BUFFER-ID. Returns count loaded. No-op if sidecar absent."
  (let* ((path    (sidecar-path pdf-path))
         (session (symbol-value (find-symbol "*SESSION*" :limn)))
         (call    (find-symbol "CALL" :limn/dispatch)))
    (cond
      ((not (probe-file path))
       (format t "no sidecar at ~a; starting fresh~%" path)
       0)
      ((not (and session call))
       (format t "no limn session — skipping load~%")
       0)
      (t
       (let* ((items (with-open-file (s path) (read s)))
              (count 0))
         (dolist (b items)
           (handler-case
               (progn
                 (funcall call session "bookmark/set"
                          :|buffer-id| buffer-id
                          :|name|      (getf b :name)
                          :|page|      (getf b :page)
                          :|x|         (or (getf b :x) 0.0)
                          :|y|         (or (getf b :y) 0.0)
                          :|note|      (or (getf b :note) ""))
                 (incf count))
             (error (e)
               (format *error-output*
                       "skipped bookmark ~a: ~a~%" b e))))
         (format t "loaded ~a bookmarks from ~a~%" count path)
         count)))))

(defvar *auto-load-handler* nil)

(defun %on-buffer-opened (ev)
  (let ((bid (getf ev :|buffer-id|))
        ;; SPEC §6 buffer-opened doesn't currently carry :|path|;
        ;; user can stash it or skip auto-load if not available.
        (path (getf ev :|path|)))
    (when (and bid path)
      (load-bookmarks bid path))))

(defun enable-auto-load! ()
  (let ((add (find-symbol "ADD-HOOK" :limn/hooks)))
    (when add
      (setf *auto-load-handler* #'%on-buffer-opened)
      (funcall add "event/buffer-opened" *auto-load-handler*))
    (format t "bookmark sidecar auto-load enabled~%")))

(defun disable-auto-load! ()
  (let ((rem (find-symbol "REMOVE-HOOK" :limn/hooks)))
    (when (and rem *auto-load-handler*)
      (funcall rem "event/buffer-opened" *auto-load-handler*)
      (setf *auto-load-handler* nil))))

;;; Self-test: sidecar path generation works without a real session.
(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  (let ((p (sidecar-path "/tmp/no-such-file.pdf")))
    (assert (pathnamep p) () "sidecar-path returns pathname")
    (assert (search ".limn/bookmarks/" (namestring p))
            "path lives under ~~/.limn/bookmarks/"))
  (format t "bookmark-sidecar self-test ok~%"))
