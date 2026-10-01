#lang racket/base

;; Quicklinks: store CRUD, keyword claims, URL expansion with
;; percent-encoding, the one-line create grammar, and the engine wiring
;; (open rows, the quicklinks listing, window-command delegation).

(require racket/file
         racket/list
         racket/string
         rackunit
         "../app/backend.rkt"
         "../app/core/engine.rkt"
         "../app/core/paths.rkt"
         "../app/core/quicklinks.rkt"
         "../app/core/settings.rkt")

(define (row-id row) (list-ref row 0))
(define (row-arg row) (list-ref row 4))
(define (row-title row) (list-ref row 1))

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-qltest-~a" 'directory))
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

(test-case "store CRUD, keyword claims, and expansion"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-quicklink-store (quicklinks-path)))
     (link-save! store "YouTube" "https://www.youtube.com/results?search_query={query}" "yt")
     (link-save! store "Hacker News" "https://news.ycombinator.com" "hn")

     (check-equal? (length (link-list store)) 2)
     ;; Sorted by name: Hacker News first.
     (check-equal? (quicklink-name (car (link-list store))) "Hacker News")

     ;; A keyword claims "<keyword> …" and hands back the trailing text.
     (define claimed (link-by-keyword store "yt nature documentary"))
     (check-true (and claimed #t))
     (check-equal? (quicklink-name (car claimed)) "YouTube")
     (check-equal? (cdr claimed) "nature documentary")

     ;; {query} expands with percent-encoding; plain links expand to
     ;; themselves.
     (check-equal?
      (expand-link-url (car claimed) "nature documentary")
      "https://www.youtube.com/results?search_query=nature%20documentary")
     (define hn (car (link-list store)))
     (check-equal? (expand-link-url hn "anything") "https://news.ycombinator.com")

     ;; Delete round-trips.
     (check-true (link-delete! store (quicklink-id hn)))
     (check-equal? (length (link-list store)) 1))))

(test-case "engine: keyword rows, create grammar, listing, and open routing"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-quicklink-store (quicklinks-path)))
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:quicklink-store store
                                 #:plugin-manager #f))

     ;; The one-line create grammar offers a save row; running it stores
     ;; the link and notifies.
     (define rows (engine-search engine "add link yt https://youtube.com/?q={query} YouTube"))
     (define save-row (findf (lambda (r) (equal? (row-id r) "link.save")) rows))
     (check-true (and save-row #t))
     (define outcome (engine-run engine "link.save" (row-arg save-row)))
     (check-equal? (car outcome) "ok")
     (check-equal? (map car (cdr outcome)) '(notify))
     (check-equal? (length (link-list store)) 1)

     ;; The keyword now claims queries and the arg is the expanded URL.
     (define search-rows (engine-search engine "yt lofi"))
     (define open-row (findf (lambda (r) (equal? (row-id r) "link.open")) search-rows))
     (check-true (and open-row #t))
     (check-equal? (row-arg open-row)
                   "https://youtube.com/?q=lofi")

     ;; Opening routes through the web-open! guard (http(s) only).
     (define opened (engine-run engine "link.open" (row-arg open-row)))
     (check-equal? (car opened) "opened")
     (check-equal? (map car (cdr opened)) '(open-url))

     ;; The listing offers delete; the delete action removes the link.
     (define listing (engine-search engine "quicklinks"))
     (define delete-row (findf (lambda (r) (equal? (row-id r) "link.delete")) listing))
     (check-true (and delete-row #t))
     (check-equal? (car (engine-run engine "link.delete" (row-arg delete-row))) "ok")
     (check-equal? (length (link-list store)) 0))))

(test-case "window commands rank rows and delegate"
  (with-fresh-data-dir
   (lambda ()
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:plugin-manager #f))
     (define rows (engine-search engine "left half"))
     (define win-row (findf (lambda (r) (equal? (row-id r) "win.left")) rows))
     (check-true (and win-row #t))
     (check-equal? (list-ref win-row 3) "Window")
     ;; The engine never executes window commands: it hands the host a
     ;; delegated status, and the action still feeds the recents table.
     (define outcome (engine-run engine "win.left" ""))
     (check-equal? (car outcome) "delegated")
     (check-equal? (cdr outcome) '()))))

(test-case "settings rows cycle and toggle through the backend route"
  (with-fresh-data-dir
   (lambda ()
     (define manager (make-settings-manager (settings-path)))
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:plugin-manager #f))
     (parameterize ([current-settings manager]
                    [current-engine engine])
       ;; The settings query lists every managed key with its value.
       (define rows (rows-for engine "settings"))
       (define keys (map (lambda (r) (row-arg r)) rows))
       (check-true (pair? (member "theme" keys)) "theme row present")
       (check-true (pair? (member "clipboard-enabled" keys)) "clipboard row present")

       ;; Running the theme row cycles system → light and reports back.
       (define outcome (settings-act! "theme"))
       (check-equal? (car outcome) "ok")
       (check-equal? (settings-get manager 'theme) "light")

       ;; Boolean keys toggle.
       (check-true (settings-get manager 'clipboard-enabled))
       (settings-act! "clipboard-enabled")
       (check-false (settings-get manager 'clipboard-enabled))

       ;; Unknown keys are loud.
       (check-true (string-contains? (car (settings-act! "nope")) "unknown"))))))

(test-case "run-action routes settings.* rows in the live backend surface"
  (with-fresh-data-dir
   (lambda ()
     (define manager (make-settings-manager (settings-path)))
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:plugin-manager #f))
     (parameterize ([current-settings manager]
                    [current-engine engine])
       ;; Routing proof without a live RVT1 server: the engine would answer
       ;; "unknown action: settings.set"; the settings route answers
       ;; "unknown setting: nope".
       (check-true (string-contains? (run-action "settings.set" "nope")
                                     "unknown setting"))
       ;; Event-bearing outcomes raise on emit (no server in tests) — but
       ;; the settings write happens before emission, so catch and assert
       ;; the state change through the real entry point.
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (run-action "settings.set" "theme"))
       (check-equal? (settings-get manager 'theme) "light")
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (run-action "settings.set" "web-search-enabled"))
       (check-false (settings-get manager 'web-search-enabled))
       ;; Boolean badges read as on/off, never Racket's #t. (The
       ;; clipboard toggle was never touched: still its default, on.)
       (define rows (rows-for engine "settings"))
       (define clip-row
         (findf (lambda (r) (equal? (list-ref r 4) "clipboard-enabled")) rows))
       (check-equal? (list-ref clip-row 7) "on")))))
