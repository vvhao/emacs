;;; nnmaildir.el --- maildir backend for Gnus  -*- lexical-binding:t -*-

;; This file is in the public domain.

;; Author: Paul Jarc <prj@po.cwru.edu>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Maildir format is documented at <URL:https://cr.yp.to/proto/maildir.html>.
;; nnmaildir also stores extra information in the .nnmaildir/ directory
;; within a maildir.
;;
;; Some goals of nnmaildir:
;; * Everything Just Works, and correctly.  E.g., NOV data is automatically
;;   regenerated when stale; no need for manually running
;;   *-generate-nov-databases.
;; * Perfect reliability: [C-g] will never corrupt its data in memory, and
;;   SIGKILL will never corrupt its data in the filesystem.
;; * Allow concurrent operation as much as possible.  If files change out
;;   from under us, adapt to the changes or degrade gracefully.
;; * We use the filesystem as a database, so that, e.g., it's easy to
;;   manipulate marks from outside Gnus.
;; * All information about a group is stored in the maildir, for easy backup,
;;   copying, restoring, etc.
;;
;; Todo:
;; * When moving an article for expiry, copy all the marks except 'expire
;;   from the original article.
;; * Add a hook for when moving messages from new/ to cur/, to support
;;   nnmail's duplicate detection.
;; * Improve generated Xrefs, so crossposts are detectable.
;; * Improve code readability.

;;; Code:

(require 'nnheader)
(require 'gnus)
(require 'gnus-util)
(require 'gnus-range)
(require 'gnus-start)
(require 'gnus-int)
(require 'message)
(require 'nnmail)

(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))

(defconst nnmaildir-version "Gnus")
(make-obsolete-variable 'nnmaildir-version 'emacs-version "29.1")

(defconst nnmaildir-flag-mark-mapping
  '((?F . tick)
    (?P . forward)
    (?R . reply)
    (?S . read))
  "Alist mapping Maildir filename flags to Gnus marks.
Maildir filenames are of the form \"unique-id:2,FLAGS\",
where FLAGS are a string of characters in ASCII order.
Some of the FLAGS correspond to Gnus marks.")

(defsubst nnmaildir--mark-to-flag (mark)
  "Find the Maildir flag that corresponds to MARK (an atom).
Return a character, or nil if not found.
See `nnmaildir-flag-mark-mapping'."
  (car (rassq mark nnmaildir-flag-mark-mapping)))

(defsubst nnmaildir--flag-to-mark (flag)
  "Find the Gnus mark that corresponds to FLAG (a character).
Return an atom, or nil if not found.
See `nnmaildir-flag-mark-mapping'."
  (cdr (assq flag nnmaildir-flag-mark-mapping)))

(defun nnmaildir--ensure-suffix (filename)
  "Ensure that FILENAME contains the suffix \":2,\"."
  (if (string-search ":2," filename)
      filename
    (concat filename ":2,")))

(defun nnmaildir--add-flag (flag suffix)
  "Return a copy of SUFFIX where FLAG is set.
SUFFIX should start with \":2,\"."
  (unless (string-match-p "^:2," suffix)
    (error "Invalid suffix `%s'" suffix))
  (let* ((flags (substring suffix 3))
	 (flags-as-list (append flags nil))
	 (new-flags
          (concat (seq-uniq
		   ;; maildir flags must be sorted
		   (sort (cons flag flags-as-list) #'<)))))
    (concat ":2," new-flags)))

(defun nnmaildir--remove-flag (flag suffix)
  "Return a copy of SUFFIX where FLAG is cleared.
SUFFIX should start with \":2,\"."
  (unless (string-match-p "^:2," suffix)
    (error "Invalid suffix `%s'" suffix))
  (let* ((flags (substring suffix 3))
	 (flags-as-list (append flags nil))
	 (new-flags (concat (delq flag flags-as-list))))
    (concat ":2," new-flags)))

(defvar nnmaildir-article-file-name nil
  "The filename of the most recently requested article.
This variable is set by `nnmaildir-request-article'.")

;; The filename of the article being moved/copied:
(defvar nnmaildir--file nil)

;; Variables to generate filenames of messages being delivered:
(defvar   nnmaildir--delivery-time "")
(defconst nnmaildir--delivery-pid (concat "P" (number-to-string (emacs-pid))))
(defvar   nnmaildir--delivery-count nil)

(defvar nnmaildir--servers nil
  "Alist mapping server name strings to servers.")
(defvar nnmaildir--cur-server nil
  "The current server.")

;; A copy of nnmail-extra-headers
(defvar nnmaildir--extra nil)

;; A NOV structure looks like this (must be prin1-able, so no defstruct):
["subject\tfrom\tdate"
 "references\tchars\tlines"
 "To: you\tIn-Reply-To: <your.mess@ge>"
 (12345 67890)     ;; modtime of the corresponding article file
 (to in-reply-to)] ;; contemporary value of nnmail-extra-headers
(defconst nnmaildir--novlen 5)
(defmacro nnmaildir--nov-new (beg mid end mtime extra)
  `(vector ,beg ,mid ,end ,mtime ,extra))
(defmacro nnmaildir--nov-get-beg   (nov) `(aref ,nov 0))
(defmacro nnmaildir--nov-get-mid   (nov) `(aref ,nov 1))
(defmacro nnmaildir--nov-get-end   (nov) `(aref ,nov 2))
(defmacro nnmaildir--nov-get-mtime (nov) `(aref ,nov 3))
(defmacro nnmaildir--nov-get-extra (nov) `(aref ,nov 4))
(defmacro nnmaildir--nov-set-beg   (nov value) `(aset ,nov 0 ,value))
(defmacro nnmaildir--nov-set-mid   (nov value) `(aset ,nov 1 ,value))
(defmacro nnmaildir--nov-set-end   (nov value) `(aset ,nov 2 ,value))
(defmacro nnmaildir--nov-set-mtime (nov value) `(aset ,nov 3 ,value))
(defmacro nnmaildir--nov-set-extra (nov value) `(aset ,nov 4 ,value))

(cl-defstruct nnmaildir--art
  (prefix nil :type string)  ;; "time.pid.host"
  (suffix nil :type string)  ;; ":2,flags"
  (num    nil :type natnum)  ;; article number
  (msgid  nil :type string)  ;; "<mess.age@id>"
  (nov    nil :type vector)) ;; cached nov structure, or nil

(cl-defstruct nnmaildir--grp
  (name  nil :type string)	;; "group.name"
  (new   nil :type list)	;; new/ modtime
  (cur   nil :type list)	;; cur/ modtime
  (min   1   :type natnum)	;; minimum article number
  (count 0   :type natnum)	;; count of articles
  (nlist nil :type list)	;; list of articles, ordered descending by number
  (flist nil :type hash-table)  ;; hash table mapping filename prefix->article
  (mlist nil :type hash-table)  ;; hash table mapping message-id->article
  (cache nil :type vector)	;; nov cache
  (index nil :type natnum)	;; index of next cache entry to replace
  (mmth  nil :type hash-table))	;; hash table mapping mark name->dir modtime
					; ("Mark Mod Time Hash")

(cl-defstruct nnmaildir--srv
  (address    	 nil :type string)         ;; server address string
  (method     	 nil :type list)           ;; (nnmaildir "address" ...)
  (prefix     	 nil :type string)         ;; "nnmaildir+address:"
  (dir        	 nil :type string)         ;; "/expanded/path/to/server/dir/"
  (ls         	 nil :type function)       ;; directory-files function
  (groups     	 nil :type hash-table)     ;; hash table mapping group name->group
  (curgrp     	 nil :type nnmaildir--grp) ;; current group, or nil
  (error      	 nil :type string)         ;; last error message, or nil
  (mtime      	 nil :type list)           ;; modtime of dir
  (gnm        	 nil)                      ;; flag: split from mail-sources?
  (target-prefix nil :type string))        ;; symlink target prefix

(defun nnmaildir--article-set-flags (article new-suffix curdir)
  (let* ((prefix (nnmaildir--art-prefix article))
	 (suffix (nnmaildir--art-suffix article))
	 (article-file (concat curdir prefix suffix))
	 (new-name (concat curdir prefix new-suffix)))
    (unless (file-exists-p article-file)
      (let ((possible (file-expand-wildcards (concat curdir prefix "*"))))
	(cond ((length= possible 1)
	       (unless (string-match-p "\\`\\(.+\\):2,.*?\\'" (car possible))
		 (error "Couldn't find updated article file %s" article-file))
	       (setq article-file (car possible)))
	      ((length> possible 1)
	       (error "Couldn't determine exact article file %s" article-file))
	      ((null possible)
	       (error "Couldn't find article file %s" article-file)))))
    (rename-file article-file new-name 'replace)
    (setf (nnmaildir--art-suffix article) new-suffix)))

(defun nnmaildir--expired-article (group article)
  (setf (nnmaildir--art-nov article) nil)
  (let ((flist  (nnmaildir--grp-flist group))
	(mlist  (nnmaildir--grp-mlist group))
	(min    (nnmaildir--grp-min   group))
	(count  (1- (nnmaildir--grp-count group)))
	(prefix (nnmaildir--art-prefix article))
	(msgid  (nnmaildir--art-msgid  article))
	(new-nlist nil)
	(nlist-pre '(nil . nil))
	nlist-post num)
    (unless (zerop count)
      (setq nlist-post (nnmaildir--grp-nlist group)
	    num (nnmaildir--art-num article))
      (if (eq num (caar nlist-post))
	  (setq new-nlist (cdr nlist-post))
	(setq new-nlist nlist-post
	      nlist-pre nlist-post
	      nlist-post (cdr nlist-post))
	(while (/= num (caar nlist-post))
	  (setq nlist-pre nlist-post
		nlist-post (cdr nlist-post)))
	(setq nlist-post (cdr nlist-post))
	(if (eq num min)
	    (setq min (caar nlist-pre)))))
    (let ((inhibit-quit t))
      (setf (nnmaildir--grp-min   group) min)
      (setf (nnmaildir--grp-count group) count)
      (setf (nnmaildir--grp-nlist group) new-nlist)
      (setcdr nlist-pre nlist-post)
      (remhash prefix flist)
      (remhash msgid mlist))))

(defun nnmaildir--nlist-art (group num)
  (let ((entry (assq num (nnmaildir--grp-nlist group))))
    (if entry
	(cdr entry))))
(defmacro nnmaildir--flist-art (list file)
  `(gethash ,file ,list))
(defmacro nnmaildir--mlist-art (list msgid)
  `(gethash ,msgid ,list))

(defun nnmaildir--pgname (server gname)
  (let ((prefix (nnmaildir--srv-prefix server)))
    (if prefix (concat prefix gname)
      (setq gname (gnus-group-prefixed-name gname
					    (nnmaildir--srv-method server)))
      (setf (nnmaildir--srv-prefix server) (gnus-group-real-prefix gname))
      gname)))

(defun nnmaildir--param (pgname param)
  (setq param (gnus-group-find-parameter pgname param 'allow-list))
  (if (vectorp param) (setq param (aref param 0)))
  (eval param t))

(defmacro nnmaildir--with-nntp-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-current-buffer nntp-server-buffer
     ,@body))
(defmacro nnmaildir--with-work-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-current-buffer (gnus-get-buffer-create " *nnmaildir work*")
     ,@body))
(defmacro nnmaildir--with-nov-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-current-buffer (gnus-get-buffer-create " *nnmaildir nov*")
     ,@body))
(defmacro nnmaildir--with-move-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-current-buffer (gnus-get-buffer-create " *nnmaildir move*")
     ,@body))

(defsubst nnmaildir--subdir (dir subdir)
  (file-name-as-directory (concat dir subdir)))
(defsubst nnmaildir--srvgrp-dir (srv-dir gname)
  (nnmaildir--subdir srv-dir gname))
(defsubst nnmaildir--tmp       (dir) (nnmaildir--subdir dir "tmp"))
(defsubst nnmaildir--new       (dir) (nnmaildir--subdir dir "new"))
(defsubst nnmaildir--cur       (dir) (nnmaildir--subdir dir "cur"))
(defsubst nnmaildir--nndir     (dir) (nnmaildir--subdir dir ".nnmaildir"))
(defsubst nnmaildir--nov-dir   (dir) (nnmaildir--subdir dir "nov"))
(defsubst nnmaildir--marks-dir (dir) (nnmaildir--subdir dir "marks"))
(defsubst nnmaildir--num-dir   (dir) (nnmaildir--subdir dir "num"))

(defmacro nnmaildir--unlink (file-arg)
  `(let ((file ,file-arg))
     (if (file-attributes file) (delete-file file))))
(defun nnmaildir--mkdir (dir)
  (or (file-exists-p (file-name-as-directory dir))
      (make-directory (directory-file-name dir))))
(defun nnmaildir--mkfile (file)
  (write-region "" nil file nil 'no-message))
(defun nnmaildir--delete-dir-files (dir ls)
  (when (file-attributes dir)
    (mapc #'delete-file (funcall ls dir 'full "\\`[^.]" 'nosort))
    (delete-directory dir)))

(defun nnmaildir--group-maxnum (server group)
  (catch 'return
    (if (zerop (nnmaildir--grp-count group)) (throw 'return 0))
    (let ((dir (nnmaildir--srvgrp-dir (nnmaildir--srv-dir server)
				    (nnmaildir--grp-name group)))
	  (number-opened 1)
	  attr ino-opened nlink number-linked)
      (setq dir (nnmaildir--nndir dir)
	    dir (nnmaildir--num-dir dir))
      (while t
	(setq attr (file-attributes
		    (concat dir (number-to-string number-opened))))
	(or attr (throw 'return (1- number-opened)))
	(setq ino-opened (file-attribute-inode-number attr)
	      nlink (file-attribute-link-number attr)
	      number-linked (+ number-opened nlink))
	(setq attr (file-attributes
		    (concat dir (number-to-string number-linked))))
	(or attr (throw 'return (1- number-linked)))
	(unless (equal ino-opened (file-attribute-inode-number attr))
	  (setq number-opened number-linked))))))

;; Make the given server, if non-nil, be the current server.  Then make the
;; given group, if non-nil, be the current group of the current server.  Then
;; return the group object for the current group.
(defun nnmaildir--prepare (server group)
  (catch 'return
    (if (null server)
	(unless (setq server nnmaildir--cur-server)
	  (throw 'return nil))
      (unless (setq server (alist-get server nnmaildir--servers
				      nil nil #'equal))
	(throw 'return nil))
      (setq nnmaildir--cur-server server))
    (let ((groups (nnmaildir--srv-groups server)))
      (when (and groups (null (hash-table-empty-p groups)))
	(unless (nnmaildir--srv-method server)
	  (setf (nnmaildir--srv-method server)
		(or (gnus-server-to-method
		     (concat "nnmaildir:" (nnmaildir--srv-address server)))
		    (throw 'return nil))))
	(if (null group)
	    (nnmaildir--srv-curgrp server)
	  (gethash group groups))))))

(defun nnmaildir--tab-to-space (string)
  (let ((pos 0))
    (while (string-match "\t" string pos)
      (aset string (match-beginning 0) ? )
      (setq pos (match-end 0))))
  string)

(defmacro nnmaildir--condcase (errsym body &rest handler)
  (declare (indent 2) (debug (sexp form body)))
  `(condition-case ,errsym
       (let ((system-messages-locale "C")) ,body)
     (error . ,handler)))

(defun nnmaildir--emlink-p (err)
  (and (eq (car err) 'file-error)
       (string= (downcase (caddr err)) "too many links")))

(defun nnmaildir--enoent-p (err)
  (eq (car err) 'file-missing))

(defun nnmaildir--eexist-p (err)
  (eq (car err) 'file-already-exists))

(defun nnmaildir--new-number (nndir)
  "Allocate a new article number by atomically creating a file under NNDIR."
  (let ((numdir (nnmaildir--num-dir nndir))
	(make-new-file t)
	(number-open 1)
	number-link previous-number-link path-open path-link ino-open)
    (nnmaildir--mkdir numdir)
    (catch 'return
      (while t
	(setq path-open (concat numdir (number-to-string number-open)))
	(if (not make-new-file)
	    (setq previous-number-link number-link)
	  (nnmaildir--mkfile path-open)
	  ;; If Emacs had O_CREAT|O_EXCL, we could return number-open here.
	  (setq make-new-file nil
		previous-number-link 0))
	(let* ((attr (file-attributes path-open))
	       (nlink (file-attribute-link-number attr)))
	  (setq ino-open (file-attribute-inode-number attr)
		number-link (+ number-open nlink)))
	(if (= number-link previous-number-link)
	    ;; We've already tried this number, in the previous loop iteration,
	    ;; and failed.
	    (signal 'error `("Corrupt internal nnmaildir data" ,path-open)))
	(setq path-link (concat numdir (number-to-string number-link)))
	(nnmaildir--condcase err
	    (progn
	      (add-name-to-file path-open path-link)
	      (throw 'return number-link))
	  (cond
	   ((nnmaildir--emlink-p err)
	    (setq make-new-file t
		  number-open number-link))
	   ((nnmaildir--eexist-p err)
	    (let ((attr (file-attributes path-link)))
	      (unless (equal (file-attribute-inode-number attr) ino-open)
		(setq number-open number-link
		      number-link 0))))
	   (t (signal (car err) (cdr err)))))))))

(defun nnmaildir--update-nov (server group article)
  (let ((nnheader-file-coding-system 'undecided)
	(srv-dir (nnmaildir--srv-dir server))
	(storage-version 1) ;; [version article-number msgid [...nov...]]
	dir gname pgname msgdir prefix suffix file attr mtime novdir novfile
	nov msgid nov-beg nov-mid nov-end field val old-extra num
	deactivate-mark)
    (catch 'return
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname server gname)
	    dir (nnmaildir--srvgrp-dir srv-dir gname)
	    msgdir (if (nnmaildir--param pgname 'read-only)
		       (nnmaildir--new dir) (nnmaildir--cur dir))
	    prefix (nnmaildir--art-prefix article)
	    suffix (nnmaildir--art-suffix article)
	    file (concat msgdir prefix suffix)
	    attr (file-attributes file))
      (unless attr
	(nnmaildir--expired-article group article)
	(throw 'return nil))
      (setq mtime (file-attribute-modification-time attr)
	    attr (file-attribute-size attr)
	    nov (nnmaildir--art-nov article)
	    dir (nnmaildir--nndir dir)
	    novdir (nnmaildir--nov-dir dir)
	    novfile (concat novdir prefix))
      (unless (equal nnmaildir--extra nnmail-extra-headers)
	(setq nnmaildir--extra (copy-sequence nnmail-extra-headers)))
      (nnmaildir--with-nov-buffer
	;; First we'll check for already-parsed NOV data.
	(cond ((not (file-exists-p novfile))
	       ;; The NOV file doesn't exist; we have to parse the message.
	       (setq nov nil))
	      ((not nov)
	       ;; The file exists, but the data isn't in memory; read the file.
	       (erase-buffer)
	       (nnheader-insert-file-contents novfile)
	       (setq nov (read (current-buffer)))
	       (if (not (and (vectorp nov)
			     (/= 0 (length nov))
			     (equal storage-version (aref nov 0))))
		   ;; This NOV data seems to be in the wrong format.
		   (setq nov nil)
		 (unless (nnmaildir--art-num   article)
		   (setf (nnmaildir--art-num   article) (aref nov 1)))
		 (unless (nnmaildir--art-msgid article)
		   (setf (nnmaildir--art-msgid article) (aref nov 2)))
		 (setq nov (aref nov 3)))))
	;; Now check whether the already-parsed data (if we have any) is
	;; usable: if the message has been edited or if nnmail-extra-headers
	;; has been augmented since this data was parsed from the message,
	;; then we have to reparse.  Otherwise it's up-to-date.
	(when (and nov (time-equal-p mtime (nnmaildir--nov-get-mtime nov)))
	  ;; The timestamp matches.  Now check nnmail-extra-headers.
	  (setq old-extra (nnmaildir--nov-get-extra nov))
	  (when (equal nnmaildir--extra old-extra) ;; common case
	    ;; Save memory; use a single copy of the list value.
	    (nnmaildir--nov-set-extra nov nnmaildir--extra)
	    (throw 'return nov))
	  ;; They're not equal, but maybe the new is a subset of the old.
	  (if (null nnmaildir--extra)
	      ;; The empty set is a subset of every set.
	      (throw 'return nov))
	  (if (not (memq nil (mapcar (lambda (e) (memq e old-extra))
				     nnmaildir--extra)))
	      (throw 'return nov)))
	;; Parse the NOV data out of the message.
	(erase-buffer)
	(nnheader-insert-file-contents file)
	(insert "\n")
	(goto-char (point-min))
	(save-restriction
	  (if (search-forward "\n\n" nil 'noerror)
	      (progn
		(setq nov-mid (count-lines (point) (point-max)))
		(narrow-to-region (point-min) (1- (point))))
	    (setq nov-mid 0))
	  (goto-char (point-min))
	  (delete-char 1)
	  (setq nov (nnheader-parse-head t)
		field (or (mail-header-lines nov) 0)))
	(unless (or (<= field 0) (nnmaildir--param pgname 'distrust-Lines:))
	  (setq nov-mid field))
	(setq nov-mid (number-to-string nov-mid)
	      nov-mid (concat (number-to-string attr) "\t" nov-mid))
	(save-match-data
	  (setq field (or (mail-header-references nov) ""))
	  (nnmaildir--tab-to-space field)
	  (setq nov-mid (concat field "\t" nov-mid)
		nov-beg (mapconcat
			  (lambda (f) (nnmaildir--tab-to-space (or f "")))
			  (list (mail-header-subject nov)
				(mail-header-from nov)
				(mail-header-date nov)) "\t")
		nov-end (mapconcat
			  (lambda (extra)
			    (setq field (symbol-name (car extra))
				  val (cdr extra))
			    (nnmaildir--tab-to-space field)
			    (nnmaildir--tab-to-space val)
			    (concat field ": " val))
			  (mail-header-extra nov) "\t")))
	(setq msgid (mail-header-id nov))
	(if (or (null msgid) (nnheader-fake-message-id-p msgid))
	    (setq msgid (concat "<" prefix "@nnmaildir>")))
	(nnmaildir--tab-to-space msgid)
	;; The data is parsed; create an nnmaildir NOV structure.
	(setq nov (nnmaildir--nov-new nov-beg nov-mid nov-end mtime
				      nnmaildir--extra)
	      num (nnmaildir--art-num article))
	(unless num
	  (setq num (nnmaildir--new-number dir))
	  (setf (nnmaildir--art-num article) num))
	;; Store this new NOV data in a file
	(erase-buffer)
	(prin1 (vector storage-version num msgid nov) (current-buffer))
	(setq file (concat novfile ":"))
	(nnmaildir--unlink file)
	(write-region (point-min) (point-max) file nil 'no-message nil
		      'excl))
      (rename-file file novfile 'replace)
      (setf (nnmaildir--art-msgid article) msgid)
      nov)))

(defun nnmaildir--cache-nov (group article nov)
  (let ((cache (nnmaildir--grp-cache group))
	(index (nnmaildir--grp-index group))
	goner)
    (unless (nnmaildir--art-nov article)
      (setq goner (aref cache index))
      (if goner (setf (nnmaildir--art-nov goner) nil))
      (aset cache index article)
      (setf (nnmaildir--grp-index group) (% (1+ index) (length cache))))
    (setf (nnmaildir--art-nov article) nov)))

(defun nnmaildir--grp-add-art (server group article)
  (let ((nov (nnmaildir--update-nov server group article))
	count num min nlist nlist-cdr insert-nlist)
    (when nov
      (setq count (1+ (nnmaildir--grp-count group))
	    num (nnmaildir--art-num article)
	    min (if (= count 1) num
		  (min num (nnmaildir--grp-min group)))
	    nlist (nnmaildir--grp-nlist group))
      (if (or (null nlist) (> num (caar nlist)))
	  (setq nlist (cons (cons num article) nlist))
	(setq insert-nlist t
	      nlist-cdr (cdr nlist))
	(while (and nlist-cdr (< num (caar nlist-cdr)))
	  (setq nlist nlist-cdr
		nlist-cdr (cdr nlist))))
      (let ((inhibit-quit t))
	(setf (nnmaildir--grp-count group) count)
	(setf (nnmaildir--grp-min group) min)
	(if insert-nlist
	    (setcdr nlist (cons (cons num article) nlist-cdr))
	  (setf (nnmaildir--grp-nlist group) nlist))
	(puthash (nnmaildir--art-prefix article)
		 article
		 (nnmaildir--grp-flist group))
	(puthash (nnmaildir--art-msgid article)
		 article
		 (nnmaildir--grp-mlist group))
	(puthash (nnmaildir--grp-name group)
		 group
		 (nnmaildir--srv-groups server)))
      (nnmaildir--cache-nov group article nov)
      t)))

(defun nnmaildir--group-ls (server pgname)
  (or (nnmaildir--param pgname 'directory-files)
      (nnmaildir--srv-ls server)))

(defun nnmaildir-article-number-to-file-name
  (number group-name server-address-string)
  (let ((group (nnmaildir--prepare server-address-string group-name))
	article dir pgname)
    (catch 'return
      (unless group
	;; The given group or server does not exist.
	(throw 'return nil))
      (setq article (nnmaildir--nlist-art group number))
      (unless article
	;; The given article number does not exist in this group.
	(throw 'return nil))
      (setq pgname (nnmaildir--pgname nnmaildir--cur-server group-name)
	    dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir group-name)
	    dir (if (nnmaildir--param pgname 'read-only)
		    (nnmaildir--new dir) (nnmaildir--cur dir)))
      (concat dir (nnmaildir--art-prefix article)
	      (nnmaildir--art-suffix article)))))

(defun nnmaildir-article-number-to-base-name
  (number group-name server-address-string)
  (let ((x (nnmaildir--prepare server-address-string group-name)))
    (when x
      (setq x (nnmaildir--nlist-art x number))
      (and x (cons (nnmaildir--art-prefix x)
		   (nnmaildir--art-suffix x))))))

(defun nnmaildir-base-name-to-article-number
  (base-name group-name server-address-string)
  (let ((x (nnmaildir--prepare server-address-string group-name)))
    (when x
      (setq x (nnmaildir--grp-flist x)
	    x (nnmaildir--flist-art x base-name))
      (and x (nnmaildir--art-num x)))))

(defun nnmaildir--nlist-iterate (nlist ranges func)
  (let (entry high low nlist2)
    (if (eq ranges 'all)
	(setq ranges `((1 . ,(caar nlist)))))
    (while ranges
      (setq entry (car ranges) ranges (cdr ranges))
      (while (and ranges (eq entry (car ranges)))
	(setq ranges (cdr ranges))) ;; skip duplicates
      (if (numberp entry)
	  (setq low entry
		high entry)
	(setq low (car entry)
	      high (cdr entry)))
      (setq nlist2 nlist) ;; Don't assume any sorting of ranges
      (catch 'iterate-loop
	(while nlist2
	  (if (<= (caar nlist2) high) (throw 'iterate-loop nil))
	  (setq nlist2 (cdr nlist2))))
      (catch 'iterate-loop
	(while nlist2
	  (setq entry (car nlist2) nlist2 (cdr nlist2))
	  (if (< (car entry) low) (throw 'iterate-loop nil))
	  (funcall func (cdr entry)))))))

(defun nnmaildir--system-name ()
  (string-replace
   ":" "\\072"
   (string-replace
    "/" "\\057"
    (string-replace "\\" "\\134" (system-name)))))

(defun nnmaildir-request-type (_group &optional _article)
  'mail)

(defun nnmaildir-status-message (&optional server)
  (nnmaildir--prepare server nil)
  (nnmaildir--srv-error nnmaildir--cur-server))

(defun nnmaildir-server-opened (&optional server)
  (and nnmaildir--cur-server
       (if server
	   (string-equal server (nnmaildir--srv-address nnmaildir--cur-server))
	 t)
       (nnmaildir--srv-groups nnmaildir--cur-server)
       t))

(defun nnmaildir-open-server (server-string &optional defs)
  (let ((server (alist-get server-string nnmaildir--servers
			   nil nil #'equal))
	dir size x prefix)
    (catch 'return
      (if server
	  (and (nnmaildir--srv-groups server)
	       (setq nnmaildir--cur-server server)
	       (throw 'return t))
	(setq server (make-nnmaildir--srv :address server-string))
	(let ((inhibit-quit t))
	  (setf (alist-get server-string nnmaildir--servers
			   nil nil #'equal)
		server)))
      (setq dir (assq 'directory defs))
      (unless dir
	(setf (nnmaildir--srv-error server)
	      "You must set \"directory\" in the select method")
	(throw 'return nil))
      (setq dir (cadr dir)
	    dir (eval dir t)	;FIXME: Why `eval'?
	    dir (expand-file-name dir)
	    dir (file-name-as-directory dir))
      (unless (file-exists-p dir)
	(setf (nnmaildir--srv-error server) (concat "No such directory: " dir))
	(throw 'return nil))
      (setf (nnmaildir--srv-dir server) dir)
      (setq x (assq 'directory-files defs))
      (if (null x)
	  (setq x (if nnheader-directory-files-is-safe 'directory-files
		    'nnheader-directory-files-safe))
	(setq x (cadr x))
	(unless (functionp x)
	  (setf (nnmaildir--srv-error server)
		(concat "Not a function: " (prin1-to-string x)))
	  (throw 'return nil)))
      (setf (nnmaildir--srv-ls server) x)
      (setq size (length (funcall x dir nil "\\`[^.]" 'nosort)))
      (and (setq x (assq 'get-new-mail defs))
	   (setq x (cdr x))
	   (car x)
	   (setf (nnmaildir--srv-gnm server) t)
	   (require 'nnmail))
      (setf prefix (cl-second (assq 'target-prefix defs))
            (nnmaildir--srv-target-prefix server)
            (if prefix
                (eval prefix t)
              ""))
      (setf (nnmaildir--srv-groups server)
	    (gnus-make-hashtable size))
      (setq nnmaildir--cur-server server)
      t)))

(defun nnmaildir--parse-filename (file)
  (let ((prefix (car file))
	timestamp len)
    (if (string-match "\\`\\([0-9]+\\)\\(\\..*\\)\\'" prefix)
	(progn
	  (setq timestamp (concat "0000" (match-string 1 prefix))
		len (- (length timestamp) 4))
	  (vector (string-to-number (substring timestamp 0 len))
		  (string-to-number (substring timestamp len))
		  (match-string 2 prefix)
		  file))
      file)))

(defun nnmaildir--sort-files (a b)
  (catch 'return
    (if (consp a)
	(throw 'return (and (consp b) (string-lessp (car a) (car b)))))
    (if (consp b) (throw 'return t))
    (if (< (aref a 0) (aref b 0)) (throw 'return t))
    (if (> (aref a 0) (aref b 0)) (throw 'return nil))
    (if (< (aref a 1) (aref b 1)) (throw 'return t))
    (if (> (aref a 1) (aref b 1)) (throw 'return nil))
    (string-lessp (aref a 2) (aref b 2))))

(defun nnmaildir--scan (gname scan-msgs groups _method srv-dir srv-ls)
  (catch 'return
    (let ((36h-ago (time-since 129600))
	  absdir nndir tdir ndir cdir nattr cattr isnew pgname read-only ls
	  files num dir flist group x)
      (setq absdir (nnmaildir--srvgrp-dir srv-dir gname)
	    nndir (nnmaildir--nndir absdir))
      (unless (file-exists-p absdir)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such directory: " absdir))
	(throw 'return nil))
      (setq tdir (nnmaildir--tmp absdir)
	    ndir (nnmaildir--new absdir)
	    cdir (nnmaildir--cur absdir)
	    nattr (file-attributes ndir)
	    cattr (file-attributes cdir))
      (unless (and (file-exists-p tdir) nattr cattr)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Not a maildir: " absdir))
	(throw 'return nil))
      (setq group (nnmaildir--prepare nil gname)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname))
      (if group
	  (setq isnew nil)
	(setq isnew t
	      group (make-nnmaildir--grp :name gname :index 0))
	(nnmaildir--mkdir nndir)
	(nnmaildir--mkdir (nnmaildir--nov-dir   nndir))
	(nnmaildir--mkdir (nnmaildir--marks-dir nndir)))
      (setq read-only (nnmaildir--param pgname 'read-only)
	    ls (or (nnmaildir--param pgname 'directory-files) srv-ls))
      (unless read-only
	(setq x (file-attribute-device-number (file-attributes tdir)))
	(unless (and (equal x (file-attribute-device-number nattr))
		     (equal x (file-attribute-device-number cattr)))
	  (setf (nnmaildir--srv-error nnmaildir--cur-server)
		(concat "Maildir spans filesystems: " absdir))
	  (throw 'return nil))
	(dolist (file (funcall ls tdir 'full "\\`[^.]" 'nosort))
	  (setq x (file-attributes file))
	  (if (or (> (file-attribute-link-number x) 1)
		  (time-less-p (file-attribute-access-time x) 36h-ago))
	      (delete-file file))))
      (or scan-msgs
	  isnew
	  (throw 'return t))
      (setq nattr (file-attribute-modification-time nattr))
      (if (time-equal-p nattr (nnmaildir--grp-new group))
	  (setq nattr nil))
      (if read-only (setq dir (and (or isnew nattr) ndir))
	(when (or isnew nattr)
	  (dolist (file  (funcall ls ndir nil "\\`[^.]" 'nosort))
	    (setq x (concat ndir file))
	    (and (time-less-p (file-attribute-modification-time
			       (file-attributes x))
			      nil)
		 (rename-file x (concat cdir (nnmaildir--ensure-suffix file)))))
	  (setf (nnmaildir--grp-new group) nattr))
	(setq cattr (file-attribute-modification-time (file-attributes cdir)))
	(if (time-equal-p cattr (nnmaildir--grp-cur group))
	    (setq cattr nil))
	(setq dir (and (or isnew cattr) cdir)))
      (unless dir (throw 'return t))
      (setq files (funcall ls dir nil "\\`[^.]" 'nosort)
	    files (save-match-data
		    (mapcar
		     (lambda (f)
		       (string-match "\\`\\([^:]*\\)\\(\\(:.*\\)?\\)\\'" f)
		       (cons (match-string 1 f) (match-string 2 f)))
		     files)))
      (when isnew
	(setq num (length files))
	(setf (nnmaildir--grp-flist group) (gnus-make-hashtable num))
	(setf (nnmaildir--grp-mlist group) (gnus-make-hashtable num))
	(setf (nnmaildir--grp-mmth group) (gnus-make-hashtable 1))
	(setq num (nnmaildir--param pgname 'nov-cache-size))
	(if (numberp num) (if (< num 1) (setq num 1))
	  (setq num 16
		cdir (nnmaildir--marks-dir nndir)
		ndir (nnmaildir--subdir cdir "tick")
		cdir (nnmaildir--subdir cdir "read"))
	  (dolist (prefix-suffix files)
	    (let ((prefix (car prefix-suffix))
		  (suffix (cdr prefix-suffix)))
	      ;; increase num for each unread or ticked article
	      (when (or
		     ;; first look for marks in suffix, if it's valid...
		     (when (and (stringp suffix)
				(string-prefix-p ":2," suffix))
		       (or
			(not (string-match-p
			      (string (nnmaildir--mark-to-flag 'read)) suffix))
			(string-match-p
			 (string (nnmaildir--mark-to-flag 'tick)) suffix)))
		     ;; then look in marks directories
		     (not (file-exists-p (concat cdir prefix)))
		     (file-exists-p (concat ndir prefix)))
                (incf num)))))
	(setf (nnmaildir--grp-cache group) (make-vector num nil))
        (let ((inhibit-quit t))
          (puthash gname group groups))
	(or scan-msgs (throw 'return t)))
      (setq flist (nnmaildir--grp-flist group)
	    files (mapcar
		   (lambda (file)
		     (and (null (nnmaildir--flist-art flist (car file)))
			  file))
		   files)
	    files (delq nil files)
	    files (mapcar #'nnmaildir--parse-filename files)
	    files (sort files #'nnmaildir--sort-files))
      (dolist (file files)
	(setq file (if (consp file) file (aref file 3))
	      x (make-nnmaildir--art :prefix (car file) :suffix (cdr file)))
	(nnmaildir--grp-add-art nnmaildir--cur-server group x))
      (if read-only (setf (nnmaildir--grp-new group) nattr)
	(setf (nnmaildir--grp-cur group) cattr)))
    t))

(defvar nnmaildir-get-new-mail)
(defvar nnmaildir-group-alist)
(defvar nnmaildir-active-file)

(defun nnmaildir-request-scan (&optional scan-group server)
  (let ((coding-system-for-write nnheader-file-coding-system)
	(buffer-file-coding-system nil)
	(file-coding-system-alist nil)
	(nnmaildir-get-new-mail t)
	(nnmaildir-group-alist nil)
	(nnmaildir-active-file nil)
	x srv-ls srv-dir method groups target-prefix dirs seen
	deactivate-mark)
    (nnmaildir--prepare server nil)
    (setq srv-ls (nnmaildir--srv-ls nnmaildir--cur-server)
	  srv-dir (nnmaildir--srv-dir nnmaildir--cur-server)
	  method (nnmaildir--srv-method nnmaildir--cur-server)
	  groups (nnmaildir--srv-groups nnmaildir--cur-server)
	  target-prefix (nnmaildir--srv-target-prefix nnmaildir--cur-server))
    (nnmaildir--with-work-buffer
     (save-match-data
       (if (stringp scan-group)
	   (if (nnmaildir--scan scan-group t groups method srv-dir srv-ls)
	       (when (nnmaildir--srv-gnm nnmaildir--cur-server)
		 (nnmail-get-new-mail 'nnmaildir nil nil scan-group))
	     (remhash scan-group groups))
	 (setq x (file-attribute-modification-time (file-attributes srv-dir))
	       scan-group (null scan-group))
	 (if (time-equal-p x (nnmaildir--srv-mtime nnmaildir--cur-server))
	     (when scan-group
	       (maphash (lambda (group-name _group)
			  (nnmaildir--scan group-name t groups
					   method srv-dir srv-ls))
			groups))
	   (setq dirs (funcall srv-ls srv-dir nil "\\`[^.]" 'nosort)
		 dirs (if (zerop (length target-prefix))
			  dirs
			(seq-remove
			 (lambda (dir)
			   (and (>= (length dir) (length target-prefix))
				(string= (substring dir 0
						    (length target-prefix))
					 target-prefix)))
			 dirs)))
	   (dolist (grp-dir dirs)
	     (when (nnmaildir--scan grp-dir scan-group groups
				    method srv-dir srv-ls)
	       (push grp-dir seen)))
	   (setq x nil)
	   (maphash (lambda (gname _group)
		      (unless (member gname seen)
			(push gname x)))
		    groups)
	   (dolist (grp x)
	     (remhash grp groups))
	   (setf (nnmaildir--srv-mtime nnmaildir--cur-server)
		 (file-attribute-modification-time (file-attributes srv-dir))))
	 (and scan-group
	      (nnmaildir--srv-gnm nnmaildir--cur-server)
	      (nnmail-get-new-mail 'nnmaildir nil nil))))))
  t)

(defun nnmaildir-request-list (&optional server)
  (nnmaildir-request-scan 'find-new-groups server)
  (let (pgname ro deactivate-mark)
    (nnmaildir--prepare server nil)
    (nnmaildir--with-nntp-buffer
      (erase-buffer)
      (maphash (lambda (gname group)
		  (setq pgname (nnmaildir--pgname nnmaildir--cur-server gname)

			ro (nnmaildir--param pgname 'read-only))
		  (insert (string-replace
			   " " "\\ "
			   (nnmaildir--grp-name group))
			  " ")
                  (princ (nnmaildir--group-maxnum nnmaildir--cur-server group)
			 nntp-server-buffer)
		  (insert " ")
                  (princ (nnmaildir--grp-min group) nntp-server-buffer)
		  (insert " " (if ro "n" "y") "\n"))
		(nnmaildir--srv-groups nnmaildir--cur-server))))
  t)

(defun nnmaildir-request-newgroups (_date &optional server)
  (nnmaildir-request-list server))

(defun nnmaildir-retrieve-groups (groups &optional server)
  (let (group deactivate-mark)
    (nnmaildir--prepare server nil)
    (nnmaildir--with-nntp-buffer
      (erase-buffer)
      (dolist (gname groups)
	(setq group (nnmaildir--prepare nil gname))
	(if (null group) (insert "411 no such news group\n")
	  (insert "211 ")
	  (princ (nnmaildir--grp-count group) nntp-server-buffer)
	  (insert " ")
	  (princ (nnmaildir--grp-min   group) nntp-server-buffer)
	  (insert " ")
	  (princ (nnmaildir--group-maxnum nnmaildir--cur-server group)
		 nntp-server-buffer)
	  (insert " "
		  (string-replace " " "\\ " gname)
		  "\n")))))
  'group)

(defun nnmaildir-request-update-info (gname info &optional server)
  (let* ((group (nnmaildir--prepare server gname))
	 (curdir (nnmaildir--cur
		  (nnmaildir--srvgrp-dir
		   (nnmaildir--srv-dir nnmaildir--cur-server) gname)))
	 (curdir-mtime (file-attribute-modification-time (file-attributes curdir)))
	 pgname flist always-marks never-marks old-marks dir
	 all-marks marks ranges markdir read ls
	 old-mmth new-mmth mtime existing missing deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname)
	    flist (nnmaildir--grp-flist group))
      (when (zerop (nnmaildir--grp-count group))
	(setf (gnus-info-read info) nil)
	(gnus-info-set-marks info nil 'extend)
	(throw 'return info))
      (setq old-marks (cons 'read (gnus-info-read info))
	    old-marks (cons old-marks (gnus-info-marks info))
	    always-marks (nnmaildir--param pgname 'always-marks)
	    never-marks (nnmaildir--param pgname 'never-marks)
	    existing (nnmaildir--grp-nlist group)
	    existing (mapcar #'car existing)
	    existing (nreverse existing)
	    existing (range-compress-list existing)
	    missing (list (cons 1 (nnmaildir--group-maxnum
				   nnmaildir--cur-server group)))
	    missing (range-difference missing existing)
	    dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir gname)
	    dir (nnmaildir--nndir dir)
	    dir (nnmaildir--marks-dir dir)
            ls (nnmaildir--group-ls nnmaildir--cur-server pgname)
            all-marks (seq-uniq
		       ;; get mark names from mark dirs and from flag
		       ;; mappings
		       (append
			(mapcar #'cdr nnmaildir-flag-mark-mapping)
			(mapcar #'intern (funcall ls dir nil "\\`[^.]" 'nosort))))
	    new-mmth (make-hash-table :size (length all-marks))
	    old-mmth (nnmaildir--grp-mmth group))
      (dolist (mark all-marks)
	(setq markdir (nnmaildir--subdir dir (symbol-name mark))
	      ranges nil)
	(catch 'got-ranges
	  (if (memq mark never-marks) (throw 'got-ranges nil))
	  (when (memq mark always-marks)
	    (setq ranges existing)
	    (throw 'got-ranges nil))
	  ;; Find the mtime for this mark.  If this mark can be expressed as
	  ;; a filename flag, get the later of the mtimes for markdir and
	  ;; curdir, otherwise only the markdir counts.
	  (setq mtime
		(let ((markdir-mtime (file-attribute-modification-time (file-attributes markdir))))
		  (cond
		   ((null (nnmaildir--mark-to-flag mark))
		    markdir-mtime)
		   ((null markdir-mtime)
		    curdir-mtime)
		   ((null curdir-mtime)
		    ;; this should never happen...
		    markdir-mtime)
		   ((time-less-p markdir-mtime curdir-mtime)
		    curdir-mtime)
		   (t
		    markdir-mtime))))
	  (puthash mark mtime new-mmth)
	  (when (time-equal-p mtime (gethash mark old-mmth))
	    (setq ranges (assq mark old-marks))
	    (if ranges (setq ranges (cdr ranges)))
	    (throw 'got-ranges nil))
	  (let ((article-list nil))
	    ;; Consider the article marked if it either has the flag in the
	    ;; filename, or is in the markdir.  As you'd rarely remove a
	    ;; flag/mark, this should avoid losing information in the most
	    ;; common usage pattern.
	    (or
	     (let ((flag (nnmaildir--mark-to-flag mark)))
	       ;; If this mark has a corresponding maildir flag...
	       (when flag
		 (let ((regexp
			(concat "\\`[^.].*:2,[A-Z]*" (string flag))))
		   ;; ...then find all files with that flag.
		   (dolist (filename (funcall ls curdir nil regexp 'nosort))
		     (let* ((prefix (car (split-string filename ":2,")))
			    (article (nnmaildir--flist-art flist prefix)))
		       (when article
			 (push (nnmaildir--art-num article) article-list)))))))
	     ;; Also check Gnus-specific mark directory, if it exists.
	     (when (file-directory-p markdir)
	       (dolist (prefix (funcall ls markdir nil "\\`[^.]" 'nosort))
		 (let ((article (nnmaildir--flist-art flist prefix)))
		   (when article
		     (push (nnmaildir--art-num article) article-list))))))
	    (setq ranges (range-add-list ranges (sort article-list #'<)))))
	(if (eq mark 'read) (setq read ranges)
	  (if ranges (setq marks (cons (cons mark ranges) marks)))))
      (setf (gnus-info-read info) (range-concat read missing))
      (gnus-info-set-marks info marks 'extend)
      (setf (nnmaildir--grp-mmth group) new-mmth)
      info)))

(defun nnmaildir-request-group (gname &optional server fast _info)
  (let ((group (nnmaildir--prepare server gname))
	deactivate-mark)
    (catch 'return
      (unless group
	;; (insert "411 no such news group\n")
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (setf (nnmaildir--srv-curgrp nnmaildir--cur-server) group)
      (if fast (throw 'return t))
      (nnmaildir--with-nntp-buffer
	(erase-buffer)
	(insert "211 ")
	(princ (nnmaildir--grp-count group) nntp-server-buffer)
	(insert " ")
	(princ (nnmaildir--grp-min   group) nntp-server-buffer)
	(insert " ")
	(princ (nnmaildir--group-maxnum nnmaildir--cur-server group)
	       nntp-server-buffer)
	(insert " " (string-replace " " "\\ " gname) "\n")
	t))))

(defun nnmaildir-request-create-group (gname &optional server _args)
  (nnmaildir--prepare server nil)
  (catch 'return
    (let ((target-prefix (nnmaildir--srv-target-prefix nnmaildir--cur-server))
	  srv-dir dir)
      (when (zerop (length gname))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Invalid (empty) group name")
	(throw 'return nil))
      (when (eq (aref "." 0) (aref gname 0))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Group names may not start with \".\"")
	(throw 'return nil))
      (when (save-match-data (string-match "[\0/\t]" gname))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Invalid characters (null, tab, or /) in group name: "
		      gname))
	(throw 'return nil))
      (when (gethash
	     gname (nnmaildir--srv-groups nnmaildir--cur-server))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Group already exists: " gname))
	(throw 'return nil))
      (setq srv-dir (nnmaildir--srv-dir nnmaildir--cur-server))
      (if (file-name-absolute-p target-prefix)
	  (setq dir (expand-file-name target-prefix))
	(setq dir srv-dir
	      dir (file-truename dir)
	      dir (concat dir target-prefix)))
      (setq dir (nnmaildir--subdir dir gname))
      (nnmaildir--mkdir dir)
      (nnmaildir--mkdir (nnmaildir--tmp dir))
      (nnmaildir--mkdir (nnmaildir--new dir))
      (nnmaildir--mkdir (nnmaildir--cur dir))
      (unless (string= target-prefix "")
	(make-symbolic-link (concat target-prefix gname)
			    (concat srv-dir gname)))
      (nnmaildir-request-scan 'find-new-groups))))

(defun nnmaildir-request-rename-group (gname new-name &optional server)
  (let ((group (nnmaildir--prepare server gname))
	(coding-system-for-write nnheader-file-coding-system)
	(buffer-file-coding-system nil)
	(file-coding-system-alist nil)
	srv-dir x groups)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (when (zerop (length new-name))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Invalid (empty) group name")
	(throw 'return nil))
      (when (eq (aref "." 0) (aref new-name 0))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Group names may not start with \".\"")
	(throw 'return nil))
      (when (save-match-data (string-match "[\0/\t]" new-name))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Invalid characters (null, tab, or /) in group name: "
		      new-name))
	(throw 'return nil))
      (if (string-equal gname new-name) (throw 'return t))
      (when (gethash new-name
			 (nnmaildir--srv-groups nnmaildir--cur-server))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Group already exists: " new-name))
	(throw 'return nil))
      (setq srv-dir (nnmaildir--srv-dir nnmaildir--cur-server))
      (condition-case err
	  (rename-file (concat srv-dir gname)
		       (concat srv-dir new-name))
	(error
	 (setf (nnmaildir--srv-error nnmaildir--cur-server)
	       (concat "Error renaming link: " (prin1-to-string err)))
	 (throw 'return nil)))
      ;; FIXME: Why are we making copies of the group and the groups
      ;; hashtable?  Why not just set the group's new name, and puthash the
      ;; group under that new name?
      (setq x (nnmaildir--srv-groups nnmaildir--cur-server)
	    groups (gnus-make-hashtable (hash-table-size x)))
      (maphash (lambda (gname g)
		  (unless (eq g group)
		    (puthash gname g groups)))
		x)
      (setq group (copy-sequence group))
      (setf (nnmaildir--grp-name group) new-name)
      (puthash new-name group groups)
      (setf (nnmaildir--srv-groups nnmaildir--cur-server) groups)
      t)))

(defun nnmaildir-request-delete-group (gname force &optional server)
  (let ((group (nnmaildir--prepare server gname))
	pgname grp-dir target dir ls deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname)
	    grp-dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    target (car (file-attributes (concat grp-dir gname)))
	    grp-dir (nnmaildir--srvgrp-dir grp-dir gname))
      (unless (or force (stringp target))
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Not a symlink: " gname))
	(throw 'return nil))
      (if (eq group (nnmaildir--srv-curgrp nnmaildir--cur-server))
	  (setf (nnmaildir--srv-curgrp nnmaildir--cur-server) nil))
      (remhash gname (nnmaildir--srv-groups nnmaildir--cur-server))
      (if (not force)
	  (progn
	    (setq grp-dir (directory-file-name grp-dir))
	    (nnmaildir--unlink grp-dir))
	(setq ls (nnmaildir--group-ls nnmaildir--cur-server pgname))
	(if (nnmaildir--param pgname 'read-only)
	    (progn (delete-directory  (nnmaildir--tmp grp-dir))
		   (nnmaildir--unlink (nnmaildir--new grp-dir))
		   (delete-directory  (nnmaildir--cur grp-dir)))
	  (nnmaildir--delete-dir-files (nnmaildir--tmp grp-dir) ls)
	  (nnmaildir--delete-dir-files (nnmaildir--new grp-dir) ls)
	  (nnmaildir--delete-dir-files (nnmaildir--cur grp-dir) ls))
	(setq dir (nnmaildir--nndir grp-dir))
	(dolist (subdir `(,(nnmaildir--nov-dir dir) ,(nnmaildir--num-dir dir)
			  ,@(funcall ls (nnmaildir--marks-dir dir)
				     'full "\\`[^.]" 'nosort)))
	  (nnmaildir--delete-dir-files subdir ls))
	(setq dir (nnmaildir--nndir grp-dir))
	(nnmaildir--unlink (concat dir "markfile"))
	(nnmaildir--unlink (concat dir "markfile{new}"))
	(delete-directory (nnmaildir--marks-dir dir))
	(delete-directory dir)
	(if (not (stringp target))
	    (delete-directory grp-dir)
	  (setq grp-dir (directory-file-name grp-dir)
		dir target)
	  (unless (eq (aref "/" 0) (aref dir 0))
	    (setq dir (concat (file-truename
			       (nnmaildir--srv-dir nnmaildir--cur-server))
			      dir)))
	  (delete-directory dir)
	  (nnmaildir--unlink grp-dir)))
      t)))

(defun nnmaildir-retrieve-headers (articles &optional gname server fetch-old)
  (let ((group (nnmaildir--prepare server gname))
	nlist mlist article num start stop nov insert-nov
	deactivate-mark)
    (setq insert-nov
	  (lambda (article)
	    (setq nov (nnmaildir--update-nov nnmaildir--cur-server group
					     article))
	    (when nov
	      (nnmaildir--cache-nov group article nov)
	      (setq num (nnmaildir--art-num article))
	      (princ num nntp-server-buffer)
	      (insert "\t" (nnmaildir--nov-get-beg nov) "\t"
		      (nnmaildir--art-msgid article) "\t"
		      (nnmaildir--nov-get-mid nov) "\tXref: nnmaildir "
		      (string-replace " " "\\ " gname) ":")
	      (princ num nntp-server-buffer)
	      (insert "\t" (nnmaildir--nov-get-end nov) "\n"))))
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (if gname (concat "No such group: " gname) "No current group"))
	(throw 'return nil))
      (nnmaildir--with-nntp-buffer
	(erase-buffer)
	(setq mlist (nnmaildir--grp-mlist group)
	      nlist (nnmaildir--grp-nlist group)
	      gname (nnmaildir--grp-name group))
	(cond
	 ((null nlist))
	 ((and fetch-old (not (numberp fetch-old)))
	  (nnmaildir--nlist-iterate nlist 'all insert-nov))
	 ((null articles))
	 ((stringp (car articles))
	  (dolist (msgid articles)
	    (setq article (nnmaildir--mlist-art mlist msgid))
	    (if article (funcall insert-nov article))))
	 (t
	  (if fetch-old
	      ;; Assume the article range list is sorted ascending
	      (setq stop (car articles)
		    start (car (last articles))
		    stop  (if (numberp stop)  stop  (car stop))
		    start (if (numberp start) start (cdr start))
		    stop (- stop fetch-old)
		    stop (if (< stop 1) 1 stop)
		    articles (list (cons stop start))))
	  (nnmaildir--nlist-iterate nlist articles insert-nov)))
	(sort-numeric-fields 1 (point-min) (point-max))
	'nov))))

(defun nnmaildir-request-article (num-msgid &optional gname server to-buffer)
  (let ((group (nnmaildir--prepare server gname))
	(case-fold-search t)
	list article dir pgname deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (if gname (concat "No such group: " gname) "No current group"))
	(throw 'return nil))
      (if (numberp num-msgid)
	  (setq article (nnmaildir--nlist-art group num-msgid))
	(setq list (nnmaildir--grp-mlist group)
	      article (nnmaildir--mlist-art list num-msgid))
	(if article (setq num-msgid (nnmaildir--art-num article))
	  (catch 'found
	    (maphash
              (lambda (_gname group)
                (setq list (nnmaildir--grp-mlist group)
                      article (nnmaildir--mlist-art list num-msgid))
                (when article
                  (setq num-msgid (nnmaildir--art-num article))
                  (throw 'found nil)))
              (nnmaildir--srv-groups nnmaildir--cur-server))))
	(unless article
	  (setf (nnmaildir--srv-error nnmaildir--cur-server) "No such article")
	  (throw 'return nil)))
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname)
	    dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir gname)
	    dir (if (nnmaildir--param pgname 'read-only)
		    (nnmaildir--new dir) (nnmaildir--cur dir))
	    nnmaildir-article-file-name
	    (concat dir
		    (nnmaildir--art-prefix article)
		    (nnmaildir--art-suffix article)))
      (unless (file-exists-p nnmaildir-article-file-name)
	(nnmaildir--expired-article group article)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Article has expired")
	(throw 'return nil))
      (with-current-buffer (or to-buffer nntp-server-buffer)
	(erase-buffer)
	(let ((coding-system-for-read mm-text-coding-system))
	  (mm-insert-file-contents nnmaildir-article-file-name)))
      (cons gname num-msgid))))

(defun nnmaildir-request-post (&optional _server)
  (let (message-required-mail-headers)
    (funcall message-send-mail-function)))

(defun nnmaildir-request-replace-article (number gname buffer)
  (let ((group (nnmaildir--prepare nil gname))
	(coding-system-for-write nnheader-file-coding-system)
	(buffer-file-coding-system nil)
	(file-coding-system-alist nil)
	dir file article suffix tmpfile deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (when (nnmaildir--param (nnmaildir--pgname nnmaildir--cur-server gname)
			      'read-only)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Read-only group: " group))
	(throw 'return nil))
      (setq dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir gname)
	    article (nnmaildir--nlist-art group number))
      (unless article
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such article: " (number-to-string number)))
	(throw 'return nil))
      (setq suffix (nnmaildir--art-suffix article)
	    file (nnmaildir--art-prefix article)
	    tmpfile (concat (nnmaildir--tmp dir) file))
      (when (file-exists-p tmpfile)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "File exists: " tmpfile))
	(throw 'return nil))
      (with-current-buffer buffer
	(write-region (point-min) (point-max) tmpfile nil 'no-message nil
		      'excl))
      (when (fboundp 'unix-sync)
	(unix-sync)) ;; no fsync :(
      (rename-file tmpfile (concat (nnmaildir--cur dir) file suffix) 'replace)
      t)))

(defun nnmaildir-request-move-article (article gname server accept-form
				       &optional _last _move-is-internal)
  (let ((group (nnmaildir--prepare server gname))
	pgname suffix result nnmaildir--file deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname)
	    article (nnmaildir--nlist-art group article))
      (unless article
	(setf (nnmaildir--srv-error nnmaildir--cur-server) "No such article")
	(throw 'return nil))
      (setq suffix (nnmaildir--art-suffix article)
	    nnmaildir--file (nnmaildir--srv-dir nnmaildir--cur-server)
	    nnmaildir--file (nnmaildir--srvgrp-dir nnmaildir--file gname)
	    nnmaildir--file (if (nnmaildir--param pgname 'read-only)
				(nnmaildir--new nnmaildir--file)
			      (nnmaildir--cur nnmaildir--file))
	    nnmaildir--file (concat nnmaildir--file
				    (nnmaildir--art-prefix article)
				    suffix))
      (unless (file-exists-p nnmaildir--file)
	(nnmaildir--expired-article group article)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      "Article has expired")
	(throw 'return nil))
      (nnmaildir--with-move-buffer
	(erase-buffer)
	(nnheader-insert-file-contents nnmaildir--file)
	(setq result (eval accept-form t)))
      (unless (or (null result) (nnmaildir--param pgname 'read-only))
	(nnmaildir--unlink nnmaildir--file)
	(nnmaildir--expired-article group article))
      result)))

(defun nnmaildir-request-accept-article (gname &optional server _last)
  (let ((group (nnmaildir--prepare server gname))
	(coding-system-for-write nnheader-file-coding-system)
	(buffer-file-coding-system nil)
	(file-coding-system-alist nil)
	srv-dir dir file time tmpfile curfile 24h article)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(throw 'return nil))
      (setq gname (nnmaildir--grp-name group))
      (when (nnmaildir--param (nnmaildir--pgname nnmaildir--cur-server gname)
			      'read-only)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "Read-only group: " gname))
	(throw 'return nil))
      (setq srv-dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir srv-dir gname)
	    time (current-time)
	    file (format-time-string "%s." time))
      (unless (string-equal nnmaildir--delivery-time file)
	(setq nnmaildir--delivery-time file
	      nnmaildir--delivery-count 0))
      (setq file (concat file (format-time-string "M%6N" time)))
      (setq file (concat file nnmaildir--delivery-pid)
	    file (concat file "Q" (number-to-string nnmaildir--delivery-count))
	    file (concat file "." (nnmaildir--system-name))
	    tmpfile (concat (nnmaildir--tmp dir) file)
	    curfile (concat (nnmaildir--cur dir) file ":2,"))
      (when (file-exists-p tmpfile)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "File exists: " tmpfile))
	(throw 'return nil))
      (when (file-exists-p curfile)
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "File exists: " curfile))
	(throw 'return nil))
      (setq nnmaildir--delivery-count (1+ nnmaildir--delivery-count)
	    24h (run-with-timer 86400 nil
				(lambda ()
				  (nnmaildir--unlink tmpfile)
				  (setf (nnmaildir--srv-error
					  nnmaildir--cur-server)
					"24-hour timer expired")
				  (throw 'return nil))))
      (condition-case nil (add-name-to-file nnmaildir--file tmpfile)
	(error
	 (write-region (point-min) (point-max) tmpfile nil 'no-message nil
		       'excl)
	 (when (fboundp 'unix-sync)
	   (unix-sync)))) ;; no fsync :(
      (cancel-timer 24h)
      (condition-case err
	  (add-name-to-file tmpfile curfile)
	(error
	 (setf (nnmaildir--srv-error nnmaildir--cur-server)
	       (concat "Error linking: " (prin1-to-string err)))
	 (nnmaildir--unlink tmpfile)
	 (throw 'return nil)))
      (nnmaildir--unlink tmpfile)
      (setq article (make-nnmaildir--art :prefix file :suffix ":2,"))
      (if (nnmaildir--grp-add-art nnmaildir--cur-server group article)
	  (cons gname (nnmaildir--art-num article))))))

(defun nnmaildir-save-mail (group-art)
  (catch 'return
    (unless group-art
      (throw 'return nil))
    (let (ga gname x groups nnmaildir--file deactivate-mark)
      (save-excursion
	(goto-char (point-min))
	(save-match-data
	  (while (looking-at "From ")
	    (replace-match "X-From-Line: ")
	    (forward-line 1))))
      (setq groups (nnmaildir--srv-groups nnmaildir--cur-server)
	    ga (car group-art) group-art (cdr group-art)
	    gname (car ga))
      (or (gethash gname groups)
	  (nnmaildir-request-create-group gname)
	  (throw 'return nil)) ;; not that nnmail bothers to check :(
      (unless (nnmaildir-request-accept-article gname)
	(throw 'return nil))
      (setq nnmaildir--file (nnmaildir--srv-dir nnmaildir--cur-server)
	    nnmaildir--file (nnmaildir--srvgrp-dir nnmaildir--file gname)
	    x (nnmaildir--prepare nil gname)
	    x (nnmaildir--grp-nlist x)
	    x (cdar x)
	    nnmaildir--file (concat nnmaildir--file
				    (nnmaildir--art-prefix x)
				    (nnmaildir--art-suffix x)))
      (delq nil
	    (mapcar
	     (lambda (ga)
	       (setq gname (car ga))
	       (and (or (gethash gname groups)
			(nnmaildir-request-create-group gname))
		    (nnmaildir-request-accept-article gname)
		    ga))
	     group-art)))))

(defun nnmaildir-active-number (_gname)
  0)

(declare-function gnus-group-mark-article-read "gnus-group" (group article))

(defun nnmaildir-request-expire-articles (ranges &optional gname server force)
  (let ((no-force (not force))
	(group (nnmaildir--prepare server gname))
	pgname time boundary target dir nlist
	didnt nnmaildir--file nnmaildir-article-file-name
	deactivate-mark)
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (if gname (concat "No such group: " gname) "No current group"))
	(throw 'return (range-uncompress ranges)))
      (setq gname (nnmaildir--grp-name group)
	    pgname (nnmaildir--pgname nnmaildir--cur-server gname))
      (if (nnmaildir--param pgname 'read-only)
	  (throw 'return (range-uncompress ranges)))
      (setq time (nnmaildir--param pgname 'expire-age))
      (unless time
	(setq time (or (and nnmail-expiry-wait-function
			    (funcall nnmail-expiry-wait-function gname))
		       nnmail-expiry-wait))
	(if (eq time 'immediate)
	    (setq time 0)
	  (if (numberp time)
	      (setq time (round (* time 86400))))))
      (when no-force
	(unless (integerp time) ;; handle 'never
	  (throw 'return (range-uncompress ranges)))
	(setq boundary (time-since time)))
      (setq dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir gname)
	    dir (nnmaildir--cur dir)
	    nlist (nnmaildir--grp-nlist group)
	    ranges (reverse ranges))
      (nnmaildir--with-move-buffer
	(nnmaildir--nlist-iterate
	 nlist ranges
	 (lambda (article)
	   (setq nnmaildir--file (nnmaildir--art-prefix article)
		 nnmaildir--file (concat dir nnmaildir--file
					 (nnmaildir--art-suffix article))
		 time (file-attributes nnmaildir--file))
	   (cond
	    ((null time)
	     (nnmaildir--expired-article group article))
	    ((and no-force
		  (time-less-p boundary
			       (file-attribute-modification-time time)))
	     (setq didnt (cons (nnmaildir--art-num article) didnt)))
	    (t
	     (setq nnmaildir-article-file-name nnmaildir--file
		   target (if force nil
			    (save-excursion
			      (save-restriction
				(nnmaildir--param pgname 'expire-group)))))
	     (when (and (stringp target)
			(not (string-equal target pgname))) ;; Move it.
	       (erase-buffer)
	       (nnheader-insert-file-contents nnmaildir--file)
	       (let ((group-art (gnus-request-accept-article
				 target nil nil 'no-encode)))
		 (when (consp group-art)
		   ;; Maybe also copy: dormant forward reply save tick
		   ;; (gnus-add-mark? gnus-request-set-mark?)
		   (gnus-group-mark-article-read target (cdr group-art)))))
	     (if (equal target pgname)
		 ;; Leave it here.
		 (setq didnt (cons (nnmaildir--art-num article) didnt))
	       (nnmaildir--unlink nnmaildir--file)
	       (nnmaildir--expired-article group article))))))
	(erase-buffer))
      didnt)))

(defvar nnmaildir--article)

(defun nnmaildir-request-set-mark (gname actions &optional server)
  (let* ((group (nnmaildir--prepare server gname))
	 (curdir (nnmaildir--cur
		  (nnmaildir--srvgrp-dir
		   (nnmaildir--srv-dir nnmaildir--cur-server)
		   gname)))
	 (coding-system-for-write nnheader-file-coding-system)
	 (buffer-file-coding-system nil)
	 (file-coding-system-alist nil)
	 marksdir nlist
	 ranges all-marks todo-marks mdir mfile
	 pgname ls permarkfile deactivate-mark
	 (del-mark
	  (lambda (mark)
	    (let ((prefix (nnmaildir--art-prefix nnmaildir--article))
		  (suffix (nnmaildir--art-suffix nnmaildir--article))
		  (flag (nnmaildir--mark-to-flag mark)))
	      (when flag
		;; If this mark corresponds to a flag, remove the flag from
		;; the file name.
		(nnmaildir--article-set-flags
		 nnmaildir--article (nnmaildir--remove-flag flag suffix)
		 curdir))
	      ;; We still want to delete the hardlink in the marks dir if
	      ;; present, regardless of whether this mark has a maildir flag or
	      ;; not, to avoid getting out of sync.
	      (setq mfile (nnmaildir--subdir marksdir (symbol-name mark))
		    mfile (concat mfile prefix))
	      (nnmaildir--unlink mfile))))
	 (del-action (lambda (article)
		       (let ((nnmaildir--article article))
			 (mapcar del-mark todo-marks))))
	 (add-action
	  (lambda (article)
	    (mapcar
	     (lambda (mark)
	       (let ((prefix (nnmaildir--art-prefix article))
		     (suffix (nnmaildir--art-suffix article))
		     (flag (nnmaildir--mark-to-flag mark)))
		 (if flag
		     ;; If there is a corresponding maildir flag, just rename
		     ;; the file.
		     (nnmaildir--article-set-flags
		      article (nnmaildir--add-flag flag suffix) curdir)
		   ;; Otherwise, use nnmaildir-specific marks dir.
		   (setq mdir (nnmaildir--subdir marksdir (symbol-name mark))
			 permarkfile (concat mdir ":")
			 mfile (concat mdir prefix))
		   (nnmaildir--condcase err (add-name-to-file permarkfile mfile)
		     (cond
		      ((nnmaildir--eexist-p err))
		      ((nnmaildir--enoent-p err)
		       (nnmaildir--mkdir mdir)
		       (nnmaildir--mkfile permarkfile)
		       (add-name-to-file permarkfile mfile))
		      ((nnmaildir--emlink-p err)
		       (let ((permarkfilenew (concat permarkfile "{new}")))
			 (nnmaildir--mkfile permarkfilenew)
			 (rename-file permarkfilenew permarkfile 'replace)
			 (add-name-to-file permarkfile mfile)))
		      (t (signal (car err) (cdr err))))))))
	     todo-marks)))
	 (set-action (lambda (article)
		       (funcall add-action article)
		       (let ((nnmaildir--article article))
			 (mapcar (lambda (mark)
				   (unless (memq mark todo-marks)
				     (funcall del-mark mark)))
				 all-marks)))))
    (catch 'return
      (unless group
	(setf (nnmaildir--srv-error nnmaildir--cur-server)
	      (concat "No such group: " gname))
	(dolist (action actions)
	  (setq ranges (range-concat ranges (car action))))
	(throw 'return ranges))
      (setq nlist (nnmaildir--grp-nlist group)
	    marksdir (nnmaildir--srv-dir nnmaildir--cur-server)
	    marksdir (nnmaildir--srvgrp-dir marksdir gname)
	    marksdir (nnmaildir--nndir marksdir)
	    marksdir (nnmaildir--marks-dir marksdir)
	    gname (nnmaildir--grp-name group)
            pgname (nnmaildir--pgname nnmaildir--cur-server gname)
            ls (nnmaildir--group-ls nnmaildir--cur-server pgname)
	    all-marks (funcall ls marksdir nil "\\`[^.]" 'nosort)
            all-marks (seq-uniq
		       ;; get mark names from mark dirs and from flag
		       ;; mappings
		       (append
			(mapcar #'cdr nnmaildir-flag-mark-mapping)
			(mapcar #'intern all-marks))))
      (dolist (action actions)
	(setq ranges (car action)
	      todo-marks (caddr action))
	(dolist (mark todo-marks)
	  (cl-pushnew mark all-marks :test #'equal))
	(if (numberp (cdr ranges)) (setq ranges (list ranges)))
	(nnmaildir--nlist-iterate nlist ranges
				  (cond ((eq 'del (cadr action)) del-action)
					((eq 'add (cadr action)) add-action)
					((eq 'set (cadr action)) set-action))))
      nil)))

(defun nnmaildir-close-group (gname &optional server)
  (let ((group (nnmaildir--prepare server gname))
	pgname ls dir msgdir files dirs
	(fset (make-hash-table :test #'equal)))
    (if (null group)
	(progn
	  (setf (nnmaildir--srv-error nnmaildir--cur-server)
		(concat "No such group: " gname))
	  nil)
      ;; Delete the now obsolete NOV files.
      ;; FIXME: This can take a somewhat long time, so maybe it's better
      ;; to do it asynchronously (i.e. in an idle timer).
      (setq pgname (nnmaildir--pgname nnmaildir--cur-server gname)
	    ls (nnmaildir--group-ls nnmaildir--cur-server pgname)
	    dir (nnmaildir--srv-dir nnmaildir--cur-server)
	    dir (nnmaildir--srvgrp-dir dir gname)
	    msgdir (if (nnmaildir--param pgname 'read-only)
		       (nnmaildir--new dir) (nnmaildir--cur dir))
	    ;; The dir with the NOV files.
	    dir (nnmaildir--nndir dir)
	    dirs (cons (nnmaildir--nov-dir dir)
		       (funcall ls (nnmaildir--marks-dir dir) 'full "\\`[^.]"
				'nosort))
	    dirs (mapcar
		  (lambda (dir)
		    (cons dir (funcall ls dir nil "\\`[^.]" 'nosort)))
		  dirs)
	    files (funcall ls msgdir nil "\\`[^.]" 'nosort))
      (save-match-data
	(dolist (file files)
	  (string-match "\\`\\([^:]*\\)\\(:.*\\)?\\'" file)
	  (puthash (match-string 1 file) t fset)))
      ;; Not sure why, but we specifically avoid deleting the `:' file.
      (puthash ":" t fset)
      (dolist (dir dirs)
	(setq files (cdr dir)
	      dir (file-name-as-directory (car dir)))
	(dolist (file files)
	  (unless (gethash file fset)
	    (delete-file (concat dir file)))))
      t)))

(defun nnmaildir-close-server (&optional server _defs)
  "Close SERVER, or the current maildir server."
  (when (nnmaildir--prepare server nil)
    (setq server nnmaildir--cur-server
	  nnmaildir--cur-server nil)

    ;; This slightly obscure invocation of `alist-get' removes SERVER from
    ;; `nnmaildir--servers'.
    (setf (alist-get (nnmaildir--srv-address server)
		     nnmaildir--servers server 'remove #'equal)
	  server))
  t)

(defun nnmaildir-request-close ()
  (let ((servers
	 (mapcar #'car nnmaildir--servers))
	buffer)
    (mapc #'nnmaildir-close-server servers)
    (setq buffer (get-buffer " *nnmaildir work*"))
    (if buffer (kill-buffer buffer))
    (setq buffer (get-buffer " *nnmaildir nov*"))
    (if buffer (kill-buffer buffer))
    (setq buffer (get-buffer " *nnmaildir move*"))
    (if buffer (kill-buffer buffer)))
  t)

(provide 'nnmaildir)

;;; nnmaildir.el ends here
