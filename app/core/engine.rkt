#lang racket/base

;; Fulcrum search engine.
;;
;; One entry point for the UI (engine-search), one for actions
;; (engine-run). Providers register result rows; the engine scores them with
;; the fuzzy matcher, adds a recents boost for previously chosen actions, and
;; returns the top K rows. All ranking lives here so the native UIs render a
;; single, consistent list.
;;
;; Wire rows are positional string lists of exactly 8 columns:
;;   (id title subtitle kind arg icon hint badge)
;; `id` is a global action id, `arg` the provider-specific payload. The
;; engine-run contract routes (id arg) pairs back to the owning provider.

(require racket/bool
         racket/contract
         racket/list
         racket/math
         racket/string
         "apps.rkt"
         "calc.rkt"
         "clipboard.rkt"
         "fuzzy.rkt"
         "gallery.rkt"
         "paths.rkt"
         "plugins.rkt"
         "store.rkt"
         "snippets.rkt"
         "syscmd.rkt"
         "websearch.rkt")

(provide (struct-out engine)
         (struct-out result)
         make-engine
         engine-search
         engine-run
         engine-rebuild-index!
         engine-app-count
         engine-record-use!
         result->row)

(struct result
  (id title subtitle kind arg icon hint badge keywords priority)
  #:transparent)

(struct engine
  (apps-index clipboard snippets plugins syscmds recents-path recents recents-lock max-results)
  #:mutable)

(define (result->row r)
  (list (result-id r) (result-title r) (result-subtitle r) (result-kind r)
        (result-arg r) (result-icon r) (result-hint r) (result-badge r)))

;; ---- recents ------------------------------------------------------------

(define recents-max-entries 500)

(define (load-recents path)
  (define raw (read-json-file path '()))
  (if (list? raw)
      (for/hash ([entry (in-list raw)]
                 #:when (and (hash? entry)
                             (string? (hash-ref entry 'key #f))
                             (hash-ref entry 'count #f)))
        (values (hash-ref entry 'key)
                (cons (hash-ref entry 'count) (hash-ref entry 'ts 0))))
      (hash)))

(define (recents-key id arg) (string-append id "\u0000" arg))

(define (recents-boost engine id arg)
  (define entry (hash-ref (engine-recents engine) (recents-key id arg) #f))
  (if entry
      (let* ([count (car entry)]
             [age-ms (- (current-inexact-milliseconds) (cdr entry))]
             [recency (cond [(< age-ms (* 24 3600 1000)) 1.0]
                            [(< age-ms (* 7 24 3600 1000)) 0.7]
                            [else 0.4])])
        (exact-floor (* (min 150 (* 25 (min 6 count))) recency)))
      0))

(define (engine-record-use! engine id arg)
  (call-with-semaphore
   (engine-recents-lock engine)
   (lambda ()
     (define key (recents-key id arg))
     (define table (engine-recents engine))
     (define previous (hash-ref table key (cons 0 0)))
     (define next (cons (add1 (car previous)) (current-inexact-milliseconds)))
     (define updated (hash-set table key next))
     ;; Bound the table: drop the least recently used entries beyond the cap.
     (set-engine-recents!
      engine
      (if (<= (hash-count updated) recents-max-entries)
          updated
          (for/hash ([entry (in-list (take (sort (hash->list updated)
                                                 >
                                                 #:key (lambda (e) (cdr (cdr e))))
                                           recents-max-entries))])
            (values (car entry) (cdr entry)))))
     (write-json-atomic!
      (engine-recents-path engine)
      (for/list ([entry (in-list (hash->list (engine-recents engine)))])
        (hasheq 'key (car entry)
                'count (car (cdr entry))
                'ts (cdr (cdr entry))))))))

;; ---- providers ----------------------------------------------------------

(define (apps-provider engine)
  (define apps (hash-values (engine-apps-index engine)))
  (lambda (query)
    (if (zero? (string-length query))
        (let ([top (take (sort apps string<? #:key application-name)
                         (min 9 (length apps)))])
          (for/list ([app (in-list top)])
            (result "app.launch" (application-name app)
                    (application-path app) "Application"
                    (application-id app) "app" "" ""
                    (string-join (application-keywords app) " ")
                    100)))
        (for/list ([app (in-list apps)])
          (define score
            (fuzzy-score-fields
             query
             (list (cons 1.0 (application-name app))
                   (cons 0.7 (string-join (application-keywords app) " "))
                   (cons 0.4 (application-path app)))))
          (and score
               (result "app.launch" (application-name app)
                       (application-path app) "Application"
                       (application-id app) "app" "" ""
                       (string-join (application-keywords app) " ")
                       (+ score 100)))))))

(define (calc-looks-like-expression? query)
  (and (regexp-match? #px"[-+(0-9.]" query)
       (regexp-match? #px"[0-9]" query)))

(define (calc-provider engine)
  (lambda (query)
    (if (or (zero? (string-length query))
            (not (calc-looks-like-expression? query)))
        '()
        (with-handlers ([exn:calc? (lambda (_) '())])
          (define answer (calculate-display query))
          (list (result "calc.copy" answer query "Calculator" answer
                        "calculator" "" "Copy" "" 140))))))

(define (clipboard-provider engine)
  (define store (engine-clipboard engine))
  (if store
      (lambda (query)
        (for/list ([item (in-list (if (zero? (string-length query))
                                      (clipboard-list store 6)
                                      (clipboard-search store query)))])
          (define preview
            (let ([text (string-replace (clipboard-item-text item) "\n" " ")])
              (if (> (string-length text) 120)
                  (string-append (substring text 0 120) "…")
                  text)))
          (result "clip.copy" preview
                  (format "~a · pinned: ~a"
                          (clipboard-item-id item)
                          (if (clipboard-item-pinned? item) "yes" "no"))
                  "Clipboard"
                  (clipboard-item-id item) "clipboard" "" ""
                  (clipboard-item-text item)
                  (if (zero? (string-length query)) 60 80))))
      (lambda (query) '())))

(define (snippets-provider engine)
  (define store (engine-snippets engine))
  (if store
      (lambda (query)
        (for/list ([s (in-list (if (zero? (string-length query))
                                   (let ([all (snippet-list store)])
                                     (take all (min 6 (length all))))
                                   (snippet-search store query)))])
          (result "snip.copy" (snippet-name s)
                  (snippet-keyword s) "Snippet"
                  (snippet-id s) "snippet" "" ""
                  (string-append (snippet-name s) " " (snippet-keyword s) " " (snippet-text s))
                  (if (zero? (string-length query)) 60 85))))
      (lambda (query) '())))

(define (web-provider engine)
  (lambda (query)
    (if (zero? (string-length query))
        '()
        (let ([target (web-search-row-target query)])
          (if target
              (let* ([prefix (car target)]
                     [url (cdr target)]
                     [label
                      (cond
                        [(string=? prefix "web") (format "Search the web for “~a”" query)]
                        [else (format "Search: ~a" url)])])
                (list (result "web.open" label url "Web Search" url "globe" "" ""
                              "" (if (string=? prefix "web") 15 90))))
              '())))))

(define (system-provider engine)
  (lambda (query)
    (for/list ([cmd (in-list (engine-syscmds engine))])
      (define score
        (if (zero? (string-length query))
            50
            (fuzzy-score-fields query (list (cons 1.0 (system-command-name cmd))))))
      (and score
           (result "sys.run" (system-command-name cmd)
                   "System command" "System"
                   (system-command-name cmd) "system" "" ""
                   "" (+ score 50))))))

(define (plugins-provider engine)
  (define manager (engine-plugins engine))
  (if manager
      (lambda (query)
        (for/list ([row (in-list (plugin-manager-query manager query))])
          (result (string-append "plugin:" (list-ref row 4))
                  (list-ref row 0)
                  (list-ref row 1)
                  "Plugin"
                  (list-ref row 2)
                  (list-ref row 3)
                  "" ""
                  (list-ref row 0)
                  70)))
      (lambda (query) '())))

;; The plugin gallery rides the same row contract as everything else:
;; query "gallery"/"plugins" lists every first-party plugin (installed
;; rows uninstall, the rest install); any other query fuzzy-suggests
;; installs for the not-installed entries. Kind stays "Plugin" so hosts
;; render the plugin icon without per-host gallery work.
(define gallery-listing-words '("gallery" "plugins" "plugin"))

(define (gallery-row-for entry installed?)
  (if installed?
      (result "gallery.uninstall" (gallery-entry-name entry)
              (format "v~a · installed — select to uninstall"
                      (gallery-entry-version entry))
              "Plugin"
              (gallery-entry-id entry) "plugin" "" "Installed"
              (string-append (gallery-entry-name entry) " uninstall remove plugin gallery")
              120)
      (result "gallery.install" (format "Install ~a" (gallery-entry-name entry))
              (format "v~a · ~a" (gallery-entry-version entry)
                      (gallery-entry-description entry))
              "Plugin"
              (gallery-entry-id entry) "plugin" "" "Install"
              (string-append (gallery-entry-name entry) " install plugin gallery "
                             (gallery-entry-description entry))
              120)))

(define (gallery-provider engine)
  (lambda (query)
    (if (or (not (engine-plugins engine))
            (zero? (string-length query)))
        '()
        (let ([catalog (gallery-catalog)])
          (if (member (string-downcase query) gallery-listing-words)
              (for/list ([entry (in-list catalog)])
                (gallery-row-for
                 entry
                 (gallery-entry-installed? (plugins-dir) entry)))
              (for/list ([entry (in-list catalog)]
                         #:when (let ([installed?
                                       (gallery-entry-installed?
                                        (plugins-dir) entry)])
                                  (and (not installed?)
                                       (fuzzy-score-fields
                                        query
                                        (list (cons 1.0 (gallery-entry-name entry))
                                              (cons 0.5 (gallery-entry-description entry)))))))
                (define row (gallery-row-for entry #f))
                (result (result-id row) (result-title row) (result-subtitle row)
                        (result-kind row) (result-arg row) (result-icon row)
                        (result-hint row) (result-badge row)
                        (result-keywords row)
                        (+ 20 (fuzzy-score-fields
                               query
                               (list (cons 1.0 (gallery-entry-name entry))
                                     (cons 0.5 (gallery-entry-description entry))))))))))))

;; ---- engine -------------------------------------------------------------

(define/contract (make-engine
                  #:clipboard-store [clipboard-store #f]
                  #:snippet-store [snippet-store #f]
                  #:plugin-manager [plugin-manager #f]
                  #:max-results [max-results 12])
  (->* (#:clipboard-store (or/c clipboard-store? #f)
        #:snippet-store (or/c snippet-store? #f)
        #:plugin-manager (or/c plugin-manager? #f))
       (#:max-results (and/c exact-integer? (>=/c 1) (<=/c 50)))
       engine?)
  (engine (make-hash)
          clipboard-store
          snippet-store
          plugin-manager
          (system-commands)
          (recents-path)
          (load-recents (recents-path))
          (make-semaphore 1)
          max-results))

(define (engine-rebuild-index! engine)
  (define apps (discover-applications))
  (define index (make-hash))
  (for ([app (in-list apps)])
    (hash-set! index (application-id app) app))
  (set-engine-apps-index! engine index)
  (length apps))

(define/contract (engine-app-count engine)
  (-> engine? exact-nonnegative-integer?)
  (hash-count (engine-apps-index engine)))

(define (all-provider-results engine query)
  (append
   ((calc-provider engine) query)
   ((apps-provider engine) query)
   ((clipboard-provider engine) query)
   ((snippets-provider engine) query)
   ((web-provider engine) query)
   ((system-provider engine) query)
   ((plugins-provider engine) query)
   ((gallery-provider engine) query)))

(define/contract (engine-search engine query)
  (-> engine? string? (listof (listof string?)))
  (define q (string-trim (or query "")))
  (define candidates (all-provider-results engine q))
  (define scored
    (for/list ([r (in-list candidates)]
               #:when (result? r))
      (cons (+ (or (result-priority r) 0)
               (recents-boost engine (result-id r) (result-arg r)))
            r)))
  (define top
    (take (sort scored > #:key car)
          (min (engine-max-results engine) (length scored))))
  (map result->row (map cdr top)))

;; ---- actions ------------------------------------------------------------

(define (clip-copy-event! engine id)
  (define item (clipboard-item-ref (engine-clipboard engine) id))
  (if item
      (cons "copied" (list (cons 'copy-to-clipboard (clipboard-item-text item))))
      (cons (format "clipboard item not found: ~a" id) '())))

(define (snip-copy-event! engine id)
  (define s (snippet-ref (engine-snippets engine) id))
  (if s
      (cons "copied" (list (cons 'copy-to-clipboard (snippet-text s))))
      (cons (format "snippet not found: ~a" id) '())))

(define (app-launch! engine id)
  (define app (hash-ref (engine-apps-index engine) id #f))
  (if app
      (if (application-launch app)
          (cons "launched" '())
          (cons (format "failed to launch: ~a" (application-name app)) '()))
      (cons (format "application not indexed: ~a" id) '())))

(define (allowed-url? url)
  (or (string-prefix? url "http://")
      (string-prefix? url "https://")))

(define (web-open! url)
  (if (allowed-url? url)
      (cons "opened" (list (cons 'open-url url)))
      (cons (format "refused to open non-http(s) URL: ~a" url) '())))

(define (sys-run! engine name)
  (define cmd (findf (lambda (c) (string=? (system-command-name c) name))
                     (engine-syscmds engine)))
  (if cmd
      (if (run-system-command! cmd)
          (cons "ok" '())
          (cons (format "failed to run system command: ~a" name) '()))
      (cons (format "unknown system command: ~a" name) '())))

;; Shared body of the gallery install/uninstall actions: run the operation,
;; reload the plugin manager so new commands are queryable immediately, and
;; tell the host what happened.
(define (gallery-act! engine op verb arg)
  (define outcome (op (plugins-dir) arg))
  (if outcome
      (cons outcome '())
      (let ([entry (findf (lambda (e)
                            (string=? (gallery-entry-id e) arg))
                          (gallery-catalog))])
        (when (engine-plugins engine)
          (plugin-manager-reload! (engine-plugins engine)))
        (define label (if entry (gallery-entry-name entry) arg))
        (cons "ok" (list (cons 'notify (format "~a ~a" verb label)))))))

(define/contract (engine-run engine id arg)
  (-> engine? string? string? (cons/c string? (listof (cons/c symbol? string?))))
  (define (finish outcome)
    (when (member (car outcome) (list "ok" "launched" "copied" "opened"))
      (engine-record-use! engine id arg))
    outcome)
  (cond
    [(string=? id "app.launch") (finish (app-launch! engine arg))]
    [(string=? id "calc.copy")
     (finish (cons "copied" (list (cons 'copy-to-clipboard arg))))]
    [(string=? id "clip.copy") (finish (clip-copy-event! engine arg))]
    [(string=? id "snip.copy") (finish (snip-copy-event! engine arg))]
    [(string=? id "web.open") (finish (web-open! arg))]
    [(string=? id "sys.run") (finish (sys-run! engine arg))]
    [(string=? id "gallery.install")
     (finish (gallery-act! engine gallery-install! "Installed" arg))]
    [(string=? id "gallery.uninstall")
     (finish (gallery-act! engine gallery-uninstall! "Uninstalled" arg))]
    [(string-prefix? id "plugin:")
     (finish
      (let ([status (plugin-manager-run! (engine-plugins engine)
                                         (substring id (string-length "plugin:"))
                                         arg)])
        (if (string=? status "ok")
            (cons "ok" '())
            (cons (format "plugin action failed: ~a" status) '()))))]
    [else (cons (format "unknown action: ~a" id) '())]))
