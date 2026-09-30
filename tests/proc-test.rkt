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
  (check-true (spawn-command "true" '()))
  (check-false (spawn-command "definitely-not-a-real-binary-xyz" '())))
