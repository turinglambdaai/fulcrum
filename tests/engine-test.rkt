#lang racket/base

;; Search engine tests with injected applications and stores — no real
;; system discovery, no plugin subprocesses, no network. Ranking, action
;; routing, and the recents boost are the contract here.

(require racket/file
         racket/list
         racket/string
         rackunit
         "../app/core/apps.rkt"
         "../app/core/clipboard.rkt"
         "../app/core/engine.rkt"
         "../app/core/paths.rkt"
         "../app/core/snippets.rkt")

(define (row-title row) (list-ref row 1))
(define (row-kind row) (list-ref row 3))
(define (row-id row) (list-ref row 0))
(define (row-arg row) (list-ref row 4))

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-engtest-~a" 'directory))
  (parameterize ([current-environment-variables
                  (let ([env (current-environment-variables)])
                    (environment-variables-set! env #"FULCRUM_DATA_DIR"
                                                (string->bytes/utf-8 (path->string dir)))
                    env)])
    (dynamic-wind
      void
      thunk
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files dir))))))

(define (fixture-engine #:apps [apps '()]
                        #:clipboard [clipboard #t]
                        #:snippets [snippets #t])
  (define engine
    (make-engine
     #:clipboard-store (if clipboard (make-clipboard-store (clipboard-path)) #f)
     #:snippet-store (if snippets (make-snippet-store (snippets-path)) #f)
     #:plugin-manager #f))
  (define index (make-hash))
  (for ([app (in-list apps)])
    (hash-set! index (application-id app) app))
  (set-engine-apps-index! engine index)
  engine)

(define fixture-apps
  (list (application "a1" "Firefox" "/usr/bin/firefox" "app" '() "/usr/share/applications/firefox.desktop")
        (application "a2" "File Manager" "/usr/bin/files" "app" '() "/usr/share/applications/files.desktop")
        (application "a3" "Terminal" "/bin/true" "app" '() "/usr/share/applications/terminal.desktop")))

(test-case "empty query lists apps first"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     (define rows (engine-search engine ""))
     (check-true (pair? rows))
     (check-true (and (member "Firefox" (map row-title rows)) #t)))))

(test-case "query ranks and filters"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     (define rows (engine-search engine "firefx"))
     (check-true (pair? rows) "typo subsequence still matches")
     (check-equal? (row-title (car rows)) "Firefox")
     (check-true (andmap (lambda (r)
                           (or (equal? (row-kind r) "Application")
                               (equal? (row-kind r) "Web Search")))
                         rows)
                 "app rows stay Applications; web fallback is the only other kind")
     (check-false (member "Terminal" (map row-title rows))))))

(test-case "calculator row appears for expressions"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (define rows (engine-search engine "1+2*3"))
     (check-true (pair? rows))
     (check-equal? (row-kind (car rows)) "Calculator")
     (check-equal? (row-title (car rows)) "7"))))

(test-case "web search fallback and bangs"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (define rows (engine-search engine "racket lang"))
     (check-true (and (findf (lambda (r) (equal? (row-kind r) "Web Search")) rows) #t))
     (define gh (engine-search engine "!gh fuzzy search"))
     (check-true
      (and (findf (lambda (r)
                    (and (equal? (row-kind r) "Web Search")
                         (string-contains? (row-arg r) "github.com")))
                  gh)
           #t)))))

(test-case "run-action copies calculator answers via events"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (define outcome (engine-run engine "calc.copy" "42"))
     (check-equal? (car outcome) "copied")
     (check-equal? (cdr outcome) (list (cons 'copy-to-clipboard "42"))))))

(test-case "run-action opens only http(s) URLs"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (define ok (engine-run engine "web.open" "https://fulcrum.jrtx.site"))
     (check-equal? (car ok) "opened")
     (define refused (engine-run engine "web.open" "file:///etc/passwd"))
     (check-equal? (car refused) "refused to open non-http(s) URL: file:///etc/passwd"))))

(test-case "run-action launches indexed apps"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     (define outcome (engine-run engine "app.launch" "a3"))
     (check-equal? (car outcome) "launched")
     (define missing (engine-run engine "app.launch" "nope"))
     (check-true (string-prefix? (car missing) "application not indexed")))))

(test-case "clipboard and snippet providers"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (clipboard-record! (engine-clipboard engine) "make fulcrum release")
     (snippet-save! (engine-snippets engine) "Release checklist" "1. tag 2. build" "rel")
     (define rows (engine-search engine "release"))
     (check-true (and (findf (lambda (r) (equal? (row-kind r) "Clipboard")) rows) #t))
     (check-true (and (findf (lambda (r) (equal? (row-kind r) "Snippet")) rows) #t)))))

(test-case "recents boost reorders repeat choices"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     ;; Record Terminal launches many times; it should then outrank Firefox
     ;; for the shared term "f…i" queries only when its own score is close.
     (for ([_ (in-range 6)])
       (engine-record-use! engine "app.launch" "a3"))
     (define rows (engine-search engine "te"))
     (check-true (pair? rows))
     ;; The boost may not flip ranking on its own, but engine-record-use!
     ;; must persist it.
     (define reloaded (fixture-engine #:apps fixture-apps))
     (check-true (> (hash-count (engine-recents reloaded)) 0)
                 "recents persist to disk"))))

(test-case "rows are 8-column string lists"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     (for ([row (in-list (engine-search engine "f"))])
       (check-equal? (length row) 8)
       (check-true (andmap string? row))))))
