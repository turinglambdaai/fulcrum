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
    (parse-mdfind-output
     "/Users/me/Reports/q3.md\n/Users/me/Reports/q3.md\nnot a path\n/Users/me/Notes.md\n"))
  (check-equal? (length parsed) 2)
  (check-equal? (car (car parsed)) "q3.md")
  (check-equal? (cdr (car parsed)) "/Users/me/Reports/q3.md")
  ;; Non-string input (a timed-out probe) yields no rows.
  (check-equal? (parse-mdfind-output #f) '())
  ;; The limit holds.
  (check-equal? (length (parse-mdfind-output "/a/1\n/a/2\n/a/3\n/a/4\n" 3)) 3))

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
      ;; macOS with Spotlight: rows are file.open, kind File (Spotlight is
      ;; indexed on dev machines and macOS CI; if the index were empty the
      ;; file-rows list is simply empty and nothing fails).
      (check-true (andmap (lambda (r) (equal? (row-id r) "file.open")) file-rows))
      ;; Everywhere else: exactly one honest explanation, which runs to a
      ;; quiet refusal.
      (begin
        (check-equal? (length file-rows) 1)
        (check-equal? (row-id (car file-rows)) "noop")
        (check-true (string-contains?
                     (car (engine-run engine "noop" ""))
                     "not available")))))
