#lang racket/base

;; Wire-level backend regression: drive the production backend module over
;; RVT1 the way a native host does and check the responses. This layer
;; catches failures the unit tests cannot — RPC-name shadowing, handler
;; arity, event emission across the wire (settings-list/snippet-list both
;; shipped broken once because their handlers recursed into the RPC's own
;; definition instead of the core function).

(require json
         racket/file
         racket/match
         racket/path
         racket/string
         rivet/backend
         rivet/protocol)

(define test-dir (or (current-load-relative-directory) (current-directory)))
(define fulcrum-root
  ;; raco test runs from the project root or from tests/; find the root by
  ;; looking for the app collection.
  (if (directory-exists? (build-path test-dir "app"))
      (simplify-path test-dir)
      (simplify-path (build-path test-dir ".."))))
(define (get rel sym)
  (dynamic-require (build-path fulcrum-root rel) sym))

(define root (make-temporary-file "fulcrum-wire-~a" 'directory))
(environment-variables-set! (current-environment-variables)
                            #"FULCRUM_DATA_DIR"
                            (string->bytes/utf-8 (path->string root)))

;; Load the production backend module: registering every RPC/State/Event
;; happens at require time, exactly as in the embedded runtime.
(define backend-path (build-path fulcrum-root "app" "backend.rkt"))
(void (dynamic-require backend-path #f))
(define current-engine (dynamic-require backend-path 'current-engine))
(define current-settings (dynamic-require backend-path 'current-settings))

(define make-settings-manager (get "app/core/settings.rkt" 'make-settings-manager))
(define settings-path (get "app/core/paths.rkt" 'settings-path))
(define clipboard-path (get "app/core/paths.rkt" 'clipboard-path))
(define snippets-path (get "app/core/paths.rkt" 'snippets-path))
(define make-clipboard (get "app/core/clipboard.rkt" 'make-clipboard-store))
(define make-snippets (get "app/core/snippets.rkt" 'make-snippet-store))
(define make-engine (get "app/core/engine.rkt" 'make-engine))
(define rebuild (get "app/core/engine.rkt" 'engine-rebuild-index!))

(define manager (make-settings-manager (settings-path)))
(define eng (make-engine
             #:clipboard-store (make-clipboard (clipboard-path))
             #:snippet-store (make-snippets (snippets-path))
             #:plugin-manager #f))
(rebuild eng)
(current-settings manager)
(current-engine eng)

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define srv (thread (lambda () (serve server-in server-out))))

(define (call-rpc id payload)
  (write-frame (frame message:request id (encode-value payload)) client-out)
  (let loop ([events '()])
    (define f (read-frame client-in))
    (match (frame-type f)
      [(== message:hello) (loop events)]
      [(== message:event)
       (loop (cons (decode-value (frame-payload f)) events))]
      [(== message:response)
       (values (decode-value (frame-payload f)) #f events)]
      [(== message:error)
       (values #f
               (let ([v (decode-value (frame-payload f))])
                 (if (string? v) v (format "~s" v)))
               events)]
      [_ (loop events)])))

(define failures 0)
(define (check! name actual expected)
  (cond
    [(equal? actual expected) (printf "ok   ~a\n" name)]
    [else
     (set! failures (add1 failures))
     (printf "FAIL ~a\n  expected: ~s\n  actual:   ~s\n" name expected actual)]))

(define hello (read-frame client-in))
(check! "hello identifies rivet"
        (car (decode-value (frame-payload hello)))
        "rivet")

(define-values (h-val h-err _h) (call-rpc 1 (list "health")))
(check! "health no error" h-err #f)
(check! "health mentions version" (string-prefix? h-val "fulcrum 0.") #t)

(call-rpc 2 (list "clipboard-record" "deploy command: make fulcrum-release"))
(call-rpc 3 (list "snippet-save" "" "Verify snippet" "rel" "body-for-verify"))

(define-values (rows-val rows-err _r) (call-rpc 4 (list "search" "verify snippet")))
(check! "search no error" rows-err #f)
(define titles (for/list ([row (in-list rows-val)]) (list-ref row 1)))
(check! "search finds snippet" (and (member "Verify snippet" titles) #t) #t)

;; The two RPCs that shipped broken: their handlers must reach the core
;; stores, not recurse into the RPC's own (zero-argument) definition.
(define-values (sl _sle _sleve) (call-rpc 5 (list "settings-list")))
(check! "settings-list no error" _sle #f)
(define theme-row
  (for/first ([row (in-list sl)] #:when (string=? (list-ref row 0) "theme"))
    row))
(check! "settings-list lists theme" (and theme-row #t) #t)

(define-values (snl _snle _snleve) (call-rpc 6 (list "snippet-list")))
(check! "snippet-list no error" _snle #f)
(check! "snippet-list has the snippet"
        (and (member "Verify snippet" (for/list ([row (in-list snl)])
                                        (list-ref row 1)))
             #t)
        #t)

(define-values (plv _ple _pleve) (call-rpc 7 (list "plugins-list")))
(check! "plugins-list no error" _ple #f)

;; action + event over the wire
(define-values (calc-val _ce _cev) (call-rpc 8 (list "search" "12*12")))
(define calc-row
  (for/first ([row (in-list calc-val)]
              #:when (string=? (list-ref row 3) "Calculator"))
    row))
(check! "calculator answer" (list-ref calc-row 1) "144")
(define-values (run-val run-err run-events)
  (call-rpc 9 (list "run-action" (list-ref calc-row 0) (list-ref calc-row 4))))
(check! "run-action copied" run-val "copied")
(check! "copy-to-clipboard event emitted"
        (and (for/or ([e (in-list run-events)])
               (and (pair? e) (string=? (car e) "copy-to-clipboard")
                    (string=? (cadr e) "144")))
             #t)
        #t)

;; URL safety enforced over the wire
(define-values (evil _ee _eev)
  (call-rpc 10 (list "run-action" "web.open" "file:///etc/passwd")))
(check! "file:// refused" (string-prefix? evil "refused") #t)

(kill-thread srv)
(delete-directory/files root)
(if (zero? failures)
    (printf "wire backend checks passed\n")
    (begin
      (printf "~a wire backend check(s) FAILED\n" failures)
      (exit 1)))
