#lang racket/base

;; File search — per-platform, always available on desktop:
;;   macOS: Spotlight (`mdfind -name`) — millisecond responses, deep index
;;   Linux: `locate -i` (the mlocate/plocate index) or `find` as fallback
;;   Windows: scan the user's actual known folders first (including redirected
;;     OneDrive locations), then query Windows Search (SYSTEMINDEX) for broader
;;     indexed results; a bounded profile walk is the last resort.
;; Claims `find <query>` queries so it never clutters unrelated searches.
;; Opening a result uses the platform opener, the same side-effect path
;; application launches use.

(require racket/bool
         racket/contract
         racket/list
         racket/path
         racket/string
         net/uri-codec
         "file-index.rkt"
         "fuzzy.rkt"
         "proc.rkt"
         "search-normalize.rkt")

(provide (struct-out file-search-result)
         file-search-available?
         parse-paths
         rank-file-hits
         file-search/status
         file-search
         file-open!)

(struct file-search-result (hits status backend) #:transparent)

;; Platform indices are good candidate generators, but their first eight rows
;; are not a relevance contract.  Pull a modest bounded set and apply the same
;; deterministic Fulcrum ranking on every host.
(define file-search-candidate-limit 128)

;; At most one platform query is useful. Native hosts generation-guard their
;; UI, but without backend cancellation every superseded keystroke still left
;; a PowerShell/mdfind/locate process running until timeout.
(define active-search-lock (make-semaphore 1))
(define active-search-cancel (box #f))

(define (claim-file-search!)
  (define cancel (make-semaphore 0))
  (call-with-semaphore
   active-search-lock
   (lambda ()
     (define previous (unbox active-search-cancel))
     (when previous (semaphore-post previous))
     (set-box! active-search-cancel cancel)))
  cancel)

(define (release-file-search! cancel)
  (call-with-semaphore
   active-search-lock
   (lambda ()
     ;; A late completion must never clear the newer query's cancellation
     ;; handle.
     (when (eq? cancel (unbox active-search-cancel))
       (set-box! active-search-cancel #f)))))

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

;; ---- cross-platform relevance --------------------------------------------

(define noisy-path-components
  '(".git" ".hg" ".svn" "node_modules" "build" "dist" "target"
    "cache" "caches" "__pycache__"))

(define (normalized-path-components path)
  (filter (lambda (part) (not (string=? part "")))
          (regexp-split #px"[/\\\\]+" (string-downcase path))))

(define (file-stem name)
  ;; Treat the final extension as metadata for ranking ("report" should put
  ;; report.md ahead of report-old.md). Dotfiles keep their complete name.
  (if (string-prefix? name ".")
      name
      (regexp-replace #px"\\.[^.]*$" name "")))

(define (file-hit-score query hit)
  (define q (string-downcase (string-trim query)))
  (define name (string-downcase (car hit)))
  (define path (string-downcase (cdr hit)))
  (define stem (file-stem name))
  (define fuzzy
    (or (fuzzy-score-fields
         q
         (search-fields-with-pinyin
          (list (cons 1.0 name)
                (cons 0.35 path))))
        0))
  (define intent-bonus
    (cond
      [(string=? q name) 2000]
      [(string=? q stem) 1900]
      [(string-prefix? name q) 1400]
      [(string-contains? name q) 900]
      [else 0]))
  (define components (normalized-path-components path))
  (define noise-penalty
    (if (for/or ([part (in-list components)])
          (member part noisy-path-components))
        250
        0))
  ;; Prefer a nearby human-facing path when relevance is otherwise equal.
  (+ fuzzy intent-bonus
     (- (min 80 (* 2 (length components))))
     (- noise-penalty)))

(define/contract (rank-file-hits query hits [limit 8])
  (->* (string? (listof (cons/c string? string?)))
       (exact-nonnegative-integer?)
       (listof (cons/c string? string?)))
  (define scored
    (for/list ([hit (in-list hits)])
      (vector (file-hit-score query hit) hit)))
  (define sorted
    (sort scored
          (lambda (a b)
            (define a-score (vector-ref a 0))
            (define b-score (vector-ref b 0))
            (if (= a-score b-score)
                (string-ci<? (cdr (vector-ref a 1))
                             (cdr (vector-ref b 1)))
                (> a-score b-score)))))
  (take-min (map (lambda (entry) (vector-ref entry 1)) sorted) limit))

;; Keep "no matches", "no tool", and "tool timed out" distinct. The old
;; list-only API collapsed all three to '(), which made stock Ubuntu's slow
;; `find` fallback look like a successful empty search.
(define (file-search/status query [limit 8]
                            #:os [os (system-type 'os)]
                            #:resolve [resolver resolve-program]
                            #:run [runner run-command/cancellable]
                            #:index-path [index-path #f])
  (define backend (file-search-backend os resolver))
  ;; Claim before touching the persistent index. Otherwise an older request
  ;; delayed in SQLite could claim after a newer request and cancel the wrong
  ;; process when RVT1 workers run concurrently.
  (define cancel (and backend (claim-file-search!)))
  (define cached
    (if index-path
        (file-index-search index-path query file-search-candidate-limit)
        '()))
  (if (false? backend)
      (if (null? cached)
          (file-search-result '() 'unavailable #f)
          (file-search-result (rank-file-hits query cached limit)
                              'ok 'fulcrum-index))
      (let-values ([(program args)
                    (case backend
                      [(mdfind) (values "mdfind" (list "-name" query))]
                      [(locate)
                       (values "locate"
                               (list "-i" "-l"
                                     (number->string file-search-candidate-limit)
                                     query))]
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
        (define output
          (dynamic-wind
            void
            (lambda ()
              (runner program args
                      #:timeout-ms (if (eq? os 'windows) 9000 3000)
                      #:cancel-evt (semaphore-peek-evt cancel)))
            (lambda () (release-file-search! cancel))))
        (cond
          [(eq? output 'cancelled)
           (file-search-result '() 'cancelled backend)]
          [(false? output)
           (if (null? cached)
               (file-search-result '() 'timeout backend)
               (file-search-result (rank-file-hits query cached limit)
                                   'ok 'fulcrum-index))]
          [else
           (define platform-hits
             (parse-paths output file-search-candidate-limit))
           (when (and index-path (pair? platform-hits))
             (file-index-upsert-hits! index-path platform-hits))
           (define candidates
             (remove-duplicates (append platform-hits cached)
                                string=?
                                #:key cdr))
           (file-search-result
            (rank-file-hits
             query
             candidates
             limit)
            'ok
            (if (and (null? platform-hits) (pair? cached))
                'fulcrum-index
                backend))]))))

;; Compatibility API for callers that only need hits.
(define (file-search query [limit 8])
  (file-search-result-hits (file-search/status query limit)))

;; ---- windows: index-first search script -----------------------------------

;; One PowerShell invocation, three tiers inside a bounded explicit-find
;; request (9 seconds on Windows, not on ordinary launcher typing):
;;   1. Windows known folders — Desktop, Documents and Downloads (including
;;      shell-redirected and OneDrive directories), before probing OLE DB.
;;      A broken Windows Search service must not prevent common-file results.
;;   2. Windows Search (SYSTEMINDEX) for other indexed scopes.
;;   3. A bounded user-profile walk only if the first two tiers found nothing.
;; The former index-first chain frequently spent its entire three-second
;; deadline in OLE DB or an enormous USERPROFILE recursion, yielding zero
;; results for files that were plainly present under Documents.
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
   "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);"
   "$out=@();"
   "$q='" (ps-literal raw-q) "';"
   "$qs='" (ps-literal sql-q) "';"
   "$roots=@([Environment]::GetFolderPath('DesktopDirectory'),"
   "[Environment]::GetFolderPath('MyDocuments'),"
   "(Join-Path $env:USERPROFILE 'Downloads'));"
   "foreach($cloud in @($env:OneDriveConsumer,$env:OneDrive)){"
   "if($cloud){$roots+=@((Join-Path $cloud 'Desktop'),"
   "(Join-Path $cloud 'Documents'))}};"
   "foreach($root in ($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -Unique)){"
   "try{$out+=@(Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -File "
   "-Filter ('*'+$q+'*') -ErrorAction SilentlyContinue|"
   "Select-Object -First 128 -ExpandProperty FullName)}catch{};"
   "if($out.Count -ge 128){break}"
   "};"
   "if($out.Count -eq 0){try{"
   "$c=New-Object System.Data.OleDb.OleDbConnection(\"Provider=Search.CollatorDSO;Extended Properties='Application=Windows'\");"
   "$c.Open();$cmd=$c.CreateCommand();"
   "$cmd.CommandText=\"SELECT TOP 128 System.ItemUrl FROM SYSTEMINDEX WHERE CONTAINS(System.FileName,'`\"$qs*`\"') AND SCOPE='file:'\";"
   "$r=$cmd.ExecuteReader();while($r.Read()){$out+=$r.GetString(0)};$r.Close();"
   "if($out.Count -eq 0){"
   "$cmd.CommandText=\"SELECT TOP 128 System.ItemUrl FROM SYSTEMINDEX WHERE FREETEXT(System.FileName,'`\"$qs`\"') AND SCOPE='file:'\";"
   "$r=$cmd.ExecuteReader();while($r.Read()){$out+=$r.GetString(0)};$r.Close()"
   "}"
   "$c.Close()"
   "}catch{}};"
   "if($out.Count -gt 0){"
   "$out|Select-Object -Unique -First 128|ForEach-Object{"
   "if($_ -like 'file:*'){[System.Uri]::UnescapeDataString($_ -replace '^file:/+','')}"
   "else{$_}}"
   "}else{"
   "Get-ChildItem -Path $env:USERPROFILE -Recurse -Depth 3 -Filter ('*'+$q+'*') -File -ErrorAction SilentlyContinue|Select-Object -First 128 -ExpandProperty FullName"
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
