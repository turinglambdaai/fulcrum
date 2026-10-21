#lang racket/base

;; File search: the mdfind output parser (pure), and the engine provider's
;; two shapes — Spotlight rows on macOS, the honest unavailability row
;; elsewhere.

(require racket/file
         racket/string
         rackunit
         "../app/core/engine.rkt"
         "../app/core/files.rkt")

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

(test-case "windows backend runs the index-first script inside one command"
  (define captured #f)
  (define result
    (file-search/status
     "o'brien" 8
     #:os 'windows
     #:resolve (lambda (program) (and (string=? program "powershell.exe") program))
     #:run (lambda (program args #:timeout-ms [timeout-ms 3000])
             (set! captured (cons program args))
             "file:///C:/Users/me/obrien.txt\n")))
  ;; The call stays a single PowerShell invocation with the 3s budget.
  (check-equal? (car captured) "powershell.exe")
  (check-equal? (cadr captured) "-NoProfile")
  (check-equal? (file-search-result-status result) 'ok)
  (check-equal? (file-search-result-hits result)
                '(("obrien.txt" . "C:/Users/me/obrien.txt")))
  (define script (cadddr captured))
  ;; Index-first: SYSTEMINDEX query, then the honest scan fallback — both
  ;; inside the same invocation so any index failure still answers.
  (check-true (string-contains? script "SYSTEMINDEX"))
  (check-true (string-contains? script "CONTAINS(System.FileName,"))
  (check-true (string-contains? script "FREETEXT(System.FileName,"))
  (check-true (string-contains? script "Get-ChildItem"))
  ;; The query is neutralized for both SQL and PowerShell single quotes.
  (check-false (string-contains? script "o'brien"))
  (check-true (string-contains? script "o''brien")))

(test-case "Linux find fallback reports timeout instead of an empty success"
  (define (find-only program)
    (and (string=? program "find") "/usr/bin/find"))
  (define timed-out
    (file-search/status
     "report" 8
     #:os 'unix
     #:resolve find-only
     #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000]) #f)))
  (check-equal? (file-search-result-status timed-out) 'timeout)
  (check-equal? (file-search-result-backend timed-out) 'find)
  (check-equal? (file-search-result-hits timed-out) '())
  (define completed
    (file-search/status
     "report" 8
     #:os 'unix
     #:resolve find-only
     #:run (lambda (_program _args #:timeout-ms [_timeout-ms 3000])
             "/home/me/report.txt\n")))
  (check-equal? (file-search-result-status completed) 'ok)
  (check-equal? (file-search-result-hits completed)
                '(("report.txt" . "/home/me/report.txt"))))

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
