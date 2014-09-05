;;; vlf-tune.el --- VLF tuning operations  -*- lexical-binding: t -*-

;; Copyright (C) 2014 Free Software Foundation, Inc.

;; Keywords: large files, batch size, performance
;; Author: Andrey Kotlarski <m00naticus@gmail.com>
;; URL: https://github.com/m00natic/vlfi

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;; This package provides wrappers for basic chunk operations that add
;; time statistics and automatic tuning of `vlf-batch-size' for
;; optimal performance.

;;; Code:

(defcustom vlf-tune-enabled t
  "Whether to allow automatic change of batch size.
If nil, completely disable.  If `stats', maintain measure statistics,
but don't change batch size.  If t, measure and change."
  :group 'vlf :type '(choice (const :tag "Enabled" t)
                             (const :tag "Just statistics" stats)
                             (const :tag "Disabled" nil)))

(defvar vlf-file-size 0 "Total size in bytes of presented file.")
(make-variable-buffer-local 'vlf-file-size)
(put 'vlf-file-size 'permanent-local t)

(defun vlf-tune-ram-size ()
  "Try to determine RAM size in bytes."
  (if (executable-find "free")
      (let* ((free (shell-command-to-string "free"))
             (match-from (string-match "[[:digit:]]+" free)))
        (if match-from
            (* 1000 (string-to-number (substring free match-from
                                                 (match-end 0))))))))

(defcustom vlf-tune-max (let ((ram-size (vlf-tune-ram-size)))
                          (if ram-size
                              (/ ram-size 20)
                            large-file-warning-threshold))
  "Maximum batch size in bytes when auto tuning."
  :group 'vlf :type 'integer)

(defcustom vlf-tune-step (/ vlf-tune-max 1000)
  "Step used for tuning in bytes."
  :group 'vlf :type 'integer)

(defvar vlf-tune-insert-bps nil
  "Vector of bytes per second insert measurements.")
(make-variable-buffer-local 'vlf-tune-insert-bps)
(put 'vlf-tune-insert-bps 'permanent-local t)

(defvar vlf-tune-insert-raw-bps nil
  "Vector of bytes per second non-decode insert measurements.")
(make-variable-buffer-local 'vlf-tune-insert-raw-bps)
(put 'vlf-tune-insert-raw-bps 'permanent-local t)

(defvar vlf-tune-encode-bps nil
  "Vector of bytes per second encode measurements.")
(make-variable-buffer-local 'vlf-tune-encode-bps)
(put 'vlf-tune-encode-bps 'permanent-local t)

(defvar vlf-tune-write-bps nil
  "Vector of bytes per second write measurements.")
(make-variable-buffer-local 'vlf-tune-write-bps)
(put 'vlf-tune-write-bps 'permanent-local t)

(defvar vlf-tune-hexl-bps nil
  "Vector of bytes per second hexlify measurements.")
(make-variable-buffer-local 'vlf-tune-hexl-bps)
(put 'vlf-tune-hexl-bps 'permanent-local t)

(defvar vlf-tune-dehexlify-bps nil
  "Vector of bytes per second dehexlify measurements.")
(make-variable-buffer-local 'vlf-tune-dehexlify-bps)
(put 'vlf-tune-dehexlify-bps 'permanent-local t)

(defun vlf-tune-closest-index (size)
  "Get closest measurement index corresponding to SIZE."
  (let ((step (float vlf-tune-step)))
    (max 0 (1- (min (round size step) (round vlf-tune-max step))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; bookkeeping

(defun vlf-tune-initialize-measurement ()
  "Initialize measurement vector."
  (make-vector (/ vlf-tune-max vlf-tune-step) '(0 . 0)))

(defmacro vlf-tune-add-measurement (vec size time)
  "Add at an appropriate position in VEC new SIZE TIME measurement.
VEC is a vector of (mean time . count) elements ordered by size."
  `(when (and vlf-tune-enabled (not (zerop ,size)))
     (or ,vec (setq ,vec (vlf-tune-initialize-measurement)))
     (let* ((idx (vlf-tune-closest-index ,size))
            (existing (aref ,vec idx))
            (existing-val (car existing)))
       (aset ,vec idx (let ((count (1+ (cdr existing)))) ;recalculate mean
                        (cons (/ (+ (* (1- count)
                                       (if (= existing-val -1) 0
                                         existing-val))
                                    (/ ,size ,time))
                                 count)
                              count))))))

(defmacro vlf-time (&rest body)
  "Get timing consed with result of BODY execution."
  `(let ((time (float-time))
         (result (progn ,@body)))
     (cons (- (float-time) time) result)))

(defun vlf-tune-insert-file-contents (start end)
  "Extract decoded file bytes START to END and save time it takes."
  (let ((result (vlf-time (insert-file-contents buffer-file-name
                                                nil start end))))
    (vlf-tune-add-measurement vlf-tune-insert-bps
                              (- end start) (car result))
    (cdr result)))

(defun vlf-tune-insert-file-contents-literally (start end)
  "Insert raw file bytes START to END and save time it takes."
  (let ((result (vlf-time (insert-file-contents-literally
                           buffer-file-name nil start end))))
    (vlf-tune-add-measurement vlf-tune-insert-raw-bps
                              (- end start) (car result))
    (cdr result)))

(defun vlf-tune-encode-length (start end)
  "Get length of encoded region START to END and save time it takes."
  (let ((result (vlf-time (length (encode-coding-region
                                   start end
                                   buffer-file-coding-system t)))))
    (vlf-tune-add-measurement vlf-tune-encode-bps
                              (cdr result) (car result))
    (cdr result)))

(defun vlf-tune-write (start end append visit size)
  "Save buffer and save time it takes.
START, END, APPEND, VISIT have same meaning as in `write-region'.
SIZE is number of bytes that are saved."
  (let ((time (car (vlf-time (write-region start end buffer-file-name
                                           append visit)))))
    (vlf-tune-add-measurement vlf-tune-write-bps size time)))

(defun vlf-tune-hexlify ()
  "Activate `hexl-mode' and save time it takes."
  (let ((time (car (vlf-time (hexl-mode)))))
    (vlf-tune-add-measurement vlf-tune-hexl-bps
                              hexl-max-address time)))

(defun vlf-tune-dehexlify ()
  "Exit `hexl-mode' and save time it takes."
  (let ((time (car (vlf-time (hexl-mode-exit)))))
    (vlf-tune-add-measurement vlf-tune-dehexlify-bps
                              hexl-max-address time)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; tuning

(defun vlf-tune-approximate-nearby (vec index)
  "VEC has value for INDEX, approximate to closest available."
  (let ((val 0)
        (left-idx (1- index))
        (right-idx (1+ index))
        (max (length vec)))
    (while (and (zerop val) (or (<= 0 left-idx)
                                (< right-idx max)))
      (if (<= 0 left-idx)
          (let ((left (car (aref vec left-idx))))
            (if (and (not (zerop left)) (/= left -1))
                (setq val left))))
      (if (< right-idx max)
          (let ((right (car (aref vec right-idx))))
            (if (and (not (zerop right)) (/= right -1))
                (setq val (if (zerop val)
                              right
                            (/ (+ val right) 2))))))
      (setq left-idx (1- left-idx)
            right-idx (1+ right-idx)))
    val))

(defmacro vlf-tune-approximate (vec index)
  "Unless VEC has value for INDEX, approximate to closest available."
  `(if ,vec
       (let ((val (car (aref ,vec ,index))))
         (cond ((zerop val)
                (aset ,vec ,index '(-1 . 0)) ;mark element as tried once
                0)
               ((= val -1) ;index has been tried before, yet still no value
                (vlf-tune-approximate-nearby ,vec ,index))
               (t val)))))

(defun vlf-tune-assess (type coef index)
  "Get measurement value according to TYPE, COEF and INDEX."
  (* coef (or (cond ((eq type :insert)
                     (vlf-tune-approximate vlf-tune-insert-bps index))
                    ((eq type :raw)
                     (vlf-tune-approximate vlf-tune-insert-raw-bps
                                           index))
                    ((eq type :encode)
                     (vlf-tune-approximate vlf-tune-encode-bps index))
                    ((eq type :write)
                     (vlf-tune-approximate vlf-tune-write-bps index))
                    ((eq type :hexl)
                     (if vlf-tune-hexl-bps
                         (car (aref vlf-tune-hexl-bps index))))
                    ((eq type :dehexlify)
                     (if vlf-tune-dehexlify-bps
                         (car (aref vlf-tune-dehexlify-bps index)))))
              0)))

(defun vlf-tune-score (types index)
  "Calculate cumulative speed over TYPES for INDEX."
  (catch 'result
    (let ((time 0)
          (size (* (1+ index) vlf-tune-step)))
      (dolist (el types (/ size time))
        (let ((bps (if (consp el)
                       (vlf-tune-assess (car el) (cadr el) index)
                     (vlf-tune-assess el 1 index))))
          (if (zerop bps)
              (throw 'result nil)
            (setq time (+ time (/ size bps)))))))))

(defun vlf-tune-conservative (types &optional index)
  "Adjust `vlf-batch-size' to best nearby value over TYPES.
INDEX if given, specifies search independent of current batch size."
  (if (eq vlf-tune-enabled t)
      (let* ((half-max (/ (1+ vlf-file-size) 2))
             (idx (or index (vlf-tune-closest-index vlf-batch-size)))
             (curr (if (< half-max (* idx vlf-tune-step)) t
                     (vlf-tune-score types idx))))
        (if curr
            (let ((prev (if (zerop idx) t
                          (vlf-tune-score types (1- idx)))))
              (if prev
                  (let ((next (if (or (eq curr t)
                                      (< half-max (* (1+ idx)
                                                     vlf-tune-step)))
                                  t
                                (vlf-tune-score types (1+ idx)))))
                    (cond ((null next)
                           (setq vlf-batch-size (* (+ 2 idx)
                                                   vlf-tune-step)))
                          ((eq curr t)
                           (or (eq prev t)
                               (setq vlf-batch-size
                                     (* idx vlf-tune-step))))
                          (t (let ((best-idx idx))
                               (and (numberp prev) (< curr prev)
                                    (setq curr prev
                                          best-idx (1- idx)))
                               (and (numberp next) (< curr next)
                                    (setq best-idx (1+ idx)))
                               (setq vlf-batch-size
                                     (* (1+ best-idx)
                                        vlf-tune-step))))))
                (setq vlf-batch-size (* idx vlf-tune-step))))
          (setq vlf-batch-size (* (1+ idx) vlf-tune-step))))))

(defun vlf-tune-binary (types min max)
  "Adjust `vlf-batch-size' to optimal value using binary search, \
optimizing over TYPES.
MIN and MAX specify interval of indexes to search."
  (let ((sum (+ min max)))
    (if (< (- max min) 3)
        (vlf-tune-conservative types (/ sum 2))
      (let* ((left-idx (round (+ sum (* 2 min)) 4))
             (left (vlf-tune-score types left-idx)))
        (if left
            (let* ((right-idx (round (+ sum (* 2 max)) 4))
                   (right (vlf-tune-score types right-idx)))
              (cond ((null right)
                     (setq vlf-batch-size (* (1+ right-idx)
                                             vlf-tune-step)))
                    ((< left right)
                     (vlf-tune-binary types (/ (1+ sum) 2) max))
                    (t (vlf-tune-binary types min (/ sum 2)))))
          (setq vlf-batch-size (* (1+ left-idx) vlf-tune-step)))))))

(defun vlf-tune-linear (types max-idx)
  "Adjust `vlf-batch-size' to optimal value using linear search, \
optimizing over TYPES up to MAX-IDX."
  (let ((best-idx 0)
        (best-bps 0)
        (idx 0)
        (none-missing t))
    (while (and none-missing (<= idx max-idx))
      (let ((bps (vlf-tune-score types idx)))
        (cond ((null bps)
               (setq vlf-batch-size (* (1+ idx) vlf-tune-step)
                     none-missing nil))
              ((< best-bps bps) (setq best-idx idx
                                      best-bps bps))))
      (setq idx (1+ idx)))
    (or (not none-missing)
        (setq vlf-batch-size (* (1+ best-idx) vlf-tune-step)))))

(defun vlf-tune-optimal (types &optional linear)
  "Adjust `vlf-batch-size' to optimal value optimizing on TYPES.
TYPES is alist of elements that may be of form (type coef) or
non list values in which case coeficient is assumed 1.
Types can be :insert, :raw, :encode, :write, :hexl or :dehexlify.
If LINEAR is non nil, use brute-force."
  (if (eq vlf-tune-enabled t)
      (let ((max-idx (1- (/ (min vlf-tune-max
                                 (/ (1+ vlf-file-size) 2))
                            vlf-tune-step))))
        (cond (linear (vlf-tune-linear types max-idx))
              ((file-remote-p buffer-file-name)
               (vlf-tune-conservative types))
              ((<= 1 max-idx)
               (if (< max-idx 3)
                   (vlf-tune-conservative types (/ max-idx 2))
                 (vlf-tune-binary types 0 max-idx)))))))

(provide 'vlf-tune)

;;; vlf-tune.el ends here
