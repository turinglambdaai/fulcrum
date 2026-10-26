#lang racket/base

;; Reproducible million-path storage/query benchmark for the Fulcrum filename
;; index. It writes only beneath the OS temporary directory and removes the
;; generated database when finished.

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         "../app/core/file-index.rkt")

(define entry-count 1000000)
(define query-count 500)
(command-line
 #:program "benchmark-file-index.rkt"
 #:once-each
 [("--entries") count "Number of synthetic file paths"
  (set! entry-count (string->number count))]
 [("--queries") count "Number of warm prefix queries"
  (set! query-count (string->number count))])

(unless (and (exact-positive-integer? entry-count)
             (exact-positive-integer? query-count))
  (raise-user-error 'benchmark-file-index "counts must be positive integers"))

(define batch-size 5000)
(define work-dir (make-temporary-file "fulcrum-file-index-benchmark-~a" 'directory))
(define db-path (build-path work-dir "million.sqlite3"))

(define (synthetic-hit i)
  (define name (format "document-~a.txt" (~r i #:min-width 7 #:pad-string "0")))
  (cons name (format "/volume/team-~a/project-~a/~a"
                     (modulo i 32) (modulo i 1000) name)))

(define (percentile sorted fraction)
  (list-ref sorted
            (min (sub1 (length sorted))
                 (inexact->exact (floor (* fraction (length sorted)))))))

(dynamic-wind
  void
  (lambda ()
    (collect-garbage)
    (define ingest-start (current-inexact-milliseconds))
    (for ([start (in-range 0 entry-count batch-size)])
      (define stop (min entry-count (+ start batch-size)))
      (unless
          (file-index-upsert-hits!
           db-path
           (for/list ([i (in-range start stop)]) (synthetic-hit i)))
        (raise-user-error 'benchmark-file-index "index write failed")))
    (define ingest-ms (- (current-inexact-milliseconds) ingest-start))
    (unless (= (file-index-count db-path) entry-count)
      (raise-user-error 'benchmark-file-index "indexed row count mismatch"))

    ;; Prime connection/page caches. The workload deliberately includes wide
    ;; one- and two-character prefixes: launcher search must stay responsive
    ;; from the first keystroke, not only once a query becomes selective.
    (file-index-search db-path "document-050" 12)
    (define samples
      (for/list ([n (in-range query-count)])
        (define prefix
          (case (modulo n 10)
            [(0) "d"]
            [(1) "do"]
            [(2) "document"]
            [else
             (format "document-~a"
                     (~r (modulo (* n 7919) entry-count)
                         #:min-width 3 #:pad-string "0"))]))
        (define started (current-inexact-milliseconds))
        (file-index-search db-path prefix 12)
        (- (current-inexact-milliseconds) started)))
    (define sorted (sort samples <))
    (define p50 (percentile sorted 0.50))
    (define p95 (percentile sorted 0.95))
    (define size-mib (/ (file-size db-path) 1024.0 1024.0))
    (printf "entries=~a ingest_ms=~a db_mib=~a query_p50_ms=~a query_p95_ms=~a query_max_ms=~a target_p95_lt_50=~a\n"
            entry-count
            (~r ingest-ms #:precision '(= 1))
            (~r size-mib #:precision '(= 1))
            (~r p50 #:precision '(= 3))
            (~r p95 #:precision '(= 3))
            (~r (last sorted) #:precision '(= 3))
            (< p95 50.0)))
  (lambda () (delete-directory/files work-dir)))
