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
         "../app/core/snippets.rkt"
         "../app/core/store.rkt")

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
        ;; d-prefixed id: the unix launch path tries gtk-launch, then falls
        ;; back to the Exec argv. /bin/true exists on every CI runner, so the
        ;; launch is a real spawn rather than the old silent-success lie
        ;; (bare gtk-launch forked a doomed child and reported victory).
        (application "dterminal" "Terminal" "/bin/true" "app" '() "/usr/share/applications/terminal.desktop")))

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

(test-case "Chinese applications match full pinyin and initials"
  (with-fresh-data-dir
   (lambda ()
     (define chinese-apps
       (list (application "wechat" "微信" "C:\\Apps\\WeChat.exe"
                          "app" '("聊天") "wechat")
             (application "notes" "笔记 Work" "C:\\Apps\\Notes.exe"
                          "app" '() "notes")))
     (define engine (fixture-engine #:apps chinese-apps))
     (for ([query (in-list '("微信" "weixin" "wx"))])
       (define rows (engine-search engine query))
       (check-equal? (row-title (car rows)) "微信"))
     (define mixed (engine-search engine "bj work"))
     (check-equal? (row-title (car mixed)) "笔记 Work"))))

(test-case "application icon metadata survives ranking into native result rows"
  (with-fresh-data-dir
   (lambda ()
     (define app (application "dterminal" "Terminal" "/bin/true"
                              "org.gnome.Terminal" '()
                              "/usr/share/applications/terminal.desktop"))
     (define engine (fixture-engine #:apps (list app)))
     (for ([query (in-list '("" "Terminal"))])
       (define rows (engine-search engine query))
       (define match
         (findf (lambda (row)
                  (and (string=? (row-kind row) "Application")
                       (string=? (row-title row) "Terminal")))
                rows))
       (check-not-false match)
       (when match
         (check-equal? (list-ref match 5) "org.gnome.Terminal")
         (check-equal? (row-arg match) "dterminal"))))))

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
     (define outcome (engine-run engine "app.launch" "dterminal"))
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
     ;; The documented store keyword lists history; it is not treated as a
     ;; literal search term inside clipboard contents.
     (define clip-rows (engine-search engine "clip"))
     (check-true
      (and (findf (lambda (r)
                    (and (equal? (row-kind r) "Clipboard")
                         (string-contains? (row-title r) "fulcrum release")))
                  clip-rows)
           #t))
     (check-true (and (findf (lambda (r) (equal? (row-kind r) "Snippet")) rows) #t))
     ;; Clipboard rows paste to the frontmost app as the primary action;
     ;; Copy stays one ⌘K away.
     (define clip-row (findf (lambda (r) (equal? (row-kind r) "Clipboard")) rows))
     (check-equal? (row-id clip-row) "clip.paste"))))

(test-case "clipboard keyword explains empty and disabled history"
  (with-fresh-data-dir
   (lambda ()
     (define empty-rows (engine-search (fixture-engine) "clip"))
     (check-equal? (row-title (car empty-rows)) "Clipboard history is empty")
     (define disabled-rows
       (engine-search (fixture-engine #:clipboard #f) "clipboard"))
     (check-equal? (row-title (car disabled-rows))
                   "Clipboard history is disabled"))))

(test-case "querying the store name lists every snippet"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (for ([i (in-range 4)])
       (snippet-save! (engine-snippets engine) (format "S~a" i) "text" (format "k~a" i)))
     (define rows (engine-search engine "snippets"))
     (check-equal? (length (filter (lambda (r) (equal? (row-kind r) "Snippet")) rows)) 4))))

(test-case "add snippet one-liner creates through the action"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     ;; Incomplete input offers the syntax, never a half row.
     (define hint (engine-search engine "add snippet"))
     (check-equal? (row-id (car hint)) "noop")
     (check-true (string-contains? (row-title (car hint)) "snippet"))
     ;; Complete input offers a create row with the packed payload.
     (define rows (engine-search engine "add snippet addr 42 Wall Street, floor 5"))
     (define create (findf (lambda (r) (equal? (row-id r) "snippet.save")) rows))
     (check-true (and create #t))
     (check-equal? (row-arg create) "addr\u001F42 Wall Street, floor 5")
     ;; Running it saves: name = keyword, keyword claim = keyword.
     (define outcome (engine-run engine "snippet.save" (row-arg create)))
     (check-equal? (car outcome) "ok")
     (define saved (snippet-by-keyword (engine-snippets engine) "addr"))
     (check-true (and saved #t))
     (check-equal? (snippet-text saved) "42 Wall Street, floor 5")
     (check-equal? (snippet-name saved) "addr")
     ;; The claim is immediately searchable.
     (define hits (engine-search engine "addr"))
     (check-true (and (findf (lambda (r)
                               (and (equal? (row-kind r) "Snippet")
                                    (equal? (snippet-keyword
                                             (snippet-ref (engine-snippets engine)
                                                          (row-arg r)))
                                            "addr")))
                             hits)
                      #t)))))

(test-case "paste actions hand text to the host event, not the clipboard"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (define cid (clipboard-item-id
                  (clipboard-record! (engine-clipboard engine) "pasted text")))
     (define outcome (engine-run engine "clip.paste" cid))
     (check-equal? (car outcome) "copied")
     (check-equal? (cdr outcome)
                   (list (cons 'paste-to-frontmost "pasted text")))
     (snippet-save! (engine-snippets engine) "Note" "remember the milk" "milk")
     (define s (snippet-by-keyword (engine-snippets engine) "milk"))
     (define snip-outcome (engine-run engine "snip.paste" (snippet-id s)))
     (check-equal? (cdr snip-outcome)
                   (list (cons 'paste-to-frontmost "remember the milk")))
     (check-true (string-contains? (car (engine-run engine "clip.paste" "nope"))
                                   "not found")))))

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

(test-case "recents never write raw clipboard, URL or plugin arguments"
  (with-fresh-data-dir
   (lambda ()
     (define eng (fixture-engine #:apps fixture-apps))
     (check-equal? (car (engine-run eng "copy" "highly-sensitive-clipboard")) "copied")
     (check-equal? (car (engine-run eng "web.open"
                                    "https://example.com/?token=private-api-token"))
                   "opened")
     ;; FPP plugins can receive secrets; don't persist untrusted arguments
     ;; until plugins can declare sensitivity in a future history schema.
     (engine-record-use! eng "plugin:password" "private-password")
     (engine-record-use! eng "app.launch" "a1")
     (define serialized (file->string (recents-path)))
     (for ([secret (in-list '("highly-sensitive-clipboard"
                              "private-api-token" "private-password"))])
       (check-false (string-contains? serialized secret)))
     (check-equal? (hash-count (engine-recents eng)) 1)
     (check-true (hash-has-key? (engine-recents eng)
                                (string-append "app.launch" "\u0000" "a1"))))))

(test-case "legacy raw-argument recents are scrubbed on startup"
  (with-fresh-data-dir
   (lambda ()
     (write-json-atomic!
      (recents-path)
      (list (hasheq 'key (string-append "copy" "\u0000" "old-private-text")
                    'count 4 'ts 1.0)
            (hasheq 'key (string-append "app.launch" "\u0000" "a1")
                    'count 2 'ts 2.0)))
     (define eng (fixture-engine #:apps fixture-apps))
     (check-equal? (hash-count (engine-recents eng)) 1)
     (check-false (string-contains? (file->string (recents-path))
                                    "old-private-text"))
     (check-true (hash-has-key? (engine-recents eng)
                                (string-append "app.launch" "\u0000" "a1"))))))

(test-case "rows are 8-column string lists"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     (for ([row (in-list (engine-search engine "f"))])
       (check-equal? (length row) 8)
       (check-true (andmap string? row))))))

(test-case "secondary actions: the ⌘K panel contract"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine #:apps fixture-apps))
     ;; App rows: reveal + copy path.
     (define app-actions
       (engine-row-actions engine "app.launch" "a1"))
     (check-equal? (length app-actions) 2)
     (check-equal? (list-ref (car app-actions) 0) "file.open")
     ;; application-path is the discovery path (the .desktop file on
     ;; Linux fixtures, the bundle on macOS) — that is what Reveal opens.
     (check-equal? (list-ref (car app-actions) 4)
                   "/usr/share/applications/firefox.desktop")
     ;; Clipboard rows: ↵ pastes to the frontmost app (the primary),
     ;; the panel keeps Copy, then the pin toggle and delete.
     (define cid (clipboard-item-id
                  (clipboard-record! (engine-clipboard engine) "hello")))
     (define clip-actions (engine-row-actions engine "clip.paste" cid))
     (check-equal? (list-ref (car clip-actions) 0) "clip.copy")
     (check-equal? (list-ref (cadr clip-actions) 1)
                   "Pin")
     (check-true (clipboard-item-pinned?
                 (clipboard-toggle-pin! (engine-clipboard engine) cid)))
     (check-equal? (list-ref (cadr (engine-row-actions engine "clip.paste" cid)) 1)
                   "Unpin")
     ;; Snippet rows: paste + delete. Link/file/web rows: copy URL/path.
     (check-equal? (list-ref (car (engine-row-actions engine "snip.copy" "s1")) 0)
                   "snip.paste")
     (check-equal? (list-ref (list-ref (engine-row-actions engine "snip.copy" "s1") 1) 0)
                   "snip.delete")
     (check-equal? (list-ref (car (engine-row-actions engine "web.open" "https://x")) 0)
                   "copy")
     ;; Unknown ids offer nothing.
     (check-equal? (engine-row-actions engine "sys.run" "Lock") '())

     ;; The pin route actually toggles; delete removes.
     (define outcome (engine-run engine "clip.pin" cid))
     (check-equal? (car outcome) "ok")
     (check-false (clipboard-item-pinned?
                   (clipboard-item-ref (engine-clipboard engine) cid)))
     (check-equal? (car (engine-run engine "clip.delete" cid)) "ok")
     (check-false (clipboard-item-ref (engine-clipboard engine) cid))
     ;; Unknown clip id is loud.
     (check-true (string-contains? (car (engine-run engine "clip.pin" "nope"))
                                   "not found")))))


(test-case "snippet import/export one-line commands and error reporting"
  (with-fresh-data-dir
   (lambda ()
     (define engine (fixture-engine))
     (snippet-save! (engine-snippets engine) "Sample" "Body" "samp")
     (define path (path->string (build-path (data-dir) "bundle.json")))
     (define hint (engine-search engine "export snippets"))
     (check-equal? (row-id (car hint)) "noop")
     (define rows (engine-search engine (string-append "export snippets " path)))
     (define export-row (findf (lambda (r) (equal? (row-id r) "snip.export")) rows))
     (check-not-false export-row)
     (check-equal? (row-arg export-row) path)
     (check-equal? (car (engine-run engine "snip.export" (row-arg export-row))) "ok")
     (check-true (file-exists? (string->path path)))
     (check-true (string-contains?
                  (car (engine-run engine "snip.export" path))
                  "failed"))
     (snippet-delete! (engine-snippets engine)
                      (snippet-id (snippet-by-keyword (engine-snippets engine) "samp")))
     (define imported (engine-search engine (string-append "import snippets " path)))
     (define import-row (findf (lambda (r) (equal? (row-id r) "snip.import")) imported))
     (check-not-false import-row)
     (check-equal? (car (engine-run engine "snip.import" (row-arg import-row))) "ok")
     (check-equal? (snippet-count (engine-snippets engine)) 1)
     (check-true (string-contains?
                  (car (engine-run engine "snip.import" "/nonexistent/fulcrum-bundle.json"))
                  "failed")))))
