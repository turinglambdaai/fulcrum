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
(define plugins-mod
  (build-path fulcrum-root "app" "core" "plugins.rkt"))
(define plugin-manager-path*
  (dynamic-require plugins-mod 'plugin-manager-path))
(define plugin-id* (dynamic-require plugins-mod 'plugin-id))
(define engine-plugins*
  (dynamic-require (build-path fulcrum-root "app" "core" "engine.rkt")
                   'engine-plugins))
(define make-plugin-manager*
  (dynamic-require plugins-mod 'make-plugin-manager))
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
(define app-count* (get "app/core/engine.rkt" 'engine-app-count))

(define manager (make-settings-manager (settings-path)))
(define eng (make-engine
             #:clipboard-store (make-clipboard (clipboard-path))
             #:snippet-store (make-snippets (snippets-path))
             #:plugin-manager (make-plugin-manager*
                               (build-path root "plugins"))))
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

;; Every host consumes the same eight cells, including the current badge.
(define-values (quick-rows quick-error _quick-events)
  (call-rpc 40 (list "search" "")))
(check! "home search no error" quick-error #f)
(define quick-theme
  (for/first ([row (in-list quick-rows)]
              #:when (and (equal? (car row) "settings.set")
                          (equal? (list-ref row 4) "theme")))
    row))
(check! "home theme row has eight cells" (and quick-theme (length quick-theme)) 8)
(check! "home theme badge is current value"
        (and quick-theme (list-ref quick-theme 7)) "system")
(define-values (setting-rows setting-error _setting-events)
  (call-rpc 41 (list "search" "settings")))
(check! "settings search no error" setting-error #f)
(define setting-theme
  (for/first ([row (in-list setting-rows)]
              #:when (and (equal? (car row) "settings.set")
                          (equal? (list-ref row 4) "theme")))
    row))
(check! "settings theme badge is current value"
        (and setting-theme (list-ref setting-theme 7)) "system")
(define-values (setting-result setting-run-error _setting-run-events)
  (call-rpc 42 (list "run-action" "settings.set" "theme")))
(check! "settings action succeeds" (list setting-result setting-run-error)
        '("ok" #f))
(define-values (updated-rows _updated-error _updated-events)
  (call-rpc 43 (list "search" "settings")))
(define updated-theme
  (for/first ([row (in-list updated-rows)]
              #:when (and (equal? (car row) "settings.set")
                          (equal? (list-ref row 4) "theme")))
    row))
(check! "settings badge updates after cycling"
        (and updated-theme (list-ref updated-theme 7)) "light")

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
;; (This call used to hang inside the serve worker on an older rivet and
;; lived commented out as a KNOWN ISSUE; with current rivet the worker
;; answers over the same pipe transport in ~200 ms, so it is wired back in.
;; The handler's exn? guard keeps a discovery failure a -1 result either way.)
(define-values (irv ire _irev) (call-rpc 17 (list "index-rebuild")))
(check! "index-rebuild no error" ire #f)
(check! "index-rebuild returns the index size"
        irv (app-count* (current-engine)))

;; app index freshness: the search path rebuilds when the discovery roots
;; changed since the cached fingerprint (installs during a session used to
;; stay invisible until relaunch). Drive the refresh directly and watch the
;; cache stamp; the search RPCs above already ran it once with cache #f.
(define refresh* (get "app/backend.rkt" 'refresh-app-index-if-stale!))
(define fingerprint* (get "app/core/apps.rkt" 'application-roots-fingerprint))
(define cache* (get "app/backend.rkt" 'app-roots-fingerprint-cache))
(cache* #f)
(refresh*)
(check! "refresh with no cache rebuilds and stamps the fingerprint"
        (equal? (cache*) (fingerprint*)) #t)
(define count-after-refresh (app-count* (current-engine)))
(refresh*)
(check! "refresh with unchanged roots is a no-op" (cache*) (fingerprint*))
(check! "no-op refresh keeps the engine index"
        (app-count* (current-engine)) count-after-refresh)
(cache* (list (list "/definitely/not/a/root" #f)))
(refresh*)
(check! "stale cache triggers a rebuild"
        (equal? (cache*) (fingerprint*)) #t)

;; plugins-reload is void and harmless with an empty gallery
(define-values (prv pre _prev) (call-rpc 18 (list "plugins-reload")))
(check! "plugins-reload no error" pre #f)

;; update-check over the wire: pin the feed at an unreachable local URL so
;; the section never touches the network, then check the record shape and
;; the honest error. The record travels as a field-ordered list.
(define settings-set!*
  (dynamic-require (build-path fulcrum-root "app" "core" "settings.rkt")
                   'settings-set!))
(void (settings-set!* manager 'update-base-url "https://127.0.0.1:9/fulcrum"))
(define-values (ucv uce _ucev) (call-rpc 40 (list "update-check" #t)))
(check! "update-check no error" uce #f)
(check! "update-check record shape"
        (and (list? ucv) (= (length ucv) 8) (string? (list-ref ucv 0))
             (string? (list-ref ucv 2))
             (string=? (list-ref ucv 0) "error")
             (string-contains? (list-ref ucv 1) "127.0.0.1")
             #t)
        #t)

;; the silent variant answers "throttled" right after the manual check
;; above stamped update-last-check (the 4-hour throttle is backend-owned)
(define-values (uc2v uc2e _uc2ev) (call-rpc 41 (list "update-check" #f)))
(check! "update-check silent no error" uc2e #f)
(check! "silent check right after a manual one is throttled"
        (and (list? uc2v) (string=? (list-ref uc2v 0) "throttled")) #t)

;; update-state after the failed check above: phase "error" with the
;; reason, the single failure channel hosts poll
(define-values (usv use _usev) (call-rpc 42 (list "update-state")))
(check! "update-state no error" use #f)
(check! "update-state error shape"
        (and (list? usv) (= (length usv) 5)
             (string=? (list-ref usv 0) "error")
             (string-contains? (or (list-ref usv 2) "") "127.0.0.1"))
        #t)

;; update rows: the idle surface offers exactly the check row — no
;; download row before a candidate exists
(define-values (urv ure _urev) (call-rpc 43 (list "search" "update")))
(check! "update rows no error" ure #f)
(define update-ids (for/list ([row (in-list urv)] #:when (string=? (list-ref row 3) "Update"))
                     (list-ref row 0)))
(check! "update rows offer a check" (member "update.check" update-ids) '("update.check"))
(check! "no download row before a candidate"
        (member "update.download" update-ids) #f)

;; ---- settings surface behind the native settings windows -----------------
;; settings-list speaks on/off for booleans (hosts compare against "off"),
;; settings-set takes the same words back, the leading settings row opens
;; the host window by delegation, and ai-status reports readiness without
;; ever carrying the key across the wire.
(define (setting-value rows key)
  (for/first ([row (in-list rows)] #:when (string=? (list-ref row 0) key))
    (list-ref row 1)))
(define-values (sl2 sl2e _sl2ev) (call-rpc 50 (list "settings-list")))
(check! "settings-list no error (2)" sl2e #f)
(check! "settings-list booleans read on/off"
        (setting-value sl2 "expansion-enabled") "on")
(define-values (ssv sse _ssev)
  (call-rpc 51 (list "settings-set" "expansion-enabled" "off")))
(check! "settings-set accepts off" sse #f)
(check! "settings-set returns true" ssv #t)
(define-values (sl3 _sl3e _sl3ev) (call-rpc 52 (list "settings-list")))
(check! "settings-set off round-trips through settings-list"
        (setting-value sl3 "expansion-enabled") "off")
(call-rpc 53 (list "settings-set" "expansion-enabled" "on"))
(define-values (_langv _lange lang-events)
  (call-rpc 63 (list "settings-set" "language" "en")))
(check! "language changes push live host state"
        (and (member '("$state" ("language" "en")) lang-events) #t) #t)
(call-rpc 64 (list "settings-set" "language" "zh"))
(define-values (sov _soe _soev) (call-rpc 54 (list "run-action" "settings.open" "")))
(check! "settings.open delegates to the host" sov "delegated")
(define-values (erows _ere _erev) (call-rpc 55 (list "search" "")))
(check! "empty query offers the settings window row"
        (and (for/or ([row (in-list erows)])
               (string=? (list-ref row 0) "settings.open"))
             #t)
        #t)
;; The row contract is positional: a column too many silently drops the
;; row on hosts that check the width (the quick settings rows once had 9).
(check! "every empty-query row has exactly 8 cells"
        (for/and ([row (in-list erows)]) (= (length row) 8)) #t)
(define-values (srows _sre _srev) (call-rpc 56 (list "search" "settings")))
(check! "settings query leads with the window row"
        (and (pair? srows) (string=? (list-ref (car srows) 0) "settings.open")) #t)
(check! "every settings-query row has exactly 8 cells"
        (for/and ([row (in-list srows)]) (= (length row) 8)) #t)
(define-values (as1 ase _asev) (call-rpc 57 (list "ai-status")))
(check! "ai-status no error" ase #f)
(check! "ai-status without a provider" as1 "no provider configured")
(call-rpc 58 (list "settings-set" "ai-provider" "openai"))
(define-values (as2 _as2e _as2ev) (call-rpc 59 (list "ai-status")))
(check! "ai-status without a key" as2 "no API key for openai")
(define-values (aksv _aksve _aksvev) (call-rpc 60 (list "run-action" "ai.key" "sk-test-key")))
(check! "ai.key saves the key" aksv "ok")
(define-values (as3 _as3e _as3ev) (call-rpc 61 (list "ai-status")))
(check! "ai-status ready once a key exists" as3 "ready")
(call-rpc 62 (list "settings-set" "ai-provider" ""))

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


;; ---- plugin center end-to-end (unix: the fixture spawns /bin/sh) ---------

(when (eq? (system-type 'os) 'unix)
  (define fixture-dir
    (make-temporary-file "fulcrum-wire-plugin-~a" 'directory))
  (define plugin-dir (build-path fixture-dir "echo"))
  (make-directory* plugin-dir)
  (call-with-output-file (build-path plugin-dir "manifest.json")
    (lambda (out)
      (displayln
       (string-append
        "{\"id\":\"echo\",\"name\":\"Echo\",\"version\":\"1.0.0\","
        "\"entry\":{\"exec\":[\"/bin/sh\",\"plugin.sh\"]},"
        "\"commands\":[{\"id\":\"find\",\"name\":\"Find\",\"keyword\":\"echo\"}]}")
       out))
    #:exists 'truncate)
  (call-with-output-file (build-path plugin-dir "plugin.sh")
    (lambda (out)
      (displayln
       "#!/bin/sh\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *'\"op\":\"run\"'*) printf '%s\\n' '{\"request_id\":2,\"status\":\"ok\"}';;\n    *) printf '%s\\n' '{\"request_id\":1,\"results\":[{\"title\":\"Echo result\",\"arg\":\"42\"}]}';;\n  esac\ndone"
       out))
    #:exists 'truncate)

  (define-values (insv _i1 _i2)
    (call-rpc 30 (list "run-action" "plugins.install"
                       (path->string plugin-dir))))
  (check! "plugins.install ok" insv "ok")

  (define mgr (engine-plugins* (current-engine)))
  (define-values (plv2 _p1 _p2) (call-rpc 31 (list "plugins-list")))
  (check! "installed plugin listed"
          (and (member "echo" (for/list ([row (in-list plv2)])
                                (list-ref row 0)))
               #t)
          #t)

  (define-values (ech-rows _e1 _e2) (call-rpc 32 (list "search" "echo 7")))
  (check! "search surfaces the plugin row"
          (and (findf (lambda (row)
                        (string=? (list-ref row 0) "plugin:echo:find"))
                      ech-rows)
               #t)
          #t)

  (define-values (ech-run _e3 _e4)
    (call-rpc 33 (list "run-action" "plugin:echo:find" "42")))
  (check! "plugin action runs" ech-run "ok")

  (define-values (unv _u1 _u2)
    (call-rpc 34 (list "run-action" "plugins.uninstall" "echo")))
  (check! "plugins.uninstall ok" unv "ok")
  (check! "uninstalled plugin gone from disk"
          (not (directory-exists?
                (build-path (plugin-manager-path* mgr) "echo")))
          #t)

  (delete-directory/files fixture-dir))

(kill-thread srv)
(delete-directory/files root)
(if (zero? failures)
    (printf "wire backend checks passed\n")
    (begin
      (printf "~a wire backend check(s) FAILED\n" failures)
      (exit 1)))
