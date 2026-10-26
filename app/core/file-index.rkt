#lang racket/base

;; Fulcrum's persistent filename index.
;;
;; This first storage slice deliberately implements the queries SQLite's
;; ordinary B-tree can answer predictably at million-file scale: exact name,
;; exact stem, and filename prefix. Platform indexes remain the candidate
;; source for infix/content queries until Fulcrum ships a compact postings
;; format; the Racket backend remains the owner of merging and ranking.

(require db
         racket/file
         racket/list
         racket/path
         racket/string)

(provide file-index-count
         file-index-search
         file-index-upsert-hits!
         file-index-remove-paths!
         file-index-rename!)

(define schema-version 2)
(define max-candidates 256)

(define (fold text)
  (string-foldcase text))

(define (portable-file-name path)
  (define pieces (regexp-split #px"[/\\\\]+" path))
  (if (null? pieces) path (last pieces)))

(define (corrupt-database-error? exn)
  (regexp-match? #px"(?i:not a database|database disk image is malformed)"
                 (exn-message exn)))

(define (sidecar-path path suffix)
  (string->path (string-append (path->string path) suffix)))

(define (remove-index-files! path)
  ;; This database is explicitly a rebuildable cache. Limit recovery to the
  ;; exact index path and SQLite's two exact sidecar names.
  (for ([candidate (in-list (list path
                                  (sidecar-path path "-wal")
                                  (sidecar-path path "-shm")))])
    (with-handlers ([exn:fail:filesystem? (lambda (_) (void))])
      (when (file-exists? candidate) (delete-file candidate)))))

(define (initialize! connection)
  (query-exec connection "PRAGMA busy_timeout = 1000")
  (query-exec connection "PRAGMA journal_mode = WAL")
  (query-exec connection "PRAGMA synchronous = NORMAL")
  (define version (query-value connection "PRAGMA user_version"))
  (unless (= version schema-version)
    (call-with-transaction
     connection
     (lambda ()
       (query-exec connection "DROP TABLE IF EXISTS files")
       (query-exec
        connection
        (string-append
         "CREATE TABLE files ("
         "path TEXT PRIMARY KEY NOT NULL,"
         "name TEXT NOT NULL,"
         "folded_name TEXT NOT NULL"
         ") WITHOUT ROWID"))
       (query-exec connection
                   "CREATE INDEX files_name_prefix ON files(folded_name, path)")
       (query-exec connection (format "PRAGMA user_version = ~a" schema-version)))))
  ;; A current-version database can predate the index if creation was
  ;; interrupted. These statements are idempotent and cheap at open time.
  (query-exec connection
              "CREATE INDEX IF NOT EXISTS files_name_prefix ON files(folded_name, path)"))

(define (connect path)
  (define parent (path-only path))
  (when parent (make-directory* parent))
  (define connection (sqlite3-connect #:database path #:mode 'create))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (disconnect connection)
                     (raise exn))])
    (initialize! connection)
    connection))

(define (call-with-index path default proc [recovery? #t])
  (with-handlers
      ([exn:fail?
        (lambda (exn)
          (if (and recovery? (corrupt-database-error? exn))
              (begin
                (remove-index-files! path)
                (call-with-index path default proc #f))
              default))])
    (define connection (connect path))
    (dynamic-wind
      void
      (lambda () (proc connection))
      (lambda () (disconnect connection)))))

(define (valid-hit? hit)
  (and (pair? hit) (string? (car hit)) (string? (cdr hit))))

(define (file-index-upsert-hits! path hits)
  (call-with-index
   path #f
   (lambda (connection)
     (define upsert
       (prepare
        connection
        (string-append
         "INSERT INTO files(path,name,folded_name) VALUES(?,?,?) "
         "ON CONFLICT(path) DO UPDATE SET "
         "name=excluded.name, folded_name=excluded.folded_name")))
     (call-with-transaction
      connection
      (lambda ()
        (for ([hit (in-list hits)] #:when (valid-hit? hit))
          (define name (car hit))
          (define full-path (cdr hit))
          (query-exec connection upsert
                      full-path name (fold name)))))
     #t)))

(define (file-index-count path)
  (call-with-index path 0
                   (lambda (connection)
                     (query-value connection "SELECT count(*) FROM files"))))

(define (row->hit row)
  (cons (vector-ref row 0) (vector-ref row 1)))

(define (file-index-search path query [limit 8])
  (define q (fold (string-trim query)))
  (cond
    [(or (string=? q "") (<= limit 0)) '()]
    [else
     (call-with-index
      path '()
      (lambda (connection)
        ;; Appending the greatest Unicode scalar creates an exclusive upper
        ;; bound for every string beginning with q under SQLite BINARY order.
        (define upper (string-append q "\U0010FFFF"))
        ;; q." through q/ is the exact-stem-with-extension range. Query it
        ;; separately so report.md cannot be crowded out by thousands of
        ;; report-* names, while both statements still stop on the B-tree
        ;; instead of sorting an entire one-character prefix.
        (define stem-rows
          (query-rows
           connection
           "SELECT name,path FROM files WHERE folded_name >= ? AND folded_name < ? ORDER BY folded_name,path LIMIT ?"
           (string-append q ".") (string-append q "/")
           (min limit max-candidates)))
        (define prefix-rows
          (query-rows
           connection
           "SELECT name,path FROM files WHERE folded_name >= ? AND folded_name < ? ORDER BY folded_name,path LIMIT ?"
           q upper (min limit max-candidates)))
        (define hits
          (remove-duplicates
           (append (map row->hit stem-rows) (map row->hit prefix-rows))
           string=?
           #:key cdr))
        (take hits (min limit (length hits)))))]))

(define (file-index-remove-paths! path paths)
  (call-with-index
   path #f
   (lambda (connection)
     (call-with-transaction
      connection
      (lambda ()
        (for ([full-path (in-list paths)] #:when (string? full-path))
          (query-exec connection "DELETE FROM files WHERE path = ?" full-path))))
     #t)))

(define (file-index-rename! path old-path new-path)
  (call-with-index
   path #f
   (lambda (connection)
     (call-with-transaction
      connection
      (lambda ()
        (query-exec connection "DELETE FROM files WHERE path = ?" old-path)
        (define name (portable-file-name new-path))
        (query-exec
         connection
         (string-append
          "INSERT INTO files(path,name,folded_name) VALUES(?,?,?) "
          "ON CONFLICT(path) DO UPDATE SET "
          "name=excluded.name, folded_name=excluded.folded_name")
         new-path name (fold name))))
     #t)))
