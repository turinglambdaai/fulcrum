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
         spawn-command
         resolve-program)

(define launcher-custodian (make-custodian))

;; Drain a child pipe without letting a parent-side cleanup race escape as an
;; uncaught exception from a background thread.  The tagged message keeps a
;; failed read distinct from a timeout while the caller is waiting for the
;; drain to finish.
(define (drain-port/async input #:capture? [capture? #t])
  (define result (make-async-channel 1))
  (define worker
    (thread
     (lambda ()
       (define value
         (with-handlers ([exn:fail? (lambda (_) '(error))])
           (if capture?
               (list 'ok (port->string input))
               (begin
                 (copy-port input (open-output-nowhere))
                 '(ok)))))
       (async-channel-put result value))))
  (values worker result))

(define (finish-drain worker input result)
  ;; A normally exiting child closes its pipe and the reader finishes at once.
  ;; Keep a defensive bound for broken OS handles; only then close the port to
  ;; wake the reader.  drain-port/async catches that expected interruption.
  (define message (sync/timeout 1 result))
  (unless message
    (close-input-port input)
    (sync/timeout 0.1 worker))
  message)

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
    ;; The stdout DRAIN must run concurrently with the exit wait: a child
    ;; that writes more than the 64 KiB pipe buffer blocks on write while
    ;; the parent blocks on exit — a mutual deadlock that used to time out
    ;; every file search whose result set was large.
    (define done (make-async-channel))
    (define waiter
      (thread (lambda ()
                (subprocess-wait proc)
                (async-channel-put done #t))))
    (define-values (stdout-worker output-ch)
      (drain-port/async stdout))
    ;; stderr has its own finite pipe too.  Ignoring it recreates the same
    ;; deadlock for a noisy command even when stdout is drained correctly.
    (define-values (stderr-worker stderr-ch)
      (drain-port/async stderr #:capture? #f))
    (define exited (sync/timeout (/ timeout-ms 1000) done))
    (unless exited
      (subprocess-kill proc #t)
      ;; Reap after the kill so both pipe readers see EOF before cleanup.
      ;; The watcher remains the single thread that calls subprocess-wait.
      (sync/timeout 1 done))
    (define stdout-result
      (finish-drain stdout-worker stdout output-ch))
    (finish-drain stderr-worker stderr stderr-ch)
    (unless (thread-dead? waiter)
      (kill-thread waiter))
    (close-input-port stdout)
    (close-input-port stderr)
    (and exited
         (pair? stdout-result)
         (eq? (car stdout-result) 'ok)
         (cadr stdout-result))))

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
