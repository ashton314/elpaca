;;; parcel.el --- An elisp package manager           -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Nicholas Vollmer

;; Author: Nicholas Vollmer
;; URL: https://github.com/progfolio/parcel
;; Created: Jan 1, 2022
;; Keywords: tools, convenience, lisp
;; Package-Requires: ((emacs "26.1"))
;; Version: 0.0.0

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; An elisp package manager

;;; Code:
(require 'cl-lib)
(require 'parcel-process)

(defgroup parcel nil
  "An elisp package manager."
  :group 'parcel
  :prefix "parcel-")

(defcustom parcel-directory (expand-file-name "parcel" user-emacs-directory)
  "Location of the parcel package store."
  :type 'directory)

(defun parcel-order-defaults (_order)
  "Default order modifications. Matches any order."
  (list :protocol 'https :remotes "origin" :inherit t :depth 1))

(defcustom parcel-order-functions (list #'parcel-order-defaults)
  "Abnormal hook run to alter orders.
Each element must be a unary function which accepts an order.
An order may be nil, a symbol naming a package, or a plist.
The function may return nil or a plist to be merged with the order.
This hook is run via `run-hook-with-args-until-success'."
  :type 'hook)

(defcustom parcel-recipe-functions nil
  "Abnormal hook run to alter recipes.
Each element must be a unary function which accepts an recipe plist.
The function may return nil or a plist to be merged with the recipe.
This hook is run via `run-hook-with-args-until-success'."
  :type 'hook)

(defcustom parcel-menu-functions '(parcel-menu-org parcel-menu-melpa parcel-menu-gnu-elpa-mirror)
  "Abnormal hook to lookup packages in menus.
Each function is passed a request, which may be any of the follwoing symbols:
  - `index`
     Must return a alist of the menu's package candidates.
     Each candidate is a cell of form:
     (PACKAGE-NAME . (:source SOURCE-NAME :recipe RECIPE-PLIST))
  - `update`
     Updates the menu's package candidate list."
  :type 'hook)

(defvar parcel-recipe-keywords (list :pre-build :branch :depth :fork :host
                                     :nonrecursive :package :protocol :remote :repo)
  "Recognized parcel recipe keywords.")

(defun parcel-plist-p (obj)
  "Return t if OBJ is a plist of form (:key val...)."
  (and obj
       (listp obj)
       (zerop (mod (length obj) 2))
       (cl-every #'keywordp (cl-loop for (key _) on obj by #'cddr collect key))))

(defun parcel-merge-plists (&rest plists)
  "Return plist with set of unique keys from PLISTS.
Values for each key are that of the right-most plist containing that key."
  (let ((plists (delq nil plists))
        current plist)
    (while (setq current (pop plists))
      (while current (setq plist (plist-put plist (pop current) (pop current)))))
    plist))

(defun parcel-clean-plist (plist)
  "Return PLIST copy sans keys which are not members of `parcel-recipe-keywords'."
  (apply #'append (cl-loop for key in parcel-recipe-keywords
                           for member = (plist-member plist key)
                           collect (when member
                                     (cl-subseq (plist-member plist key) 0 2)))))

(defun parcel-menu--candidates ()
  "Return alist of `parcel-menu-functions' candidates."
  (sort (apply #'append
               (cl-loop for fn in parcel-menu-functions
                        for index = (funcall fn 'index)
                        when index collect index))
        (lambda (a b) (string-lessp (car a) (car b)))))

(defvar parcel-overriding-prompt nil "Overriding prompt for interactive functions.")

;;@TODO: clean up interface.
;;;###autoload
(defun parcel-menu-item (&optional interactive symbol menus)
  "Return menu item matching SYMBOL in MENUS or `parcel-menu-functions'.
If SYMBOL is nil, prompt for it.
If INTERACTIVE is equivalent to \\[universal-argument] prompt for MENUS."
  (interactive "P")
  (let* ((menus (if interactive
                    (mapcar #'intern-soft
                            (cl-remove-duplicates
                             (completing-read-multiple
                              "Menus: "
                              parcel-menu-functions
                              nil 'require-match)
                             :test #'equal))
                  (or menus parcel-menu-functions (user-error "No menus found"))))
         (parcel-menu-functions menus)
         (candidates (parcel-menu--candidates))
         (symbol (or symbol
                     (intern-soft
                      (completing-read (or parcel-overriding-prompt "Package: ")
                                       candidates nil t))))
         (candidate (alist-get symbol candidates))
         (recipe (plist-get candidate :recipe)))
    (if (called-interactively-p 'interactive)
        (progn
          (unless recipe (user-error "No menu recipe for %s" symbol))
          (message "%S menu recipe for %s: %S"
                   (plist-get candidate :source) symbol recipe))
      recipe)))

(defsubst parcel--inheritance-disabled-p (plist)
  "Return t if PLIST explicitly has :inherit nil key val, nil otherwise."
  (when-let ((member (plist-member plist :inherit)))
    (not (cadr member))))

;;;###autoload
(defun parcel-recipe (&optional order)
  "Return recipe computed from ORDER.
ORDER is any of the following values:
  - nil. The order is prompted for.
  - a symbol which will be looked up via `parcel-menu-functions'
  - an order list."
  (interactive)
  (let ((parcel-overriding-prompt "Recipe: ")
        (interactive (called-interactively-p 'interactive))
        package
        ingredients)
    (cond
     ((or (null order) (symbolp order))
      (let ((menu-item (parcel-menu-item nil order)))
        (unless menu-item (user-error "No menu-item for %S" order))
        (push (run-hook-with-args-until-success 'parcel-order-functions order)
              ingredients)
        (push menu-item ingredients)))
     ((listp order)
      (setq package (pop order))
      (unless (parcel--inheritance-disabled-p order)
        (let ((mods (run-hook-with-args-until-success 'parcel-order-functions order)))
          (push mods ingredients)
          (when (or (plist-get order :inherit) (plist-get mods :inherit))
            (push (parcel-menu-item nil package) ingredients))))
      (setq ingredients (append ingredients (list order))))
     (t (signal 'wrong-type-argument `((null symbolp listp) . ,order))))
    (if-let ((recipe (apply #'parcel-merge-plists ingredients)))
        (progn
          (unless (plist-get recipe :package)
            (setq recipe (plist-put recipe :package (format "%S" package))))
          (setq recipe
                (parcel-merge-plists
                 recipe
                 (run-hook-with-args-until-success 'parcel-recipe-functions recipe)))
          (if interactive (message "%S" recipe)) recipe)
      (when interactive (user-error "No recipe for %S" package)))))

(defsubst parcel--repo-name (string)
  "Return repo name portion of STRING."
  (substring string (1+ (string-match-p "/" string))))

(defsubst parcel--repo-user (string)
  "Return user name portion of STRING."
  (substring string 0 (string-match-p "/" string)))

(defun parcel-repo-dir (recipe)
  "Return path to repo given RECIPE."
  (cl-destructuring-bind (&key local-repo repo fetcher (host fetcher) &allow-other-keys)
      recipe
    (expand-file-name
     ;;repo-or-local-repo.user.host
     (string-join (list (or local-repo (parcel--repo-name repo))
                        (parcel--repo-user repo)
                        (symbol-name host))
                  ".")
     parcel-directory)))

(defun parcel--repo-uri (recipe)
  "Return repo URI from RECIPE."
  (cl-destructuring-bind (&key (protocol 'https)
                               fetcher
                               (host fetcher)
                               repo &allow-other-keys)
      recipe
    (let ((protocol (pcase protocol
                      ('https '("https://" . "/"))
                      ('ssh   '("git@" . ":"))
                      (_      (signal 'wrong-type-argument `((https ssh) ,protocol)))))
          (host     (pcase host
                      ('github       "github.com")
                      ('gitlab       "gitlab.com")
                      ((pred stringp) host)
                      (_              (signal 'wrong-type-argument
                                              `((github gitlab stringp) ,host))))))
      (format "%s%s%s%s.git" (car protocol) host (cdr protocol) repo))))

(defun parcel--add-remotes (recipe)
  "Given RECIPE, add repo remotes."
  (let ((default-directory (parcel-repo-dir recipe)))
    (cl-destructuring-bind
        (&key remotes
              ((:host recipe-host))
              ((:protocol recipe-protocol))
              ((:repo recipe-repo)) &allow-other-keys)
        recipe
      (pcase remotes
        ("origin" nil)
        ((and (pred stringp) remote)
         (parcel-process-call "git" "remote" "rename" "origin" remote))
        ((pred listp)
         (dolist (spec remotes)
           (if (stringp spec)
               (parcel--add-remotes (plist-put (copy-tree recipe) :remotes spec))
             (pcase-let ((`(,remote . ,props) spec))
               (if props
                   (cl-destructuring-bind
                       (&key (host     recipe-host)
                             (protocol recipe-protocol)
                             (repo     recipe-repo)
                             &allow-other-keys
                             &aux
                             (recipe (list :host host :protocol protocol :repo repo)))
                       props
                     (parcel-process-call
                      "git" "remote" "add" remote (parcel--repo-uri recipe)))
                 (unless (equal remote "origin")
                   (parcel-process-call "git" "remote" "rename" "origin" remote)))))))
        (_ (signal 'wrong-type-argument `((stringp listp) ,remotes ,recipe)))))))

(defun parcel--checkout-ref (recipe)
  "Checkout RECIPE's :ref.
The :branch and :tag keywords are syntatic sugar and are handled here, too."
  (let ((default-directory (parcel-repo-dir recipe)))
    (cl-destructuring-bind (&key ref branch tag remotes &allow-other-keys)
        recipe
      (when (or ref branch tag)
        (cond
         ((and ref branch) (warn "Recipe :ref overriding :branch %S" recipe))
         ((and ref tag)    (warn "Recipe :ref overriding :tag %S" recipe))
         ((and tag branch) (error "Recipe ambiguous :tag and :branch %S" recipe)))
        (unless remotes    (signal 'wrong-type-argument
                                   `((stringp listp) ,remotes ,recipe)))
        (parcel-process-call "git" "fetch" "--all")
        (let* ((remote (if (stringp remotes) remotes (caar remotes))))
          (parcel-with-process
              (apply #'parcel-process-call
                     `("git"
                       ,@(delq nil
                               (cond
                                (ref    (list "checkout" ref))
                                (tag    (list "checkout" (concat ".git/refs/tags/" tag)))
                                (branch (list "switch" "-C" branch
                                              (format "%s/%s" remote branch)))))))
            (if success t
              (error "Unable to check out ref: %S %S" stderr recipe))))))))

(defun parcel-clone (recipe)
  "Clone package repository to `parcel-directory' using RECIPE."
  (cl-destructuring-bind (&key fetcher (host fetcher) &allow-other-keys)
      recipe
    (unless host (user-error "No :host in recipe %S" recipe))
    (let* ((default-directory parcel-directory))
      ;;@TODO: handle errors
      (apply #'parcel-process-call
             (delq nil (list "git" "clone" (parcel--repo-uri recipe)
                             (parcel-repo-dir recipe)))))))

(defun parcel--initialize-repo (recipe)
  "Using RECIPE, Clone repo, add remotes, check out :ref."
  (parcel-clone recipe)
  (parcel--add-remotes recipe)
  (parcel--checkout-ref recipe))

(defvar parcel--package-requires-regexp
  "\\(?:^;+[[:space:]]*Package-Requires[[:space:]]*:[[:space:]]*\\([^z-a]*?$\\)\\)"
  "Regexp matching the Package-Requires metadata in an elisp source file.")

(defun parcel--dependencies (recipe)
  "Using RECIPE, compute package's dependencies.
If package's repo is not on disk, error."
  (let* ((default-directory (parcel-repo-dir recipe))
         (pkg (expand-file-name (format "%s-pkg.el" (plist-get recipe :package))))
         (defined (file-exists-p pkg))
         (main (format "%s.el" (plist-get recipe :package))))
    (unless (file-exists-p default-directory)
      (error "Package repository not on disk: %S" recipe))
    (with-temp-buffer
      (insert-file-contents-literally (if defined pkg main))
      (goto-char (point-min))
      (if defined
          (eval (nth 4 (read (current-buffer))))
        (let ((case-fold-search t))
          (when (re-search-forward parcel--package-requires-regexp nil 'noerror)
            (condition-case err
                (read (match-string 1))
              (error "Unable to parse %S Package-Requires metadata: %S" main err))))))))

(defvar parcel--queued-orders nil "List of queued orders.")

(defun parcel--emacs-path ()
  "Return path to running Emacs."
  (concat invocation-directory invocation-name))

;;;###autoload
(defun parcel (order &optional callback)
  "ORDER CALLBACK."
  (let* ((recipe  (parcel-recipe order))
         (package (plist-get recipe :package)))
    (unless (member package parcel--queued-orders)
      (push package parcel--queued-orders)
      (let ((proc-name (format "parcel-%s" package)))
        (make-process
         :name proc-name
         :buffer proc-name
         :command (list (parcel--emacs-path)
                        "-L" parcel-directory
                        "-L" (expand-file-name "parcel" parcel-directory)
                        "-l" (expand-file-name "parcel/parcel.el" parcel-directory)
                        "--batch"
                        "--eval" (format "(parcel--initialize-repo '%S)" recipe))
         :sentinel (lambda (proc event)
                     (when (equal event "finished\n")
                       (setq parcel--queued-orders
                             (cl-remove
                              (replace-regexp-in-string "^parcel-" "" (process-name proc))
                              parcel--queued-orders
                              :test #'equal))
                       (funcall callback recipe)))
         :noquery t)))))

(defvar parcel-ignored-dependencies '(cl-lib org map)
  "Built in packages.
Ignore these unless the user explicitly requests they be installed.")

(defun parcel--process-dependencies (recipe)
  "Using RECIPE, compute dependencies and kick off their subprocesses."
  (dolist (dependency (parcel--dependencies recipe))
    (pcase-let ((`(,package ,version) dependency))
      (if (equal package 'emacs)
          (when (version< emacs-version version)
            (error "Emacs version too low for %S: %S"
                   (plist-get recipe :package)
                   recipe))
        (unless (member package parcel-ignored-dependencies)
          (parcel package #'parcel--process-dependencies))))))

(declare-function autoload-rubric "autoload")
(defvar autoload-timestamps)
(defun parcel-generate-autoloads (package dir)
  "Generate autoloads in DIR for PACKAGE."
  (let* ((auto-name (format "%s-autoloads.el" package))
         (output    (expand-file-name auto-name dir))
         (autoload-timestamps nil)
         (backup-inhibited t)
         (version-control 'never))
    (unless (file-exists-p output)
      (require 'autoload)
      (write-region (autoload-rubric output "package" nil) nil output nil 'silent))
    (make-directory-autoloads dir output)
    (when-let ((buf (find-buffer-visiting output)))
      (kill-buffer buf))
    auto-name))


;;;ASYNC
(eval-and-compile
  (defun parcel--ensure-list (obj)
    "Ensure OBJ is a list."
    (if (listp obj) obj (list obj))))

(defmacro parcel-thread-callbacks (&rest fns)
  "Place each FN in FNS in callback position of previous FN."
  (declare (debug t))
  (let* ((reversed (reverse fns))
         (last `((lambda () ,(parcel--ensure-list (pop reversed))))))
    (mapc (lambda (fn)
            (setq last `((lambda () ,(append (parcel--ensure-list fn) last)))))
          reversed)
    ;; Ditch wrapping lambda of first call
    (nth 2 (pop last))))

(defun parcel-clone-async (recipe callback)
  "Clone package repository to `parcel-directory' Asynchronously.
RECIPE is used to determine package details.
Execute CALLBACK when finished."
  (cl-destructuring-bind (&key package fetcher (host fetcher) &allow-other-keys)
      recipe
    (unless host (user-error "No :host in recipe %S" recipe))
    (let* ((default-directory parcel-directory)
           (proc (delq nil (list "git" "clone" (parcel--repo-uri recipe)
                                 (parcel-repo-dir recipe)))))
      (eval `(parcel-with-async-process ,proc
               (if success
                   (funcall (function ,callback))
                 (error "Failed to clone %S: %S" ,package result)))
            t))))

(defun parcel-clone-deps-aysnc (recipe &optional _callback)
  "Clone RECIPE's dependencies, then CALLBACK."
  (dolist (spec (parcel--dependencies recipe))
    (pcase-let ((`(,dependency ,version) spec))
      (if (equal dependency 'emacs)
          (when (version< emacs-version version)
            (error "Emacs version too low for %S: %S"
                   (plist-get recipe :package)
                   recipe))
        (unless (member dependency parcel-ignored-dependencies)
          (message "recipe: %S callback: %S"
           recipe
           (lambda () (message "dependency %S cloned" dependency))))))))

;; (let ((recipe (parcel-recipe 'doct)))
;;   (parcel-test-clean-repos)
;;   (parcel-thread-callbacks
;;    (parcel-clone-async recipe)
;;    (parcel-clone-deps-async recipe)))


;; (let ((queued-orders
;;        (list '(doct
;;                :recipe (parcel-recipe 'doct)
;;                :subs nil
;;                :pubs nil)
;;              '(wikinforg
;;                :recipe (parcel-recipe 'wikinforg)
;;                :subs nil
;;                :pubs nil))))
;;   queued-orders)




(provide 'parcel)
;;; parcel.el ends here
