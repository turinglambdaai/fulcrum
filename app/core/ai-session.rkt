#lang racket/base

;; Product-owned AI session lifecycle.
;;
;; This module deliberately knows nothing about RVT1 or native hosts.  It owns
;; exactly one provider worker, the local-only conversation memory, and the
;; rule that every accepted run has at most one terminal result.  backend.rkt
;; adapts the callbacks below to the existing AiStream State and ai-finished
;; Event without changing their public wire shapes.  Lifecycle callbacks are
;; serialized with start/cancel/close and therefore must not call back into the
;; same service.

(require racket/list
         racket/string
         "ai.rkt"
         "store.rkt")

(provide (struct-out ai-session-request)
         (struct-out ai-session-terminal)
         make-ai-session-service
         ai-session-start!
         ai-session-cancel!
         ai-session-close!
         ai-session-closed?
         ai-session-running?
         ai-session-history
         ai-session-last-answer
         ai-session-set-history!
         ai-session-set-last-answer!
         ai-session-reset!
         ai-session-undo!
         ai-session-restore!)

;; chat-user is #f for one-shot commands and the user's text for a chat turn.
(struct ai-session-request
  (provider base-url key model prompt chat-user)
  #:transparent)

;; phase is one of 'done, 'error, or 'cancelled.  Successful text and error
;; text are kept separate so backend adapters never need to reinterpret a
;; partial stream as a terminal result.
(struct ai-session-terminal (phase text error) #:transparent)

(struct active-run (id custodian worker) #:mutable #:transparent)

(struct ai-session-service
  (gate
   memory-path
   requester
   on-start
   on-delta
   on-terminal
   delta-interval-ms
   [closed? #:mutable]
   [next-id #:mutable]
   [active #:mutable]
   [history #:mutable]
   [last-answer #:mutable])
  #:transparent)

(define (make-ai-session-service
         #:memory-path memory-path
         #:request-streaming [requester ai-request-streaming]
         #:on-start [on-start (lambda () (void))]
         #:on-delta [on-delta (lambda (_partial) (void))]
         #:on-terminal [on-terminal (lambda (_terminal) (void))]
         #:delta-interval-ms [delta-interval-ms 150])
  (unless (or (path-string? memory-path) (procedure? memory-path))
    (raise-argument-error 'make-ai-session-service
                          "path-string? or procedure?"
                          memory-path))
  (unless (and (real? delta-interval-ms) (>= delta-interval-ms 0))
    (raise-argument-error 'make-ai-session-service
                          "nonnegative-real?"
                          delta-interval-ms))
  (ai-session-service (make-semaphore 1)
                      memory-path
                      requester
                      on-start
                      on-delta
                      on-terminal
                      delta-interval-ms
                      #f 0 #f '() ""))

(define (with-lock service thunk)
  (call-with-semaphore (ai-session-service-gate service) thunk))

(define (memory-path service)
  (define source (ai-session-service-memory-path service))
  (if (procedure? source) (source) source))

(define (valid-history? value)
  (and (list? value)
       (andmap (lambda (entry)
                 (and (pair? entry)
                      (string? (car entry))
                      (string? (cdr entry))))
               value)))

;; Caller holds service.gate.  Keeping the write under the same lock preserves
;; write order when an RPC reset races a terminal provider result.
(define (persist-locked! service)
  (with-handlers ([exn:fail? void])
    (write-json-atomic!
     (memory-path service)
     (hasheq 'history
             (for/list ([entry (in-list (ai-session-service-history service))])
               (list (car entry) (cdr entry)))
             'last-answer (ai-session-service-last-answer service)))))

(define (ai-session-history service)
  (with-lock service
    (lambda () (ai-session-service-history service))))

(define (ai-session-last-answer service)
  (with-lock service
    (lambda () (ai-session-service-last-answer service))))

(define (ai-session-set-history! service history)
  (unless (valid-history? history)
    (raise-argument-error 'ai-session-set-history!
                          "list of (cons string? string?)"
                          history))
  (with-lock service
    (lambda ()
      (set-ai-session-service-history! service history)
      (persist-locked! service))))

(define (ai-session-set-last-answer! service answer)
  (unless (string? answer)
    (raise-argument-error 'ai-session-set-last-answer! "string?" answer))
  (with-lock service
    (lambda ()
      (set-ai-session-service-last-answer! service answer)
      (persist-locked! service))))

(define (ai-session-restore! service)
  (define raw
    (with-handlers ([exn:fail? (lambda (_) (hash))])
      (read-json-file (memory-path service) (hash))))
  (when (hash? raw)
    (define json-history (hash-ref raw 'history '()))
    (define restored-history
      (and (list? json-history)
           (andmap (lambda (entry)
                     (and (list? entry)
                          (= (length entry) 2)
                          (string? (car entry))
                          (string? (cadr entry))))
                   json-history)
           (for/list ([entry (in-list json-history)])
             (cons (car entry) (cadr entry)))))
    (define restored-answer (hash-ref raw 'last-answer #f))
    (with-lock service
      (lambda ()
        (when restored-history
          (set-ai-session-service-history! service restored-history))
        (when (string? restored-answer)
          (set-ai-session-service-last-answer! service restored-answer)))))
  (void))

(define (ai-session-running? service)
  (with-lock service
    (lambda () (and (ai-session-service-active service) #t))))

(define (ai-session-closed? service)
  (with-lock service
    (lambda () (ai-session-service-closed? service))))

(define (safe-callback callback . args)
  ;; A missing/disconnected RVT1 peer must not strand the service in running.
  (with-handlers ([exn:fail? void])
    (apply callback args)))

(define (current-run? service run-id)
  (and (not (ai-session-service-closed? service))
       (let ([run (ai-session-service-active service)])
         (and run (= run-id (active-run-id run))))))

(define (emit-delta-if-current service run-id partial last-push)
  (define now (current-inexact-milliseconds))
  (when (> (- now (unbox last-push))
           (ai-session-service-delta-interval-ms service))
    (with-lock service
      (lambda ()
        (when (current-run? service run-id)
          ;; Keep the callback inside the lifecycle lock.  cancel/close cannot
          ;; return while an accepted delta is still being delivered, so hosts
          ;; never observe a late running update after a terminal boundary.
          (set-box! last-push now)
          (safe-callback (ai-session-service-on-delta service) partial))))))

(define (answer->terminal answer)
  (if (string-prefix? answer "AI ")
      (ai-session-terminal 'error "" answer)
      (ai-session-terminal 'done answer #f)))

(define (finish-run! service run-id request history answer)
  (define terminal (answer->terminal answer))
  (with-lock service
    (lambda ()
      (when (current-run? service run-id)
        (set-ai-session-service-active! service #f)
        (when (eq? (ai-session-terminal-phase terminal) 'done)
          (set-ai-session-service-last-answer! service answer)
          (define chat-user (ai-session-request-chat-user request))
          (when chat-user
            (set-ai-session-service-history!
             service
             (ai-history-append history chat-user answer)))
          (persist-locked! service))
        ;; Linearize terminal delivery with close: after close returns, no
        ;; terminal callback from this run can still be pending.
        (safe-callback (ai-session-service-on-terminal service) terminal)))))

(define (run-provider! service run-id request history)
  (define answer
    (with-handlers ([exn:fail?
                     (lambda (exn)
                       (string-append "AI request failed: " (exn-message exn)))])
      ((ai-session-service-requester service)
       (ai-session-request-provider request)
       (ai-session-request-base-url request)
       (ai-session-request-key request)
       (ai-session-request-model request)
       (ai-session-request-prompt request)
       #:history history
       #:on-delta
       (let ([last-push (box 0.0)])
         (lambda (partial)
           (emit-delta-if-current service run-id partial last-push))))))
  (finish-run! service run-id request history answer))

(define (ai-session-start! service request)
  (unless (ai-session-request? request)
    (raise-argument-error 'ai-session-start! "ai-session-request?" request))
  (define run #f)
  (define history '())
  (define decision
    (with-lock service
      (lambda ()
        (cond
          [(ai-session-service-closed? service) 'closed]
          [(ai-session-service-active service) 'busy]
          [else
           (define run-id (add1 (ai-session-service-next-id service)))
           (set-ai-session-service-next-id! service run-id)
           (set! history
                 (if (ai-session-request-chat-user request)
                     (ai-session-service-history service)
                     '()))
           (set! run (active-run run-id (make-custodian) #f))
           (set-ai-session-service-active! service run)
           ;; Publish running under the same lock as ownership.  A concurrent
           ;; cancel therefore either follows this transition with cancelled,
           ;; or observes no run at all; it cannot be overwritten by a late
           ;; running callback.
           (safe-callback (ai-session-service-on-start service))
           'started]))))
  (when (eq? decision 'started)
    (with-handlers ([exn:fail?
                     (lambda (exn)
                       (finish-run! service
                                    (active-run-id run)
                                    request
                                    history
                                    (string-append "AI request failed: "
                                                   (exn-message exn))))])
      (define worker
        (parameterize ([current-custodian (active-run-custodian run)])
          (thread
           (lambda ()
             (run-provider! service (active-run-id run) request history)))))
      (with-lock service
        (lambda ()
          (when (current-run? service (active-run-id run))
            (set-active-run-worker! run worker))))))
  decision)

(define (ai-session-cancel! service)
  (define run
    (with-lock service
      (lambda ()
        (define current (ai-session-service-active service))
        (when current (set-ai-session-service-active! service #f))
        current)))
  (cond
    [run
     ;; custodian-shutdown-all waits until its managed worker(s) are dead.
     (custodian-shutdown-all (active-run-custodian run))
     (with-lock service
       (lambda ()
         ;; close supersedes cancellation and promises silence after return.
         (unless (ai-session-service-closed? service)
           (safe-callback (ai-session-service-on-terminal service)
                          (ai-session-terminal 'cancelled "" #f)))))
     #t]
    [else #f]))

(define (ai-session-reset! service)
  ;; Cancelling first prevents an in-flight chat from restoring the transcript
  ;; after the user has explicitly reset it.
  (ai-session-cancel! service)
  (with-lock service
    (lambda ()
      (set-ai-session-service-history! service '())
      (set-ai-session-service-last-answer! service "")
      (persist-locked! service)))
  (void))

(define (ai-session-undo! service)
  (ai-session-cancel! service)
  (with-lock service
    (lambda ()
      (define history (ai-session-service-history service))
      (cond
        [(null? history) #f]
        [else
         (define kept (take history (max 0 (- (length history) 2))))
         (set-ai-session-service-history! service kept)
         (set-ai-session-service-last-answer! service "")
         (persist-locked! service)
         #t]))))

(define (ai-session-close! service)
  (define run
    (with-lock service
      (lambda ()
        (define current (ai-session-service-active service))
        ;; Mark closed before tearing down the custodian: callbacks that race
        ;; the shutdown observe closed and become no-ops.
        (set-ai-session-service-closed?! service #t)
        (set-ai-session-service-active! service #f)
        current)))
  (when run
    (custodian-shutdown-all (active-run-custodian run)))
  (void))
