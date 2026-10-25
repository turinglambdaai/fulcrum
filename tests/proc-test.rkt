#lang racket/base

;; Subprocess helper tests.
;;
;; The resolver matters: Racket's subprocess does no PATH lookup, so a bare
;; program name ("open", "plutil") silently fails with a nonzero child exit.
;; These tests pin PATH resolution for both helpers.

(require racket/async-channel
         rackunit
         "../app/core/proc.rkt")

(unless (eq? (system-type 'os) 'windows)
  (test-case "run-command resolves bare program names via PATH"
    (check-equal? (run-command "echo" '("fulcrum")) "fulcrum\n")
    (check-false (run-command "definitely-not-a-real-binary-xyz" '())
                 "missing binaries return #f, never raise")))

(test-case "spawn-command is fire-and-forget"
  ;; `true` is not a Windows executable. Use Racket itself so this checks
  ;; PATH resolution and successful spawning on every supported platform.
  (check-true (spawn-command "racket" '("-e" "(void)")))
  (check-false (spawn-command "definitely-not-a-real-binary-xyz" '())))

(test-case "run-command timeout closes child pipes quietly"
  ;; Regression for file-search cancellation: closing stdout while the drain
  ;; thread was still in port->string printed one exception per superseded
  ;; query.  Fast typing made the same stack trace fill the launcher.
  (define errors (open-output-string))
  (parameterize ([current-error-port errors])
    (for ([i (in-range 4)])
      (check-false
       (run-command "racket" (list "-e" "(sleep 5)") #:timeout-ms 10)))
    ;; Give an accidentally orphaned reader enough time to report its error.
    (sleep 0.2))
  (check-equal? (get-output-string errors) ""))

(test-case "run-command drains both child output pipes"
  ;; stderr is a separate finite pipe.  A command that fills it must not
  ;; deadlock while the parent waits for exit.
  (define out
    (run-command
     "racket"
     (list "-e"
           (string-append
            "(begin (display (make-string 200000 #\\x)) "
            "(eprintf \"~a\" (make-string 200000 #\\e)))"))
     #:timeout-ms 5000))
  (check-true (string? out) "large stdout + stderr must not time out")
  (check-equal? (string-length out) 200000))

(test-case "run-command cancellation terminates the child promptly"
  (define cancel (make-semaphore 0))
  (define result (make-async-channel 1))
  (define errors (open-output-string))
  (define started (current-inexact-milliseconds))
  (parameterize ([current-error-port errors])
    (thread
     (lambda ()
       (async-channel-put
        result
        (run-command/cancellable
         "racket" (list "-e" "(sleep 10)")
         #:timeout-ms 5000
         #:cancel-evt (semaphore-peek-evt cancel)))))
    (sleep 0.1)
    (semaphore-post cancel)
    (check-equal? (sync/timeout 2 result) 'cancelled))
  (check-true (< (- (current-inexact-milliseconds) started) 3000)
              "cancellation must not wait for the five-second timeout")
  (check-equal? (get-output-string errors) ""))

;; Regression: a child whose output exceeds the 64 KiB pipe buffer used to
;; deadlock run-command (parent waited for exit, child blocked on write)
;; and every large file search timed out.  The portable test above covers both
;; stdout and stderr on all three supported hosts.
