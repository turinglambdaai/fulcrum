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

(define last-raw (box #""))
(define (call-rpc id payload)
  (write-frame (frame message:request id (encode-value payload)) client-out)
  (let loop ([events '()])
    (define f
      (if (sync/timeout 5 client-in)
          (let ([f (read-frame client-in)])
            (set-box! last-raw (frame-payload f))
            f)
          (begin
            (printf "TIMEOUT waiting for frame (rpc ~a), server alive: ~s~n"
                    id (thread-dead? srv))
            (exit 1))))
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

;; ---- the remaining RPC surface, end to end -------------------------------

;; clipboard-history returns the seeded row with preview columns
(define-values (chv _che _chev) (call-rpc 11 (list "clipboard-history" "fulcrum-release")))
(check! "clipboard-history no error" _che #f)
(check! "clipboard-history has the row"
        (and (pair? chv) (string-contains? (list-ref (car chv) 1) "fulcrum-release"))
        #t)

;; clipboard-clear removes it and reports the count
(define-values (_ccv cce _ccev) (call-rpc 12 (list "clipboard-clear")))
(check! "clipboard-clear no error" cce #f)
(define-values (chv2 _che2 _che2v) (call-rpc 13 (list "clipboard-history" "fulcrum-release")))
(check! "clipboard cleared" (null? chv2) #t)

;; snippet-delete removes the seeded snippet
(define-values (sidv _side _sidev) (call-rpc 14 (list "snippet-list")))
(define seeded-id (for/first ([row (in-list sidv)]
                              #:when (string=? (list-ref row 1) "Verify snippet"))
                    (list-ref row 0)))
(check! "snippet-list row id present" (and seeded-id #t) #t)
(define-values (sdel _sdle _sdlev) (call-rpc 15 (list "snippet-delete" seeded-id)))
(check! "snippet-delete true" sdel #t)
(define-values (snl2 _snl2 _snl2v) (call-rpc 16 (list "snippet-list")))
(check! "snippet gone from list"
        (and (not (member "Verify snippet" (for/list ([row (in-list snl2)])
                                             (list-ref row 1))))
             #t)
        #t)

;; settings round trip already covered; exercise index-rebuild
(define-values (irv ire _irev) (call-rpc 17 (list "index-rebuild")))
(check! "index-rebuild no error" ire #f)
(check! "index-rebuild returns a count" (exact-integer? irv) #t)

;; plugins-reload is void and harmless with an empty gallery
(define-values (prv pre _prev) (call-rpc 18 (list "plugins-reload")))
(check! "plugins-reload no error" pre #f)

;; update-check on a developer build reports honestly (no network)
(define-values (ucv uce _ucev) (call-rpc 19 (list "update-check")))
(check! "update-check no error" uce #f)
(check! "update-check honest on dev build"
        (or (string-prefix? ucv "updates unavailable")
            (string-prefix? ucv "update check failed")
            (string-prefix? ucv "update available")
            (string-prefix? ucv "Fulcrum is up to date"))
        #t)

;; error paths: unknown RPC, unknown action, bad arity
(define-values (_xv xe _xeve) (call-rpc 20 (list "no-such-rpc" "x")))
(printf "DBG20 xe=~s\n" xe)
(check! "unknown RPC yields error frame" (string-contains? xe "unknown RPC") #t)
(define-values (yv _ye _yev) (call-rpc 21 (list "run-action" "no-such-action" "x")))
(check! "unknown action reported"
        (and (string? yv) (string-prefix? yv "unknown action") #t)
        #t)
(define-values (_zv ze _zev) (call-rpc 22 (list "health" "extra-arg")))
(check! "bad arity yields error frame" (string-contains? ze "expected 0 arguments") #t)

;; backend-owned action routers (settings/AI/plugins), all offline paths
(define-values (ahv _ahe _ahev) (call-rpc 23 (list "run-action" "ai.help" "")))
(check! "ai.help ok" ahv "ok")
(define-values (arv _are _arev) (call-rpc 24 (list "run-action" "ai.reset" "")))
(check! "ai.reset ok" arv "ok")
(define-values (akv _ake _akev) (call-rpc 25 (list "run-action" "ai.key" "   ")))
(check! "ai.key empty rejected" akv "empty key")
(define-values (auv _aue _auev) (call-rpc 26 (list "run-action" "ai.unknown" "")))
(check! "unknown ai action reported"
        (string-prefix? auv "unknown ai action") #t)
(define-values (puv _pue _puev) (call-rpc 27 (list "run-action" "plugins.unknown" "")))
(check! "unknown plugins action reported"
        (or (string-prefix? puv "unknown") (string-prefix? puv "no such")
            (string-contains? puv "unknown"))
        #t)

(kill-thread srv)
(delete-directory/files root)
(if (zero? failures)
    (printf "wire backend checks passed\n")
    (begin
      (printf "~a wire backend check(s) FAILED\n" failures)
      (exit 1)))
