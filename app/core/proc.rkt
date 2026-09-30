#lang racket/base

;; Subprocess helpers shared by app discovery, app launching, and system
;; commands.
;;
;; Two distinct contracts:
;;   - `run-command` waits (bounded) for output and is for *probing* the
;;     environment (plutil, loginctl, …). Timeouts return #f, never raise.
;;   - `spawn-command` is fire-and-forget for *side effects* (launching an
;;     application, locking the screen). Spawned processes live in their own
;;     custodian so they outlive the RPC request that started them, and
;;     failures are reported to the caller as #f instead of tearing down a
;;     request worker.

(require racket/contract
         racket/async-channel
         racket/path
         racket/port)

(provide run-command
         spawn-command)

(define launcher-custodian (make-custodian))

;; subprocess performs no PATH lookup for program names (a bare "open" fails
;; with a silent nonzero child exit), so resolve like a shell would. Names
;; with a directory part are used as-is; a bare name that resolves nowhere
;; yields #f so the helpers bail out instead of spawning a doomed child.
(define (resolve-program program)
  (if (path-only program)
      program
      (find-executable-path program)))

(define/contract (run-command program args #:timeout-ms [timeout-ms 2000])
  (->* (path-string? (listof path-string?))
       (#:timeout-ms (and/c exact-integer? (>/c 0)))
       (or/c string? #f))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define resolved (or (resolve-program program)
                         (error 'run-command
                                "executable was not found on PATH: ~a" program)))
    (define-values (proc stdout stdin stderr)
      (apply subprocess #f #f #f resolved args))
    (close-output-port stdin)
    ;; Racket has no subprocess exit event; a watcher thread provides one.
    (define done (make-async-channel))
    (parameterize ([current-custodian (make-custodian)])
      (thread (lambda ()
                (subprocess-wait proc)
                (async-channel-put done #t))))
    (define exited (sync/timeout (/ timeout-ms 1000) done))
    (define output
      (if exited
          (port->string stdout)
          (begin
            (subprocess-kill proc #t)
            #f)))
    (close-input-port stdout)
    (close-input-port stderr)
    output))

(define/contract (spawn-command program args)
  (-> path-string? (listof path-string?) boolean?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define resolved (or (resolve-program program)
                         (error 'spawn-command
                                "executable was not found on PATH: ~a" program)))
    (parameterize ([current-custodian launcher-custodian])
      (define-values (proc stdout stdin stderr)
        (apply subprocess #f #f #f resolved args))
      (close-output-port stdin)
      (close-input-port stdout)
      (close-input-port stderr)
      #t)))
