;;; mu4e-query-items.el -- part of mu4e -*- lexical-binding: t -*-

;; Copyright (C) 2023 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>

;; This file is not part of GNU Emacs.

;; mu4e is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; mu4e is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with mu4e.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Managing the last query results / baseline, which we use to get the
;; unread-counts, i.e., query items. `mu4e-query-items` delivers these items,
;; aggregated from various sources.


;;; Code:

;;; Last & baseline query results for bookmarks.
(require 'cl-lib)
(require 'mu4e-helpers)
(require 'mu4e-server)

(defvar mu4e--query-items-baseline nil
  "Some previous version of the query-items.
This is used as the baseline to track updates by comparing it to
the latest query-items.")
(defvar mu4e--query-items-baseline-tstamp nil
  "Timestamp for when the query-items baseline was updated.")

(defun mu4e--bookmark-query (bm)
  "Get query string for some bookmark BM."
  (when bm
    (let* ((query (or (plist-get bm :query)
                      (mu4e-warn "No query in %S" bm)))
           ;; queries being functions is deprecated.
           (query (if (functionp query) (funcall query) query)))
      ;; earlier, we allowed for the queries being fucntions
      (unless (stringp query)
        (mu4e-warn "Could not get query string from %s" bm))
      ;; apparently, non-UTF8 queries exist, i.e.,
      ;; with maild dir names.
      (decode-coding-string query 'utf-8 t))))

(defun mu4e--query-items-pick-favorite (items)
  "Pick the :favorite querty item.
If ITEMS does not yet have a favorite item, pick the first."
  (unless (seq-find
           (lambda (item) (plist-get item :favorite)) items)
    (plist-put (car items) :favorite t))
  items)

(defvar mu4e--bookmark-items-cached nil "Cached bookmarks query items.")
(defvar mu4e--maildir-items-cached nil "Cached maildirs query items.")

(declare-function  mu4e-bookmarks "mu4e-bookmarks")
(declare-function  mu4e-maildir-shortcuts "mu4e-folders")

(defun mu4e--query-items-reset ()
  "Reset the query items."
  (setq mu4e--bookmark-items-cached nil
        mu4e--maildir-items-cached nil)
  (run-hooks 'mu4e-query-items-updated-hook))

(defun mu4e--query-items-reset-baseline ()
  "Reset the baseline query-items."
  (setq mu4e--query-items-baseline (mu4e-server-query-items)
        mu4e--query-items-baseline-tstamp (current-time))
  (mu4e--query-items-reset))

(defun mu4e--query-item-display-counts (item)
  "Get the count display string for some query-data ITEM."
  ;; purely for display, but we need it in the main menu, modeline
  ;; so let's keep it consistent.
  (cl-destructuring-bind (&key unread hide-unread delta-unread count
                               &allow-other-keys) item
    (if hide-unread
        ""
      (concat
       (propertize (number-to-string unread)
                   'face 'mu4e-header-key-face
                   'help-echo "Number of unread")
       (if (<= delta-unread 0) ""
         (propertize (format "(%+d)" delta-unread) 'face
                     'mu4e-unread-face))
       "/"
       (propertize (number-to-string count)
                   'help-echo "Total number")))))


(defun mu4e--query-items-refresh()
  "Get the latest query data from the mu4e server."
  (mu4e--server-queries
   (mapcar #'mu4e--bookmark-query
           (seq-filter (lambda (item)
                         (and (not (or (plist-get item :hide)
                                       (plist-get item :hide-unread)))))
                       (mu4e-query-items)))))

(defun mu4e--query-items-queries-handler (_sexp)
  "Handler for queries responses from the mu4e-server.
I.e. what we get in response to mu4e--query-items-refresh."
  ;; if we don't have a baseline yet, set it. (note that
  ;; mu4e--query-items-reset-baseline also calls mu4e--query-items-reset.
  (if (not mu4e--query-items-baseline)
      (progn
        (mu4e--query-items-reset-baseline))
    (mu4e--query-items-reset))
  ;; for side-effects; recalculate.
  (mu4e-query-items))

;; this makes for O(n*m)... but with typically small(ish) n,m. Perhaps use a
;; hash for last-query-items and baseline-results?
(defun mu4e--query-find-item (query data)
  "Find the item in DATA for the given QUERY."
  (seq-find (lambda (item)
              (equal query (mu4e--bookmark-query item)))
            data))

(defun mu4e--make-query-items (data type)
  "Map the items in DATA to plists with aggregated query information.

DATA is either the bookmarks or maildirs (user-defined).

LAST-RESULTS-DATA contains unread/counts we received from the
server, while BASELINE-DATA contains the same but taken at some
earier time.

The TYPE denotes the category for the query item, a symbol
bookmark or maildir."
  (seq-map
   (lambda (item)
     (let* ((maildir (plist-get item :maildir))
            ;; for maildirs, construct the query
            (query (if (equal type 'maildirs)
                       (format "maildir:\"%s\"" maildir)
                     (plist-get item :query)))
            (name (plist-get item :name))
            ;; maildir items may have an implicit name
            ;; which is the maildir value.
            (name (or name (and (equal type 'maildirs) maildir)))

            (last-results (mu4e-server-query-items))
            (baseline mu4e--query-items-baseline)

            (baseline-item (mu4e--query-find-item query baseline))
            (last-results-item (mu4e--query-find-item query last-results))
            (count  (or (plist-get last-results-item :count) 0))
            (unread (or (plist-get last-results-item :unread) 0))
            (baseline-count  (or (plist-get baseline-item :count) count))
            (baseline-unread (or (plist-get baseline-item :unread) unread))
            (delta-unread (- unread baseline-unread))
            (value
             (list
              :name         name
              :query        query
              :key          (plist-get item :key)
              :count        count
              :unread       unread
              :delta-count  (- count baseline-count)
              :delta-unread delta-unread)))

       ;; nil props bring me discomfort
       (when (plist-get item :favorite)
         (plist-put value :favorite t))
       (when (plist-get item :hide)
         (plist-put value :hide t))
       (when (plist-get item :hide-unread)
         (plist-put value :hide-unread t))
       value))
   data))

;; Note: uipdating is lazy, only happens with the first caller to
;; mu4e-query items.
(defvar mu4e-query-items-updated-hook nil
  "Hook run when the query items have been updated.")

(defun mu4e-query-items (&optional type)
  "Grab query items of TYPE.

TYPE is symbol; either bookmarks or maildirs, or nil for both.

This combines:
     - the latest queries data (i.e., `(mu4e-server-query-items)')
     - baseline queries data (i.e. `mu4e-baseline')
   with the combined queries for `(mu4e-bookmarks)' and
    `(mu4e-maildir-shortcuts)' in bookmarks-compatible plists.

This packages the aggregated information in a format that is convenient
for use in various places."
  (cond
   ((equal type 'bookmarks)
    (or mu4e--bookmark-items-cached
        (setq mu4e--bookmark-items-cached
              (mu4e--query-items-pick-favorite
               (mu4e--make-query-items (mu4e-bookmarks) 'bookmarks)))))
   ((equal type 'maildirs)
    (or mu4e--maildir-items-cached
        (setq mu4e--maildir-items-cached
              (mu4e--make-query-items (mu4e-maildir-shortcuts) 'maildirs))))
   ((not type)
    (append (mu4e-query-items 'bookmarks)
            (mu4e-query-items 'maildirs)))
   (t
    (mu4e-error "No such type %s" type))))

(provide 'mu4e-query-items)
;;; mu4e-query-data.el ends here