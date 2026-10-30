#lang racket/base

;; File search: the mdfind output parser (pure), and the engine provider's
;; two shapes — Spotlight rows on macOS, the honest unavailability row
;; elsewhere.

(require racket/file
         racket/path
         racket/async-channel
         racket/list
         racket/string
         rackunit
         "../app/core/engine.rkt"
         "../app/core/files.rkt"
         "../app/core/file-catalog.rkt")

(define (row-id row) (list-ref row 0))
(define (row-kind row) (list-ref row 3))

(test-case "mdfind output parsing filters junk and dedupes"
  (define parsed
    (parse-paths
     "/Users/me/Reports/q3.md\n/Users/me/Reports/q3.md\nnot a path\n/Users/me/Notes.md\n"))
  (check-equal? (length parsed) 2)
  (check-equal? (car (car parsed)) "q3.md")
  (check-equal? (cdr (car parsed)) "/Users/me/Reports/q3.md")
  ;; Non-string input (a timed-out probe) yields no rows.
  (check-equal? (parse-paths #f) '())
  ;; The limit holds.
  (check-equal? (length (parse-paths "/a/1\n/a/2\n/a/3\n/a/4\n" 3)) 3))

(test-case "Windows Search file: URLs decode to plain paths"
  (define parsed
    (parse-paths
     "file:///C:/Users/me/Reports/q3.md\nfile:///C:/Users/me/My%20Notes.md\n"))
  (check-equal? (length parsed) 2)
  (check-equal? (car (car parsed)) "q3.md")
  (check-equal? (cdr (car parsed)) "C:/Users/me/Reports/q3.md")
  (check-equal? (cdr (cadr parsed)) "C:/Users/me/My Notes.md"))

(test-case "Windows scan paths with backslashes are retained"
  ;; Get-ChildItem -ExpandProperty FullName emits native backslashes.  The old
  ;; slash-only filter silently discarded every fallback result. PowerShell's
  ;; CRLF delimiter must not become part of the path either.
  (define parsed
    (parse-paths
     "C:\\Users\\me\\Reports\\q3.md\r\nD:\\Notes\\My Notes.txt\r\n"))
  (check-equal? parsed
                '(("q3.md" . "C:\\Users\\me\\Reports\\q3.md")
                  ("My Notes.txt" . "D:\\Notes\\My Notes.txt"))))

(test-case "file hits share one deterministic relevance order"
  (define candidates
    '(("old-report.md" . "/home/me/archive/old-report.md")
      ("report-old.md" . "/home/me/report-old.md")
      ("report.md" . "/home/me/report.md")
      ("report.md" . "/home/me/project/node_modules/pkg/report.md")
      ("notes.md" . "/home/me/reports/report-notes.md")))
  (define ranked (rank-file-hits "report" candidates 5))
  ;; Exact stem wins; an equally named generated dependency is demoted. A
  ;; filename prefix beats a match found only in the parent path.
  (check-equal? (cdr (car ranked)) "/home/me/report.md")
  (check-true
   (< (index-of ranked '("report-old.md" . "/home/me/report-old.md"))
      (index-of ranked '("notes.md" . "/home/me/reports/report-notes.md"))))
  (check-true
   (< (index-of ranked '("report.md" . "/home/me/report.md"))
      (index-of ranked
                '("report.md" . "/home/me/project/node_modules/pkg/report.md"))))
  (check-equal? (rank-file-hits "report" candidates 2)
                (take ranked 2)))

(test-case "cross-platform reranking recognizes pinyin candidates"
  (define ranked
    (rank-file-hits
     "weixin"
     '(("unrelated.txt" . "C:\\Users\\me\\unrelated.txt")
       ("微信计划.md" . "C:\\Users\\me\\Documents\\微信计划.md"))
     2))
  (check-equal? (car (car ranked)) "微信计划.md"))

(test-case "windows find script prioritizes known folders and preserves index fallback"
  (define captured #f)
  (define captured-timeout-ms #f)
  (define result
    (file-search/status
     "o'brien" 8
     #:os 'windows
     #:resolve (lambda (program) (and (string=? program "powershell.exe") program))
     #:run (lambda (program args #:timeout-ms [timeout-ms 3000]
                               #:cancel-evt [_cancel-evt never-evt])
             (set! captured (cons program args))
             (set! captured-timeout-ms timeout-ms)
             "file:///C:/Users/me/obrien.txt\n")))
  ;; The explicit find command gets a Windows-specific 9s budget; ordinary
  ;; launcher typing never invokes this search.
  (check-equal? captured-timeout-ms 9000)
  ;; The call stays a single PowerShell invocation with known-folder first
  ;; and Windows Search / bounded profile fallback.
  (check-equal? (car captured) "powershell.exe")
  (check-equal? (cadr captured) "-NoProfile")
  (check-equal? (file-search-result-status result) 'ok)
  (check-equal? (file-search-result-hits result)
                '(("obrien.txt" . "C:/Users/me/obrien.txt")))
  (define script (cadddr captured))
  ;; A failed/hung Windows Search provider must not starve a real file in
  ;; Documents or in redirected OneDrive. Search common folders before OLE DB.
  (check-true (string-contains? script "GetFolderPath('MyDocuments')"))
  (check-true (string-contains? script "OneDriveConsumer"))
  (check-true (string-contains? script "OutputEncoding"))
  ;; The index probe is independent of a known-folder hit and time-bounded.
  (check-false (string-contains? script "if($out.Count -eq 0){try{"))
  (check-true (string-contains? script "if($out.Count -lt 128){"))
  (check-true (string-contains? script "Start-Job"))
  (check-true (string-contains? script "Wait-Job -Job $job -Timeout 2"))
  (check-true (string-contains? script "FULCRUM_FILE_SEARCH_ROOTS"))
  (check-true (string-contains? script "SYSTEMINDEX"))
  (check-true (string-contains? script "CONTAINS(System.FileName,"))
  (check-true (string-contains? script "FREETEXT(System.FileName,"))
  (check-true (string-contains? script "Get-ChildItem"))
  (check-true (string-contains? script "SELECT TOP 128"))
  (check-true (string-contains? script "Select-Object -First 128"))
  ;; The query is neutralized for both SQL and PowerShell single quotes.
  (check-false (string-contains? script "o'brien"))
  (check-true (string-contains? script "o''brien")))

(test-case "Windows combined known-folder and indexed-drive candidates preserve both volumes"
  (define result
    (file-search/status
     "project-report" 8
     #:os 'windows
     #:resolve (lambda (program) (and (string=? program "powershell.exe") program))
     #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]
                                    #:cancel-evt [_cancel-evt never-evt])
             "C:\\Users\\me\\Documents\\project-report.txt\r\nfile:///D:/Projects/project-report.txt\r\n")))
  (check-equal? (file-search-result-status result) 'ok)
  (check-equal? (length (file-search-result-hits result)) 2)
  (check-true (member "C:\\Users\\me\\Documents\\project-report.txt"
                      (map cdr (file-search-result-hits result))))
  (check-true (member "D:/Projects/project-report.txt"
                      (map cdr (file-search-result-hits result)))))

(test-case "Windows explicit find resolves a real fixture with the production PowerShell runner"
  (when (eq? (system-type 'os) 'windows)
    ;; Native backend smoke, not a string-mock: proves the Windows scanner
    ;; returns usable filesystem paths even when SYSTEMINDEX is disabled.
    (let ([profile (getenv "USERPROFILE")])
      (when profile
        (let* ([downloads (build-path profile "Downloads")]
               [already-exists? (directory-exists? downloads)]
               [fixture-name (format "fulcrum-find-smoke-~a.txt"
                                     (current-process-milliseconds))]
               [fixture (build-path downloads fixture-name)]
               [query (substring fixture-name 0
                                 (- (string-length fixture-name) 4))])
          (make-directory* downloads)
          (dynamic-wind
            (lambda ()
              (display-to-file "test" fixture #:exists 'truncate))
            (lambda ()
              (define result (file-search/status query 8 #:os 'windows))
              (check-equal? (file-search-result-status result) 'ok)
              (check-true
               (for/or ([hit (in-list (file-search-result-hits result))])
                 (string-ci=? (car hit) fixture-name))))
            (lambda ()
              (when (file-exists? fixture) (delete-file fixture))
              (when (not already-exists?)
                (with-handlers ([exn:fail? (lambda (_) (void))])
                  (delete-directory downloads))))))))))


(test-case "Windows native find discovers an opted-in workspace alongside Downloads"
  (when (eq? (system-type 'os) 'windows)
    (let ([profile (getenv "USERPROFILE")])
      (when profile
        ;; Actions Windows checkout is normally on D:, while Downloads is
        ;; on C:. This still checks opt-in behavior on a single-volume host.
        (let* ([token (format "fulcrum-dual-volume-~a"
                              (current-process-milliseconds))]
               [downloads (build-path profile "Downloads")]
               [had-downloads? (directory-exists? downloads)]
               [workspace (build-path (current-directory) token)]
               [known (build-path downloads (string-append token "-known.txt"))]
               [extra (build-path workspace (string-append token "-workspace.txt"))]
               [previous (getenv "FULCRUM_FILE_SEARCH_ROOTS")])
          (dynamic-wind
            (lambda ()
              (make-directory* downloads)
              (make-directory* workspace)
              (display-to-file "known" known #:exists 'truncate)
              (display-to-file "workspace" extra #:exists 'truncate)
              (putenv "FULCRUM_FILE_SEARCH_ROOTS" (path->string workspace)))
            (lambda ()
              (check-not-false
               (member (simple-form-path workspace)
                       (default-file-catalog-roots #:os 'windows)))
              (define result (file-search/status token 8 #:os 'windows))
              (check-equal? (file-search-result-status result) 'ok)
              (define paths (map cdr (file-search-result-hits result)))
              (check-true
               (for/or ([path (in-list paths)])
                 (string-ci=? path (path->string known))))
              (check-true
               (for/or ([path (in-list paths)])
                 (string-ci=? path (path->string extra)))))
            (lambda ()
              (putenv "FULCRUM_FILE_SEARCH_ROOTS" (or previous ""))
              (when (file-exists? known) (delete-file known))
              (when (directory-exists? workspace)
                (delete-directory/files workspace))
              (when (not had-downloads?)
                (with-handlers ([exn:fail? (lambda (_) (void))])
                  (delete-directory downloads))))))))))

(test-case "Linux find fallback reports timeout instead of an empty success"
  (define (find-only program)
    (and (string=? program "find") "/usr/bin/find"))
  (define timed-out
    (file-search/status
     "report" 8
     #:os 'unix
     #:resolve find-only
     #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]
                                   #:cancel-evt [_cancel-evt never-evt]) #f)))
  (check-equal? (file-search-result-status timed-out) 'timeout)
  (check-equal? (file-search-result-backend timed-out) 'find)
  (check-equal? (file-search-result-hits timed-out) '())
  (define completed
    (file-search/status
     "report" 8
     #:os 'unix
     #:resolve find-only
     #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]
                                   #:cancel-evt [_cancel-evt never-evt])
             "/home/me/report.txt\n")))
  (check-equal? (file-search-result-status completed) 'ok)
  (check-equal? (file-search-result-hits completed)
                '(("report.txt" . "/home/me/report.txt"))))

(test-case "a newer file query cancels the superseded backend"
  (define first-started (make-semaphore 0))
  (define calls 0)
  (define (runner _program _args #:timeout-ms [_timeout-ms 3000]
                                  #:cancel-evt [cancel-evt never-evt])
    (set! calls (add1 calls))
    (if (= calls 1)
        (begin
          (semaphore-post first-started)
          (sync cancel-evt)
          'cancelled)
        "/home/me/new-report.txt\n"))
  (define first-result (make-async-channel 1))
  (define first-worker
    (thread
     (lambda ()
       (async-channel-put
        first-result
        (file-search/status "old" 8
                            #:os 'unix
                            #:resolve (lambda (_) "/usr/bin/find")
                            #:run runner)))))
  (sync first-started)
  (define newest
    (file-search/status "report" 8
                        #:os 'unix
                        #:resolve (lambda (_) "/usr/bin/find")
                        #:run runner))
  (define superseded (sync/timeout 1 first-result))
  (check-equal? (file-search-result-status superseded) 'cancelled)
  (check-equal? (file-search-result-status newest) 'ok)
  (check-equal? (file-search-result-hits newest)
                '(("new-report.txt" . "/home/me/new-report.txt")))
  (check-not-false (sync/timeout 1 (thread-dead-evt first-worker))))

(test-case "platform results seed the persistent index and rescue a timeout"
  (define dir (make-temporary-file "fulcrum-search-index-~a" 'directory))
  (define index-path (build-path dir "index.sqlite3"))
  (dynamic-wind
    void
    (lambda ()
      (define seeded
        (file-search/status
         "report" 8
         #:os 'unix
         #:resolve (lambda (_) "/usr/bin/locate")
         #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]
                                       #:cancel-evt [_cancel-evt never-evt])
                 "/home/me/report.md\n")
         #:index-path index-path))
      (check-equal? (file-search-result-status seeded) 'ok)
      (define rescued
        (file-search/status
         "report" 8
         #:os 'unix
         #:resolve (lambda (_) "/usr/bin/locate")
         #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]
                                       #:cancel-evt [_cancel-evt never-evt]) #f)
         #:index-path index-path))
      (check-equal? (file-search-result-status rescued) 'ok)
      (check-equal? (file-search-result-backend rescued) 'fulcrum-index)
      (check-equal? (file-search-result-hits rescued)
                    '(("report.md" . "/home/me/report.md")))
      ;; The same cache is useful even when the host search utility disappears.
      (define offline
        (file-search/status "report" 8
                            #:os 'unix
                            #:resolve (lambda (_) #f)
                            #:index-path index-path))
      (check-equal? (file-search-result-status offline) 'ok)
      (check-equal? (file-search-result-hits offline)
                    '(("report.md" . "/home/me/report.md"))))
    (lambda () (delete-directory/files dir))))

(test-case "engine provider: honest row without Spotlight, real rows with it"
  (define engine (make-engine #:clipboard-store #f
                              #:snippet-store #f
                              #:plugin-manager #f))
  ;; The provider only claims "find …" queries: an unrelated query may
  ;; hit other providers (web fallback), but never a file row.
  (define unrelated (engine-search engine "unrelated"))
  (check-false (findf (lambda (r) (equal? (row-id r) "file.open")) unrelated))
  (define rows (engine-search engine "find anything"))
  (define file-rows
    (filter (lambda (r) (or (equal? (row-id r) "file.open")
                            (equal? (row-id r) "noop")))
            rows))
  (if (file-search-available?)
      ;; A search tool on PATH does not guarantee it finishes within 3s.
      ;; Especially on Windows, a cold unindexed PowerShell scan can time out
      ;; on a shared CI runner. In that case a visible timeout explanation is
      ;; the correct product behavior; never mistake it for missing tools.
      (check-true
       (or (andmap (lambda (r) (equal? (row-id r) "file.open")) file-rows)
           (and (= (length file-rows) 1)
                (equal? (row-id (car file-rows)) "noop")
                (string-contains? (list-ref (car file-rows) 1) "timed out"))))
      ;; Everywhere else: exactly one honest explanation, which runs to a
      ;; quiet refusal.
      (begin
        (check-equal? (length file-rows) 1)
        (check-equal? (row-id (car file-rows)) "noop")
        (check-true (string-contains?
                     (car (engine-run engine "noop" ""))
                     "not available")))))
