#lang racket/base

;; Reproducible mixed Latin/Chinese filename benchmark for issue #95. It
;; writes only beneath the OS temporary directory and removes the database.

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         "../app/core/file-index.rkt")

(define entry-count 100000)
(define query-count 300)
(command-line
 #:program "benchmark-pinyin-index.rkt"
 #:once-each
 [("--entries") count "Number of synthetic file paths"
  (set! entry-count (string->number count))]
 [("--queries") count "Number of warm queries"
  (set! query-count (string->number count))])

(unless (and (exact-positive-integer? entry-count)
             (exact-positive-integer? query-count))
  (raise-user-error 'benchmark-pinyin-index "counts must be positive integers"))

(define batch-size 5000)
(define work-dir (make-temporary-file "fulcrum-pinyin-benchmark-~a" 'directory))
(define db-path (build-path work-dir "pinyin.sqlite3"))

(define chinese-stems
  '#("微信计划" "钉钉会议" "臺灣行程" "重庆项目" "女装清单"))

(define (synthetic-hit i)
  ;; Twenty percent exercises Han transliteration; the rest protects the
  ;; ordinary Latin ingestion/query path from a hidden global cost.
  (define stem
    (if (zero? (modulo i 5))
        (vector-ref chinese-stems (modulo (quotient i 5)
                                         (vector-length chinese-stems)))
        "document"))
  (define name (format "~a-~a.txt" stem (~r i #:min-width 6 #:pad-string "0")))
  (cons name (format "/volume/team-~a/project-~a/~a"
                     (modulo i 32) (modulo i 1000) name)))

(define query-cycle
  '#("weixin" "wxjh" "dingding" "ddhy" "taiwan" "twxc"
     "chongqing" "cqx" "nvzhuang" "nzqd" "document"))

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
      (unless (file-index-upsert-hits!
               db-path
               (for/list ([i (in-range start stop)]) (synthetic-hit i)))
        (raise-user-error 'benchmark-pinyin-index "index write failed")))
    (define ingest-ms (- (current-inexact-milliseconds) ingest-start))
    (unless (= (file-index-count db-path) entry-count)
      (raise-user-error 'benchmark-pinyin-index "indexed row count mismatch"))
    (file-index-search db-path "weixin" 12)
    (define samples
      (for/list ([n (in-range query-count)])
        (define query
          (vector-ref query-cycle (modulo n (vector-length query-cycle))))
        (define started (current-inexact-milliseconds))
        (define hits (file-index-search db-path query 12))
        (unless (pair? hits)
          (raise-user-error 'benchmark-pinyin-index
                            "expected at least one result for ~a" query))
        (- (current-inexact-milliseconds) started)))
    (define sorted (sort samples <))
    (define p50 (percentile sorted 0.50))
    (define p95 (percentile sorted 0.95))
    (printf
     "entries=~a han_ratio=0.20 ingest_ms=~a db_mib=~a query_p50_ms=~a query_p95_ms=~a query_max_ms=~a target_p95_lt_50=~a\n"
     entry-count
     (~r ingest-ms #:precision '(= 1))
     (~r (/ (file-size db-path) 1024.0 1024.0) #:precision '(= 1))
     (~r p50 #:precision '(= 3))
     (~r p95 #:precision '(= 3))
     (~r (last sorted) #:precision '(= 3))
     (< p95 50.0)))
  (lambda () (delete-directory/files work-dir)))
