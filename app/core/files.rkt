#lang racket/base

;; File search — per-platform, always available on desktop:
;;   macOS: Spotlight (`mdfind -name`) — millisecond responses, deep index
;;   Linux: `locate -i` (the mlocate/plocate index) or `find` as fallback
;;   Windows: PowerShell `Get-ChildItem -Recurse` (bounded depth)
;; Claims `find <query>` queries so it never clutters unrelated searches.
;; Opening a result uses the platform opener, the same side-effect path
;; application launches use.

(require racket/bool
         racket/contract
         racket/list
         racket/path
         racket/string
         "proc.rkt")

(provide (struct-out file-search-result)
         file-search-available?
         parse-paths
         file-search/status
         file-search
         file-open!)

(struct file-search-result (hits status backend) #:transparent)

(define (file-search-backend os resolver)
  (case os
    [(macosx) (and (resolver "mdfind") 'mdfind)]
    [(unix) (cond [(resolver "locate") 'locate]
                  [(resolver "find") 'find]
                  [else #f])]
    [(windows) (and (resolver "powershell.exe") 'powershell)]
    [else #f]))

;; ---- availability ---------------------------------------------------------

(define (file-search-available?)
  (not (false? (file-search-backend (system-type 'os) resolve-program))))

;; ---- search ---------------------------------------------------------------

;; Universal path-list parser: newline-separated absolute paths →
;; (name path) pairs, bounded and deduplicated. Works for mdfind, locate,
;; find, and PowerShell output alike.
(define (parse-paths output [limit 8])
  (if (not (string? output))
      '()
      (take-min
       (remove-duplicates
        (for/list ([line (in-list
                          (filter (lambda (s)
                                    (string-contains? s "/"))
                                  (string-split output "\n")))])
          (cons (path->string (file-name-from-path (string->path line)))
                line)))
       limit)))

(define (take-min xs n)
  (if (> (length xs) n) (take xs n) xs))

;; Keep "no matches", "no tool", and "tool timed out" distinct. The old
;; list-only API collapsed all three to '(), which made stock Ubuntu's slow
;; `find` fallback look like a successful empty search.
(define (file-search/status query [limit 8]
                            #:os [os (system-type 'os)]
                            #:resolve [resolver resolve-program]
                            #:run [runner run-command])
  (define backend (file-search-backend os resolver))
  (if (false? backend)
      (file-search-result '() 'unavailable #f)
      (let-values ([(program args)
                    (case backend
                      [(mdfind) (values "mdfind" (list "-name" query))]
                      [(locate) (values "locate" (list "-i" "-l" "8" query))]
                      [(find)
                       (values "find"
                               (list (path->string (find-system-path 'home-dir))
                                     "-maxdepth" "4"
                                     "-iname" (string-append "*" query "*")
                                     "-type" "f"))]
                      [(powershell)
                       (values "powershell.exe"
                               (list "-NoProfile" "-Command"
                                     (format "Get-ChildItem -Path $env:USERPROFILE -Recurse -Depth 3 -Filter '*~a*' -File | Select-Object -First 8 -ExpandProperty FullName"
                                             query)))])])
        (define output (runner program args #:timeout-ms 3000))
        (if (false? output)
            (file-search-result '() 'timeout backend)
            (file-search-result (parse-paths output limit) 'ok backend)))))

;; Compatibility API for callers that only need hits.
(define (file-search query [limit 8])
  (file-search-result-hits (file-search/status query limit)))

(define (opener-for-platform)
  (case (system-type 'os)
    [(macosx) "open"]
    [(windows) "explorer.exe"]
    [else "xdg-open"]))

;; Fire-and-forget, like application launches. #f means the opener could
;; not run at all.
(define (file-open! path)
  (spawn-command (opener-for-platform) (list (path->string (simple-form-path path)))))
