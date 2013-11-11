;;; scala-mode.el - Functions for discovering the current sbt project
;;
;; Copyright(c) 2013 Heikki Vesalainen
;; For information on the License, see the LICENSE file

(require 'compile)
(require 'comint)
(require 'sbt-mode-project)
(require 'sbt-mode-buffer)
(require 'sbt-mode-comint)
(require 'sbt-mode-rgrep)

(eval-when-compile
  (defun scala-mode:set-scala-syntax-mode ()))

(defcustom sbt:program-name "sbt"
  "Program invoked by the `sbt:run-sbt' command."
  :type 'string
  :group 'sbt)

(defcustom sbt:default-command "test:compile"
  "The default command to run with sbt:command."
  :type 'string
  :group 'sbt)

(defcustom sbt:save-some-buffers t
  "Whether to run save-some-buffers before running a command."
  :type 'boolean
  :group 'sbt)

(defvar sbt:previous-command sbt:default-command)
(make-variable-buffer-local 'sbt:previous-command)

(defvar sbt:command-history-temp nil)

(defgroup sbt nil
  "Support for sbt build REPL."
  :group 'sbt
  :prefix "sbt:")

;;;
;;; Our user commands
;;;

;;;###autoload
(defun sbt-start () "Start sbt" (interactive) (sbt:run-sbt nil t))

(defun sbt-clear () 
  "Clear the current sbt buffer and send RET to sbt to re-display the prompt"
  (interactive) (sbt:clear))

;;;###autoload
(defun sbt-command (command)
  "Send a command to the sbt running in the '*sbt*name'
buffer. Prompts for the command to send when in interactive
mode. You can use tab completion.

This command does the following:
  - displays the buffer without moving focus to it
  - erases the buffer
  - forgets about compilation errors

The command is most usefull for running a compilation command
that outputs errors."
  (interactive 
   (progn
     (setq sbt:command-history-temp 
           (ignore-errors (with-current-buffer (sbt:buffer-name) (ring-elements comint-input-ring))))
     
     (list (completing-read (format "Command to run (default %s): " (sbt:get-previous-command))
                            (completion-table-dynamic 'sbt:get-sbt-completions)
                            nil nil nil 'sbt:command-history-temp (sbt:get-previous-command)))))
  (sbt:command command))

;;;###autoload
(defun sbt-run-previous-command ()
  "Repeat the command that was previously executed (or run the
sbt:default-command, if no other command has yet been run)."
  (interactive)
  (sbt:command (sbt:get-previous-command)))

(defun sbt-completion-at-point () (interactive) (sbt:completion-at-point))

(defun sbt:clear (&optional buffer)
  "Clear (erase) the SBT buffer."
  (with-current-buffer (or buffer (sbt:buffer-name))
    (let ((proc (get-buffer-process (current-buffer)))
          (inhibit-read-only t))
      (ignore-errors (compilation-forget-errors))
      (erase-buffer)
      (ignore-errors (comint-send-string proc (kbd "C-l"))))))

(defun sbt:command (command)
  (unless command (error "Please specify a command"))

  (when (not (comint-check-proc (sbt:buffer-name)))
    (sbt:run-sbt))
  
  (when sbt:save-some-buffers
    (save-some-buffers nil (sbt:buffer-in-project-function (sbt:find-root))))

  (with-current-buffer (sbt:buffer-name)
    (display-buffer (current-buffer))
    (sbt:clear (current-buffer))
    (comint-send-string (current-buffer) (concat command "\n"))
    (setq sbt:previous-command command)))

(defun sbt:get-previous-command ()
  (if (not (get-buffer (sbt:buffer-name)))
      sbt:default-command
    (with-current-buffer (sbt:buffer-name)
      sbt:previous-command)))
    
(defun sbt:run-sbt (&optional kill-existing-p pop-p)
  "Start or re-strats (if kill-existing-p is non-NIL) sbt in a
buffer called *sbt*projectdir."
  (let* ((project-root (sbt:find-root))
         (sbt-command-line (split-string sbt:program-name " "))
         (buffer-name (sbt:buffer-name))
         (inhibit-read-only 1))
    (when (null project-root)
      (error "Could not find project root, type `C-h f sbt:find-root` for help."))

    (when (not (or (executable-find (nth 0 sbt-command-line))
                   (file-executable-p (concat project-root (nth 0 sbt-command-line)))))
      (error "Could not find %s in %s or on PATH" (nth 0 sbt-command-line) project-root))

    ;; kill existing sbt
    (when (and kill-existing-p (get-buffer buffer-name))
      (sbt:clear buffer-name)
      (kill-buffer buffer-name))

    ;; start new sbt
    (with-current-buffer (get-buffer-create buffer-name)
      (when pop-p (pop-to-buffer-same-window (current-buffer)))
      (unless (comint-check-proc (current-buffer))
        (unless (derived-mode-p 'sbt-mode) (sbt-mode))
        (cd project-root)
        (buffer-disable-undo)
        (message "Starting sbt in buffer %s " buffer-name)
        ;;(erase-buffer)

        ;; insert a string to buffer so that process mark comes after 
        ;; compilation-messages-start mark.
        (insert (concat "Running " sbt:program-name "\n"))
        (goto-char (point-min))
        (ignore-errors (compilation-forget-errors))
        (comint-exec (current-buffer) buffer-name (nth 0 sbt-command-line) nil (cdr sbt-command-line)))
      (current-buffer))))

(defun sbt:initialize-for-compilation-mode ()
  (set (make-local-variable 'compilation-directory-matcher) 
       '("--go-home-compile.el--you-are-drn^H^H^Hbugs--"))

  (set (make-local-variable 'compilation-error-regexp-alist)
       `((,(rx line-start
               ?[ (or (group "error") (group "warn") ) ?]
               " " (group (1+ (not (any ": "))))
               ?: (group (1+ digit)) ?:)
          3 4 nil (2 . nil) 3 )))
  (set (make-local-variable 'compilation-mode-font-lock-keywords)
        '(
          ("^\\[error\\] Total time:[^\n]*"
           (0 compilation-error-face))
          ("^\\[success\\][^\n]*"
           (0 compilation-info-face))))
  (compilation-setup t))

(defvar sbt:mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map
                       (make-composed-keymap compilation-shell-minor-mode-map
                                             comint-mode-map))
    (define-key map (kbd "TAB") 'sbt-completion-at-point)
    (define-key map (kbd "C-c l") 'sbt-clear)
    
    map)
  "Basic mode map for `sbt-start'")

(define-derived-mode sbt-mode comint-mode "sbt"
  "Major mode for `sbt-start'.
 
\\{sbt:mode-map}"
  (use-local-map sbt:mode-map)
  (ignore-errors (scala-mode:set-scala-syntax-mode))
  (add-hook 'sbt-mode-hook 'sbt:initialize-for-comint-mode)
  (add-hook 'sbt-mode-hook 'sbt:initialize-for-compilation-mode))

(provide 'sbt-mode)