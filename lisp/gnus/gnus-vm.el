;;; gnus-vm.el --- vm interface for Gnus  -*- lexical-binding: t; -*-

;; Copyright (C) 1994-2025 Free Software Foundation, Inc.

;; Author: Per Persson <pp@gnu.ai.mit.edu>
;; Keywords: news, mail

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

;; Major contributors:
;;	Christian Limpach <Christian.Limpach@nice.ch>
;; Some code stolen from:
;;	Rick Sladkey <jrs@world.std.com>

;;; Code:

(require 'sendmail)
(require 'message)
(require 'gnus)
(require 'gnus-msg)

(defvar gnus-vm-inhibit-window-system nil
  "Inhibit loading `win-vm' if using a window-system.
Has to be set before gnus-vm is loaded.")

(unless gnus-vm-inhibit-window-system
  (ignore-errors
    (when window-system
      (require 'win-vm))))

(declare-function vm-mode "ext:vm" (&optional read-only))

(defun gnus-vm-make-folder (&optional buffer)
  (require 'vm)
  (let ((article (or buffer (current-buffer)))
	(tmp-folder (generate-new-buffer " *tmp-folder*"))
	(start (point-min))
	(end (point-max)))
    (set-buffer tmp-folder)
    (insert-buffer-substring article start end)
    (goto-char (point-min))
    (if (looking-at "^\\(From [^ ]+ \\).*$")
	(replace-match (concat "\\1" (current-time-string)))
      (insert "From " gnus-newsgroup-name " "
	      (current-time-string) "\n"))
    (while (re-search-forward "\n\nFrom " nil t)
      (replace-match "\n\n>From "))
    ;; insert a newline, otherwise the last line gets lost
    (goto-char (point-max))
    (insert "\n")
    (vm-mode)
    tmp-folder))

(defun gnus-summary-save-article-vm (&optional arg)
  "Append the current article to a vm folder.
If N is a positive number, save the N next articles.
If N is a negative number, save the N previous articles.
If N is nil and any articles have been marked with the process mark,
save those articles instead."
  (interactive "P" gnus-article-mode gnus-summary-mode)
  (require 'gnus-art)
  (let ((gnus-default-article-saver 'gnus-summary-save-in-vm))
    (gnus-summary-save-article arg)))

(declare-function vm-save-message "ext:vm-save" (folder &optional count))

(defun gnus-summary-save-in-vm (&optional folder)
  (interactive nil gnus-article-mode gnus-summary-mode)
  (require 'vm)
  (setq folder
	(gnus-read-save-file-name
	 "Save %s in VM folder:" folder
	 gnus-mail-save-name gnus-newsgroup-name
	 gnus-current-headers 'gnus-newsgroup-last-mail))
  (gnus-eval-in-buffer-window gnus-original-article-buffer
    (save-excursion
      (save-restriction
	(widen)
	(let ((vm-folder (gnus-vm-make-folder)))
	  (vm-save-message folder)
	  (kill-buffer vm-folder))))))

(provide 'gnus-vm)

;;; gnus-vm.el ends here
