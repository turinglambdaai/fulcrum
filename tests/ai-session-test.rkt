#lang racket/base

;; Direct characterization of the product-owned AI session lifecycle.  These
;; tests stay below RVT1 so cancellation, shutdown and terminal delivery can be
;; asserted deterministically without a provider or native host.

(require racket/async-channel
         racket/file
         racket/string
         rackunit
         "../app/core/ai-session.rkt")

(define (with-session-dir thunk)
  (define dir (make-temporary-file "fulcrum-ai-session-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (thunk dir))
    (lambda ()
      (with-handlers ([exn:fail? void])
        (delete-directory/files dir)))))

(define (immediate-requester answer [pieces '()])
  (lambda (_provider _base-url _key _model _prompt
           #:history [_history '()]
           #:on-delta [on-delta void])
    (for ([piece (in-list pieces)]) (on-delta piece))
    answer))

(define (mailbox) (make-async-channel))
(define (mailbox-put box value) (async-channel-put box value))
(define (mailbox-get/timeout box [timeout 1])
  (sync/timeout timeout box))

(test-case "success streams, persists one chat turn, and delivers one terminal"
  (with-session-dir
   (lambda (dir)
     (define starts (mailbox))
     (define deltas (mailbox))
     (define terminals (mailbox))
     (define memory (build-path dir "ai-memory.json"))
     (define service
       (make-ai-session-service
        #:memory-path memory
        #:request-streaming (immediate-requester "hello" '("hel" "hello"))
        #:delta-interval-ms 0
        #:on-start (lambda () (mailbox-put starts 'running))
        #:on-delta (lambda (partial) (mailbox-put deltas partial))
        #:on-terminal (lambda (terminal) (mailbox-put terminals terminal))))
     (check-equal?
      (ai-session-start!
       service
       (ai-session-request "openai" "https://example.invalid" "secret-key"
                           "model" "prompt" "question"))
      'started)
     (check-equal? (mailbox-get/timeout starts) 'running)
     (check-equal? (mailbox-get/timeout deltas) "hel")
     (check-equal? (mailbox-get/timeout deltas) "hello")
     (define terminal (mailbox-get/timeout terminals))
     (check-equal? terminal (ai-session-terminal 'done "hello" #f))
     (check-false (mailbox-get/timeout terminals 0))
     (check-equal? (ai-session-last-answer service) "hello")
     (check-equal? (ai-session-history service)
                   (list (cons "user" "question")
                         (cons "assistant" "hello")))
     (define persisted (file->string memory))
     (check-false (string-contains? persisted "secret-key"))

     ;; A fresh service restores only the local transcript and answer.
     (define restored (make-ai-session-service #:memory-path memory))
     (ai-session-restore! restored)
     (check-equal? (ai-session-history restored)
                   (ai-session-history service))
     (check-equal? (ai-session-last-answer restored) "hello"))))

(test-case "provider failure is terminal and never enters conversation memory"
  (with-session-dir
   (lambda (dir)
     (define terminals (mailbox))
     (define service
       (make-ai-session-service
        #:memory-path (build-path dir "ai-memory.json")
        #:request-streaming (immediate-requester "AI request failed: offline")
        #:on-terminal (lambda (terminal) (mailbox-put terminals terminal))))
     (check-equal?
      (ai-session-start!
       service
       (ai-session-request "openai" "url" "key" "model" "prompt" "q"))
      'started)
     (check-equal? (mailbox-get/timeout terminals)
                   (ai-session-terminal 'error "" "AI request failed: offline"))
     (check-equal? (ai-session-history service) '())
     (check-equal? (ai-session-last-answer service) ""))))

(test-case "concurrent start is rejected; cancel kills workers and blocks late deltas"
  (with-session-dir
   (lambda (dir)
     (define workers (mailbox))
     (define children (mailbox))
     (define terminals (mailbox))
     (define deltas (mailbox))
     (define captured-delta (box #f))
     (define requester
       (lambda (_provider _base-url _key _model _prompt
                #:history [_history '()]
                #:on-delta [on-delta void])
         (set-box! captured-delta on-delta)
         (mailbox-put workers (current-thread))
         (define child (thread (lambda () (sync never-evt))))
         (mailbox-put children child)
         (sync never-evt)
         "unreachable"))
     (define service
       (make-ai-session-service
        #:memory-path (build-path dir "ai-memory.json")
        #:request-streaming requester
        #:on-delta (lambda (partial) (mailbox-put deltas partial))
        #:on-terminal (lambda (terminal) (mailbox-put terminals terminal))))
     (define request (ai-session-request "openai" "url" "key" "model" "p" #f))
     (check-equal? (ai-session-start! service request) 'started)
     (define worker (mailbox-get/timeout workers))
     (define child (mailbox-get/timeout children))
     (check-true (thread? worker))
     (check-true (thread? child))
     (check-equal? (ai-session-start! service request) 'busy)
     (check-true (ai-session-cancel! service))
     (check-equal? (mailbox-get/timeout terminals)
                   (ai-session-terminal 'cancelled "" #f))
     (check-not-false (sync/timeout 1 (thread-dead-evt worker)))
     (check-not-false (sync/timeout 1 (thread-dead-evt child)))
     (check-false (ai-session-running? service))

     ;; Even a stale provider callback retained outside the dead worker cannot
     ;; publish after cancellation.
     ((unbox captured-delta) "too late")
     (check-false (mailbox-get/timeout deltas 0))
     (check-false (mailbox-get/timeout terminals 0))
     (check-false (ai-session-cancel! service)))))

(test-case "close is silent, kills the worker, and permanently rejects starts"
  (with-session-dir
   (lambda (dir)
     (define workers (mailbox))
     (define children (mailbox))
     (define terminals (mailbox))
     (define captured-delta (box #f))
     (define deltas (mailbox))
     (define service
       (make-ai-session-service
        #:memory-path (build-path dir "ai-memory.json")
        #:request-streaming
        (lambda (_provider _base-url _key _model _prompt
                 #:history [_history '()]
                 #:on-delta [on-delta void])
          (set-box! captured-delta on-delta)
          (mailbox-put workers (current-thread))
          (define child (thread (lambda () (sync never-evt))))
          (mailbox-put children child)
          (sync never-evt)
          "unreachable")
        #:on-delta (lambda (partial) (mailbox-put deltas partial))
        #:on-terminal (lambda (terminal) (mailbox-put terminals terminal))))
     (define request (ai-session-request "ollama" "url" "" "model" "p" #f))
     (check-equal? (ai-session-start! service request) 'started)
     (define worker (mailbox-get/timeout workers))
     (define child (mailbox-get/timeout children))
     (ai-session-close! service)
     (check-true (ai-session-closed? service))
     (check-not-false (sync/timeout 1 (thread-dead-evt worker)))
     (check-not-false (sync/timeout 1 (thread-dead-evt child)))
     ((unbox captured-delta) "too late")
     (check-false (mailbox-get/timeout deltas 0))
     (check-false (mailbox-get/timeout terminals 0))
     (check-equal? (ai-session-start! service request) 'closed))))

(test-case "reset cancels an in-flight chat before clearing persisted memory"
  (with-session-dir
   (lambda (dir)
     (define workers (mailbox))
     (define terminals (mailbox))
     (define memory (build-path dir "ai-memory.json"))
     (define service
       (make-ai-session-service
        #:memory-path memory
        #:request-streaming
        (lambda (_provider _base-url _key _model _prompt
                 #:history [_history '()]
                 #:on-delta [_on-delta void])
          (mailbox-put workers (current-thread))
          (sync never-evt)
          "unreachable")
        #:on-terminal (lambda (terminal) (mailbox-put terminals terminal))))
     (ai-session-set-history! service
                              (list (cons "user" "old")
                                    (cons "assistant" "answer")))
     (ai-session-set-last-answer! service "answer")
     (check-equal?
      (ai-session-start!
       service
       (ai-session-request "openai" "url" "key" "model" "p" "new"))
      'started)
     (define worker (mailbox-get/timeout workers))
     (ai-session-reset! service)
     (check-equal? (mailbox-get/timeout terminals)
                   (ai-session-terminal 'cancelled "" #f))
     (check-not-false (sync/timeout 1 (thread-dead-evt worker)))
     (check-equal? (ai-session-history service) '())
     (check-equal? (ai-session-last-answer service) "")

     (define restored (make-ai-session-service #:memory-path memory))
     (ai-session-restore! restored)
     (check-equal? (ai-session-history restored) '())
     (check-equal? (ai-session-last-answer restored) ""))))
