#lang racket/base

;; File search — per-platform, always available on desktop:
;;   macOS: Spotlight (`mdfind -name`) — millisecond responses, deep index
;;   Linux: `locate -i` (the mlocate/plocate index) or `find` as fallback
;;   Windows: the Windows Search index (SYSTEMINDEX) when the service is
;;     up, falling back in-process to a bounded `Get-ChildItem -Recurse`
;;     scan when it is not
;; Claims `find <query>` queries so it never clutters unrelated searches.
;; Opening a result uses the platform opener, the same side-effect path
;; application launches use.

(require racket/bool
         racket/contract
         racket/list
         racket/path
         racket/string
         net/uri-codec
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

;; Windows Search returns file: URLs (file:///C:/Users/me/a%20b/x.md);
;; every other backend emits plain filesystem paths. Decode URL form
;; into a plain path; leave anything else untouched.
(define (file-url->path line)
  (if (string-prefix? line "file:")
      (uri-decode (regexp-replace #px"^file:/+" line ""))
      line))

;; Universal path-list parser: newline-separated absolute paths →
;; (name path) pairs, bounded and deduplicated. Works for mdfind, locate,
;; find, and PowerShell output alike.
(define (path-like? line)
  (or (string-contains? line "/")
      (string-contains? line "\\")))

(define (portable-file-name path)
  ;; Do not use the host OS path convention here: tests, remote output and
  ;; file: URLs can carry Windows and POSIX paths on either platform.
  (define pieces (regexp-split #px"[/\\\\]+" path))
  (if (null? pieces) path (last pieces)))

(define (clean-output-line line)
  ;; PowerShell writes CRLF.  Splitting only on newline otherwise leaves a
  ;; carriage return in the path, producing a result that cannot be opened.
  ;; Remove exactly the transport delimiter, not legitimate path whitespace.
  (regexp-replace #px"\r$" line ""))

(define (parse-paths output [limit 8])
  (if (not (string? output))
      '()
      (take-min
       (remove-duplicates
        (for/list ([line (in-list
                          (filter (lambda (s)
                                    (and (not (string=? s ""))
                                         (path-like? s)))
                                  (map clean-output-line
                                       (string-split output "\n"))))])
          (define path (file-url->path line))
          (cons (portable-file-name path) path)))
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
                                     (windows-find-script query)))])])
        (define output (runner program args #:timeout-ms 3000))
        (if (false? output)
            (file-search-result '() 'timeout backend)
            (file-search-result (parse-paths output limit) 'ok backend)))))

;; Compatibility API for callers that only need hits.
(define (file-search query [limit 8])
  (file-search-result-hits (file-search/status query limit)))

;; ---- windows: index-first search script -----------------------------------

;; One PowerShell invocation, two tiers inside the same 3-second budget:
;;   1. the Windows Search index (SYSTEMINDEX) — filename prefix match,
;;      then FREETEXT for the mid-word case; millisecond-fast when the
;;      service is healthy
;;   2. a bounded Get-ChildItem scan of the user profile — the honest
;;      fallback when the index is off, empty or errors
;; The script is defensive on purpose: any index failure lands in the
;; catch and the scan still answers. Two query spellings travel in the
;; script: $q is the raw text (the scan's -Filter wants it literal) and
;; $qs is SQL-escaped for the index queries. Both are embedded as
;; PowerShell single-quoted literals, where a literal ' is written '' —
;; so a filename like o'brien arrives intact at every layer without
;; breaking out of anything.
(define (windows-find-script query)
  (define (ps-literal s) (string-replace s "'" "''"))
  (define raw-q (regexp-replace* #px"[\u000d\u000a\u0000]" query " "))
  (define sql-q (string-replace raw-q "'" "''"))
  (string-append
   "$ErrorActionPreference='SilentlyContinue';"
   "$out=@();"
   "$q='" (ps-literal raw-q) "';"
   "$qs='" (ps-literal sql-q) "';"
   "try{"
   "$c=New-Object System.Data.OleDb.OleDbConnection(\"Provider=Search.CollatorDSO;Extended Properties='Application=Windows'\");"
   "$c.Open();$cmd=$c.CreateCommand();"
   "$cmd.CommandText=\"SELECT TOP 8 System.ItemUrl FROM SYSTEMINDEX WHERE CONTAINS(System.FileName,'`\"$qs*`\"') AND SCOPE='file:'\";"
   "$r=$cmd.ExecuteReader();while($r.Read()){$out+=$r.GetString(0)};$r.Close();"
   "if($out.Count -eq 0){"
   "$cmd.CommandText=\"SELECT TOP 8 System.ItemUrl FROM SYSTEMINDEX WHERE FREETEXT(System.FileName,'`\"$qs`\"') AND SCOPE='file:'\";"
   "$r=$cmd.ExecuteReader();while($r.Read()){$out+=$r.GetString(0)};$r.Close()"
   "}"
   "$c.Close()"
   "}catch{};"
   "if($out.Count -gt 0){"
   "$out|Select-Object -First 8|ForEach-Object{[System.Uri]::UnescapeDataString($_ -replace '^file:/+','')}"
   "}else{"
   "Get-ChildItem -Path $env:USERPROFILE -Recurse -Depth 3 -Filter ('*'+$q+'*') -File -ErrorAction SilentlyContinue|Select-Object -First 8 -ExpandProperty FullName"
   "}"))

(define (opener-for-platform)
  (case (system-type 'os)
    [(macosx) "open"]
    [(windows) "explorer.exe"]
    [else "xdg-open"]))

;; Fire-and-forget, like application launches. #f means the opener could
;; not run at all.
(define (file-open! path)
  (spawn-command (opener-for-platform) (list (path->string (simple-form-path path)))))
