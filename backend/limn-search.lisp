;;;; limn-search — search logic that operates on word lists.
;;;;
;;;; Input: a list of word plists each like (:|text| "hello" :|rect| (...)).
;;;; Output: list of matched plists (same shape, plus :|word-index| and
;;;; optional :|score| for fuzzy).
;;;;
;;;; Three modes: exact (default), regex, fuzzy. Case-insensitive by default
;;;; for exact mode. whole-word optional flag.

(defpackage #:limn/search
  (:use #:cl)
  (:export #:find-matches
           #:make-search-state #:next-result #:prev-result
           #:current-result #:state-p))

(in-package #:limn/search)

(defun string-contains (needle haystack &key case-sensitive)
  (let ((n (if case-sensitive needle    (string-downcase needle)))
        (h (if case-sensitive haystack  (string-downcase haystack))))
    (search n h)))

(defun whole-word-equal (a b &key case-sensitive)
  (let ((a1 (if case-sensitive a (string-downcase a)))
        (b1 (if case-sensitive b (string-downcase b))))
    (string= a1 b1)))

;;; ── find-matches ───────────────────────────────────────────────────────

(defun find-matches (words query &key case-sensitive regex fuzzy whole-word
                                       (emacs-syntax t))
  (when (or (null query) (zerop (length query)))
    (return-from find-matches nil))
  (cond
    (fuzzy   (fuzzy-find-matches    words query :case-sensitive case-sensitive))
    (regex   (regex-find-matches    words query
                                    :case-sensitive case-sensitive
                                    :emacs-syntax emacs-syntax))
    (whole-word (whole-word-find-matches words query :case-sensitive case-sensitive))
    (t       (exact-find-matches    words query :case-sensitive case-sensitive))))

(defun exact-find-matches (words query &key case-sensitive)
  "Phrase search: query may contain multiple words separated by space.
   Single-word query matches as substring."
  (let ((parts (split-on-space query)))
    (cond
      ((= (length parts) 1)
       (loop for w in words
             for i from 0
             when (string-contains query (getf w :|text|)
                                   :case-sensitive case-sensitive)
               collect (list* :|word-index| i w)))
      (t
       (phrase-find-matches words parts :case-sensitive case-sensitive)))))

(defun whole-word-find-matches (words query &key case-sensitive)
  (loop for w in words
        for i from 0
        when (whole-word-equal query (getf w :|text|) :case-sensitive case-sensitive)
          collect (list* :|word-index| i w)))

(defun phrase-find-matches (words parts &key case-sensitive)
  "Match consecutive words against the phrase parts."
  (let ((out '())
        (n (length parts))
        (arr (coerce words 'vector)))
    (loop for i from 0 to (- (length arr) n)
          when (loop for j from 0 below n
                      always (whole-word-equal
                              (nth j parts)
                              (getf (aref arr (+ i j)) :|text|)
                              :case-sensitive case-sensitive))
            do (push (list* :|word-index| i :|start| i :|end| (+ i n -1)
                             (aref arr i)) out))
    (nreverse out)))

(defun regex-find-matches (words pattern &key case-sensitive (emacs-syntax t))
  "v0.34: prefer cl-ppcre when available, with optional Emacs→PCRE
   translation. Falls back to the v0.27 tiny-regex if cl-ppcre / limn/regex
   are not loaded (keeps the module usable in minimal images).
   cl-ppcre symbols are resolved via find-symbol so this file compiles in
   minimal images without the vendor submodule."
  (let* ((rpkg (find-package '#:limn/regex))
         (ppkg (find-package '#:cl-ppcre))
         (translate (and emacs-syntax rpkg
                         (find-symbol "EMACS-REGEX-TO-PCRE" rpkg)))
         (effective-pattern (if (and translate (fboundp translate))
                                (funcall translate pattern)
                                pattern))
         (create-scanner (and ppkg (find-symbol "CREATE-SCANNER" ppkg)))
         (scan           (and ppkg (find-symbol "SCAN" ppkg))))
    (cond
      ((and create-scanner scan (fboundp create-scanner) (fboundp scan))
       (let ((scanner
               (funcall create-scanner
                        effective-pattern
                        :case-insensitive-mode (not case-sensitive))))
         (loop for w in words
               for i from 0
               when (funcall scan scanner (or (getf w :|text|) ""))
                 collect (list* :|word-index| i w))))
      (t
       ;; Fallback (cl-ppcre missing). case-sensitive is silently ignored
       ;; by the tiny-regex impl — kept as parameter for API parity.
       (loop for w in words
             for i from 0
             when (tiny-regex-match pattern (getf w :|text|))
               collect (list* :|word-index| i w))))))

(defun tiny-regex-match (pattern text)
  "Toy regex: handles ^...$ anchors, [chars] character classes, literal chars.
   Just enough for our test cases like '^[Tt]he$' and '[aeiou]ver'."
  (let ((anchored-start (and (>= (length pattern) 1) (char= (char pattern 0) #\^)))
        (anchored-end   (and (>= (length pattern) 1)
                              (char= (char pattern (1- (length pattern))) #\$)))
        (p pattern))
    (when anchored-start (setf p (subseq p 1)))
    (when anchored-end   (setf p (subseq p 0 (1- (length p)))))
    (let* ((parsed-pattern (parse-tiny-pattern p))
           (text-len       (length text))
           (start-positions (if anchored-start '(0) (loop for i from 0 to text-len collect i))))
      (some (lambda (start)
              (multiple-value-bind (matched end)
                  (try-match parsed-pattern text start)
                (and matched
                     (or (not anchored-end) (= end text-len)))))
            start-positions))))

(defun parse-tiny-pattern (p)
  "Parses pattern into a list of atoms:
     (:char #\X), (:class \"aeiou\")."
  (let ((result '())
        (i 0))
    (loop while (< i (length p))
          do (cond
               ((char= (char p i) #\[)
                (let ((end (position #\] p :start i)))
                  (when end
                    (push (list :class (subseq p (1+ i) end)) result)
                    (setf i (1+ end)))))
               (t (push (list :char (char p i)) result)
                  (incf i))))
    (nreverse result)))

(defun try-match (parsed text start)
  (let ((pos start))
    (dolist (atom parsed)
      (when (>= pos (length text)) (return-from try-match (values nil pos)))
      (case (first atom)
        (:char
         (unless (char= (second atom) (char text pos))
           (return-from try-match (values nil pos))))
        (:class
         (unless (find (char text pos) (second atom))
           (return-from try-match (values nil pos)))))
      (incf pos))
    (values t pos)))

(defun fuzzy-find-matches (words query &key case-sensitive)
  (declare (ignore case-sensitive))
  "Simple fuzzy: count subsequence matches. Returns hits with :|score|."
  (when (or (null query) (zerop (length query))) (return-from fuzzy-find-matches nil))
  (loop for w in words
        for i from 0
        for score = (fuzzy-score (string-downcase query)
                                  (string-downcase (or (getf w :|text|) "")))
        when (> score 0)
          collect (list* :|word-index| i :|score| score w)))

(defun fuzzy-score (q txt)
  "Cheap fuzzy: each query char must appear in order in target. Score is
   the ratio of matched query chars to target length (higher = better)."
  (let ((qi 0) (matched 0))
    (loop for ch across txt
          while (< qi (length q))
          when (char= ch (char q qi))
            do (incf qi) (incf matched))
    (cond
      ((zerop (length q)) 0)
      ((< qi (length q)) 0)
      (t (/ matched (max 1 (length txt)))))))

(defun split-on-space (s)
  (loop with start = 0
        with result = '()
        for i from 0 below (length s)
        when (char= (char s i) #\Space)
          do (when (> i start) (push (subseq s start i) result))
             (setf start (1+ i))
        finally (when (> (length s) start) (push (subseq s start) result))
                (return (nreverse result))))

;;; ── search state navigation ────────────────────────────────────────────

(defstruct state
  query
  mode
  results
  (index 0))

(defun make-search-state (&rest args
                          &key |query| |mode| |results|
                          &allow-other-keys)
  (declare (ignorable args))
  (make-state :query |query| :mode |mode| :results |results| :index 0))

(defun current-result (s)
  (let ((rs (state-results s)))
    (when rs (nth (mod (state-index s) (length rs)) rs))))

(defun next-result (s)
  (let ((rs (state-results s)))
    (when rs (setf (state-index s) (mod (1+ (state-index s)) (length rs))))
    (current-result s)))

(defun prev-result (s)
  (let ((rs (state-results s)))
    (when rs (setf (state-index s) (mod (1- (state-index s)) (length rs))))
    (current-result s)))
