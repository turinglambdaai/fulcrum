#lang racket/base

;; File search — the honest v1: Spotlight on macOS (`mdfind -name`),
;; an explanatory row everywhere else. Claims `find <query>` queries so
;; it never clutters unrelated searches. Opening a result uses the
;; platform opener, the same side-effect path application launches use.

(require racket/bool
         racket/contract
         racket/list
         racket/path
         racket/string
         "proc.rkt")

(provide file-search-available?
         parse-mdfind-output
         file-search
         file-open!)

(define (file-search-available?)
  (and (equal? (system-type 'os) 'macosx)
       (not (false? (resolve-program "mdfind")))))

;; Pure: mdfind's newline-separated absolute paths → (name path) pairs,
;; bounded and deduplicated.
(define (parse-mdfind-output output [limit 8])
  (if (not (string? output))
      '()
      (for/list ([line (in-list (take-min
                                 (remove-duplicates
                                  (filter (lambda (s)
                                            ;; mdfind emits POSIX absolute paths;
                                            ;; complete-path? would be
                                            ;; platform-relative (Windows wants
                                            ;; a drive letter).
                                            (string-prefix? s "/"))
                                          (string-split output "\n")))
                                 limit))])
        (cons (path->string (file-name-from-path (string->path line)))
              line))))

(define (take-min xs n)
  (if (> (length xs) n) (take xs n) xs))

;; (name path) pairs, or '() when unavailable. Bounded by the mdfind
;; timeout (Spotlight answers in milliseconds; a wedged index costs 1.5 s).
(define/contract (file-search query [limit 8])
  (->* (string?) ((and/c exact-integer? (>/c 0))) (listof (cons/c string? string?)))
  ;; Spotlight answers in milliseconds; a wedged index costs 1.5 s.
  (if (not (file-search-available?))
      '()
      (let ([output (run-command "mdfind" (list "-name" query) #:timeout-ms 1500)])
        (parse-mdfind-output output limit))))

(define (opener-for-platform)
  (case (system-type 'os)
    [(macosx) "open"]
    [(windows) "explorer.exe"]
    [else "xdg-open"]))

;; Fire-and-forget, like application launches. #f means the opener could
;; not run at all.
(define/contract (file-open! path)
  (-> path-string? boolean?)
  (spawn-command (opener-for-platform) (list (path->string (simple-form-path path)))))
