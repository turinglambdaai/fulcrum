#lang racket/base

;; System commands.
;;
;; Platform actions exposed as launcher entries (lock, sleep, restart, …).
;; Commands are spawned with `spawn-command`, so they never block a request
;; worker, and the list is built with injectable availability probes so tests
;; can run on any OS.

(require racket/contract
         racket/list
         "proc.rkt")

(provide (struct-out system-command)
         system-commands
         run-system-command!)

(struct system-command (name program args) #:transparent)

(define (find-executable name)
  (and name (find-executable-path name)))

(define (macos-commands)
  (append
   (list (system-command "Sleep" "pmset" '("sleepnow"))
         (system-command "Sleep Display" "pmset" '("displaysleepnow")))
   ;; CGSession -suspend is the classic lock-screen entry point; it has moved
   ;; or disappeared on some macOS versions, so it is only offered when the
   ;; binary exists.
   (let ([session (find-executable-path
                   "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")])
     (if session
         (list (system-command "Lock Screen" (path->string session) '("-suspend")))
         '()))))

(define (windows-commands)
  (list (system-command "Lock" "rundll32.exe" '("user32.dll,LockWorkStation"))
        (system-command "Sleep" "rundll32.exe" '("powrprof.dll,SetSuspendState 0,1,0"))
        (system-command "Restart" "shutdown.exe" '("/r" "/t" "0"))
        (system-command "Shut Down" "shutdown.exe" '("/s" "/t" "0"))))

(define (linux-lock-command)
  (define candidates
    (list (system-command "Lock Screen" "loginctl" '("lock-session"))
          (system-command "Lock Screen" "gnome-screensaver-command" '("-l"))
          (system-command "Lock Screen" "xscreensaver-command" '("-lock"))))
  (findf (lambda (cmd)
           (find-executable (system-command-program cmd)))
         candidates))

(define (linux-commands)
  (append
   (let ([lock (linux-lock-command)]) (if lock (list lock) '()))
   (filter
    values
    (for/list ([cmd (in-list
                     (list (system-command "Sleep" "systemctl" '("suspend"))
                           (system-command "Restart" "systemctl" '("reboot"))
                           (system-command "Power Off" "systemctl" '("poweroff"))))])
      (and (find-executable (system-command-program cmd)) cmd)))))

(define/contract (system-commands [platform (system-type 'os)])
  (->* () ((or/c 'macosx 'windows 'unix)) (listof system-command?))
  (case platform
    [(macosx) (macos-commands)]
    [(windows) (windows-commands)]
    [else (linux-commands)]))

(define/contract (run-system-command! cmd)
  (-> system-command? boolean?)
  (spawn-command (system-command-program cmd)
                 (map (lambda (a)
                        (if (string? a) a (format "~a" a)))
                      (system-command-args cmd))))
