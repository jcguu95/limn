(in-package :cl-user)
(require :sb-posix)
(format t "~%HOME = ~s~%" (sb-posix:getenv "HOME"))
(let ((d (merge-pathnames ".limn/annotations/" (or (sb-posix:getenv "HOME") "/root/"))))
  (format t "dir pathname = ~s~%" d)
  (format t "namestring = ~a~%" (namestring d))
  (format t "probe-file = ~s~%" (probe-file d))
  (format t "directory glob (merge-pathnames \"*.lisp\" d) = ~s~%"
          (directory (merge-pathnames "*.lisp" d)))
  (format t "directory glob explicit = ~s~%"
          (directory "/root/.limn/annotations/*.lisp")))
(sb-ext:exit :code 0)
