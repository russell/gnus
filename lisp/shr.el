;;; shr.el --- Simple HTML Renderer

;; Copyright (C) 2010 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: html

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
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package takes a HTML parse tree (as provided by
;; libxml-parse-html-region) and renders it in the current buffer.  It
;; does not do CSS, JavaScript or anything advanced: It's geared
;; towards rendering typical short snippets of HTML, like what you'd
;; find in HTML email and the like.

;;; Code:

(defgroup shr nil
  "Simple HTML Renderer"
  :group 'mail)

(defcustom shr-max-image-proportion 0.9
  "How big pictures displayed are in relation to the window they're in.
A value of 0.7 means that they are allowed to take up 70% of the
width and height of the window.  If they are larger than this,
and Emacs supports it, then the images will be rescaled down to
fit these criteria."
  :version "24.1"
  :group 'shr
  :type 'float)

(defcustom shr-blocked-images nil
  "Images that have URLs matching this regexp will be blocked."
  :version "24.1"
  :group 'shr
  :type 'regexp)

(defvar shr-folding-mode nil)
(defvar shr-state nil)

(defvar shr-width 70)

(defun shr-transform-dom (dom)
  (let ((result (list (pop dom))))
    (dolist (arg (pop dom))
      (push (cons (intern (concat ":" (symbol-name (car arg))) obarray)
		  (cdr arg))
	    result))
    (dolist (sub dom)
      (if (stringp sub)
	  (push (cons :text sub) result)
	(push (shr-transform-dom sub) result)))
    (nreverse result)))

;;;###autoload
(defun shr-insert-document (dom)
  (let ((shr-state nil))
    (shr-descend (shr-transform-dom dom))))

(defun shr-descend (dom)
  (let ((function (intern (concat "shr-" (symbol-name (car dom))) obarray)))
    (if (fboundp function)
	(funcall function (cdr dom))
      (shr-generic (cdr dom)))))

(defun shr-generic (cont)
  (dolist (sub cont)
    (cond
     ((eq (car sub) :text)
      (shr-insert (cdr sub)))
     ((consp (cdr sub))
      (shr-descend sub)))))

(defun shr-p (cont)
  (shr-ensure-newline)
  (insert "\n")
  (shr-generic cont)
  (insert "\n"))

(defun shr-b (cont)
  (shr-fontize-cont cont 'bold))

(defun shr-i (cont)
  (shr-fontize-cont cont 'italic))

(defun shr-u (cont)
  (shr-fontize-cont cont 'underline))

(defun shr-s (cont)
  (shr-fontize-cont cont 'strikethru))

(defun shr-fontize-cont (cont type)
  (let ((start (point)))
    (shr-generic cont)
    (shr-add-font start (point) type)))

(defun shr-add-font (start end type)
  (put-text-property start end 'face type))

(defun shr-a (cont)
  (let ((start (point))
	(url (cdr (assq :href cont))))
    (shr-generic cont)
    (widget-convert-button
     'link start (point)
     :action 'shr-browse-url
     :url url
     :keymap widget-keymap
     :help-echo url)))

(defun shr-browse-url (widget &rest stuff)
  (browse-url (widget-get widget :url)))

(defun shr-img (cont)
  (let ((start (point-marker)))
    (let ((alt (cdr (assq :alt cont)))
	  (url (cdr (assq :src cont))))
      (when (zerop (length alt))
	(setq alt "[img]"))
      (cond
       ((and shr-blocked-images
	     (string-match shr-blocked-images url))
	(insert alt))
       ((url-is-cached (browse-url-url-encode-chars url "[&)$ ]"))
	(shr-put-image (shr-get-image-data url) (point) alt))
       (t
	(insert alt)
	(url-retrieve url 'shr-image-fetched
		      (list (current-buffer) start (point-marker))
		      t)))
      (insert " ")
      (setq shr-state 'image))))

(defun shr-image-fetched (status buffer start end)
  (when (and (buffer-name buffer)
	     (not (plist-get status :error)))
    (url-store-in-cache (current-buffer))
    (when (or (search-forward "\n\n" nil t)
	      (search-forward "\r\n\r\n" nil t))
      (let ((data (buffer-substring (point) (point-max))))
        (with-current-buffer buffer
          (let ((alt (buffer-substring start end))
		(inhibit-read-only t))
	    (delete-region start end)
	    (shr-put-image data start alt))))))
  (kill-buffer (current-buffer)))

(defun shr-put-image (data point alt)
  (if (not (display-graphic-p))
      (insert alt)
    (let ((image (shr-rescale-image data)))
      (put-image image point alt))))

(defun shr-rescale-image (data)
  (if (or (not (fboundp 'imagemagick-types))
	  (not (get-buffer-window (current-buffer))))
      (create-image data nil t)
    (let* ((image (create-image data nil t))
	   (size (image-size image))
	   (width (car size))
	   (height (cdr size))
	   (edges (window-inside-pixel-edges
		   (get-buffer-window (current-buffer))))
	   (window-width (truncate (* shr-max-image-proportion
				      (- (nth 2 edges) (nth 0 edges)))))
	   (window-height (truncate (* shr-max-image-proportion
				       (- (nth 3 edges) (nth 1 edges)))))
	   scaled-image)
      (when (> height window-height)
	(setq image (or (create-image data 'imagemagick t
				      :height window-height)
			image))
	(setq size (image-size image t)))
      (when (> (car size) window-width)
	(setq image (or
		     (create-image data 'imagemagick t
				   :width window-width)
		     image)))
      image)))

(defun shr-pre (cont)
  (let ((shr-folding-mode nil))
    (shr-ensure-newline)
    (shr-generic cont)
    (shr-ensure-newline)))

(defun shr-blockquote (cont)
  (shr-pre cont))

(defun shr-ensure-newline ()
  (unless (zerop (current-column))
    (insert "\n")))

(defun shr-insert (text)
  (when (eq shr-state 'image)
    (insert "\n")
    (setq shr-state nil))
  (cond
   ((eq shr-folding-mode 'none)
    (insert t))
   (t
    (let (column)
      (dolist (elem (split-string text))
	(setq column (current-column))
	(if (zerop column)
	    (insert elem)
	  (if (> (+ column (length elem) 1) shr-width)
	      (insert "\n" elem)
	    (insert " " elem))))))))

(defun shr-get-image-data (url)
  "Get image data for URL.
Return a string with image data."
  (with-temp-buffer
    (mm-disable-multibyte)
    (url-cache-extract (url-cache-create-filename url))
    (when (or (search-forward "\n\n" nil t)
              (search-forward "\r\n\r\n" nil t))
      (buffer-substring (point) (point-max)))))

(provide 'shr)

;;; shr.el ends here