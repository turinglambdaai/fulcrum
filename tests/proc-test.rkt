#lang racket/base

;; Subprocess helper tests.
;;
;; The resolver matters: Racket's subprocess does no PATH lookup, so a bare
;; program name ("open", "plutil") silently fails with a nonzero child exit.
;; These tests pin PATH resolution for both helpers.

(require rackunit
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

;; Regression: a child whose output exceeds the 64 KiB pipe buffer used to
;; deadlock run-command (parent waited for exit, child blocked on write)
;; and every large file search timed out. Unix-gated like the FPP1
;; fixtures (/bin/sh).
(when (member (system-type 'os) '(unix macosx))
  (test-case "run-command drains output larger than the pipe buffer"
    (define out
      (run-command "/bin/sh"
                   (list "-c" "yes hello-there | head -c 200000")
                   #:timeout-ms 5000))
    (check-true (string? out) "large output must not time out")
    (check-true (> (string-length out) 100000))))
