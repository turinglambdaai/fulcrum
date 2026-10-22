#lang racket/base

;; Inline conversion tests (#52): natural-language dates, the bounded unit
;; table, and the currency cache path. No network — the rates fetcher is
;; stubbed for every query-shaped call, and calendar tests freeze "today"
;; through the `today` parameter.

(require racket/file
         racket/list
         racket/match
         racket/path
         rackunit
         "../app/core/convert.rkt"
         "../app/core/engine.rkt"
         "../app/core/paths.rkt"
         "../app/core/store.rkt")

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-convtest-~a" 'directory))
  (parameterize ([current-environment-variables
                  (let ([env (current-environment-variables)])
                    (environment-variables-set! env #"FULCRUM_DATA_DIR"
                                                (string->bytes/utf-8 (path->string dir)))
                    env)])
    (dynamic-wind
      void
      thunk
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files dir))))))

;; Every conversion query would schedule a background rates refresh; the
;; stub keeps tests off the network no matter what shape the query has.
(define (with-stub-fetcher thunk)
  (parameterize ([current-rates-fetcher (lambda () #f)]) (thunk)))

(define (titles query)
  (map car (convert-row-data query)))

(define (first-title query)
  (match (titles query)
    [(list t) t]
    [_ #f]))

(define (write-rates-cache! rates #:fetched-at [fetched-at (current-seconds)])
  (write-json-atomic! (rates-path) (hasheq 'fetchedAt fetched-at 'base "USD" 'rates rates)))

(define fixture-rates
  (hasheq 'USD 1.0 'EUR 0.92 'CNY 7.12 'GBP 0.79 'JPY 151.4))

;; ---- calendar core ---------------------------------------------------------

(test-case "civil-days round trips and weekday anchors"
  (for ([ymd (in-list '((1970 1 1) (1970 1 5) (2000 2 29) (2026 10 22)
                        (2100 3 1) (1900 3 1) (2024 2 29)))])
    (define n (civil->days (car ymd) (cadr ymd) (caddr ymd)))
    (check-equal? (days->civil n) ymd (format "round trip ~a" ymd)))
  ;; 1970-01-01 was a Thursday (index 4), 1970-01-05 the following Monday.
  (check-equal? (weekday-index (civil->days 1970 1 1)) 4)
  (check-equal? (weekday-index (civil->days 1970 1 5)) 1))

(test-case "month arithmetic clamps to month length"
  (check-equal? (add-months '(2026 1 31) 1) '(2026 2 28))
  (check-equal? (add-months '(2024 1 31) 1) '(2024 2 29))
  (check-equal? (add-months '(2026 10 31) 3) '(2027 1 31))
  (check-equal? (add-days '(2026 10 22) 10) '(2026 11 1)))

;; ---- date rows -------------------------------------------------------------

(test-case "next weekday"
  (with-stub-fetcher
   (lambda ()
     (parameterize ([today '(2026 10 22)]) ; a Thursday
       (check-equal? (first-title "next friday") "2026-10-23 (Friday)"))
     (parameterize ([today '(2026 10 23)]) ; already Friday: strictly future
       (check-equal? (first-title "next friday") "2026-10-30 (Friday)"))
     (parameterize ([today '(2026 10 22)])
       (check-equal? (first-title "next mon") "2026-10-26 (Monday)"))
     (check-false (first-title "next frank"))
     (check-false (first-title "next")))))

(test-case "in n units"
  (with-stub-fetcher
   (lambda ()
     (parameterize ([today '(2026 10 22)])
       (check-equal? (first-title "in 3 weeks") "2026-11-12 (Thursday)")
       (check-equal? (first-title "in 14 days") "2026-11-05 (Thursday)")
       (check-equal? (first-title "in 2 months") "2026-12-22 (Tuesday)")
       (check-equal? (first-title "in 1 year") "2027-10-22 (Friday)")
       (check-false (first-title "in 0 days"))
       (check-false (first-title "in 3 fortnights"))))))

(test-case "iso date arithmetic"
  (with-stub-fetcher
   (lambda ()
     (parameterize ([today '(2026 10 22)])
       (check-equal? (first-title "2026-10-20 + 14d") "2026-11-03 (Tuesday)")
       (check-equal? (first-title "2026-01-31 + 1m") "2026-02-28 (Saturday)")
       (check-equal? (first-title "2026-10-22 + 2w") "2026-11-05 (Thursday)")
       (check-equal? (first-title "2026-01-01 + 1y") "2027-01-01 (Friday)")
       (check-false (first-title "2026-13-01 + 2d"))
       (check-false (first-title "2026-10-20 - 14d"))))))

(test-case "days until and since"
  (with-stub-fetcher
   (lambda ()
     (parameterize ([today '(2026 10 22)])
       (check-equal? (first-title "days until 2027-01-01") "71 days")
       (check-equal? (first-title "days since 2026-10-01") "21 days")
       ;; Past targets answer with a signed count, not a lie.
       (check-equal? (first-title "days until 2026-01-01") "-294 days")
       (check-false (first-title "days until 2026-13-40"))))))

;; ---- units -----------------------------------------------------------------

(test-case "temperature"
  (with-stub-fetcher
   (lambda ()
     (check-equal? (first-title "32f to c") "0 °C")
     (check-equal? (first-title "100 c to f") "212 °F")
     (check-equal? (first-title "0c to k") "273.15 K")
     (check-equal? (first-title "37 celsius to fahrenheit") "98.6 °F")
     ;; Below absolute zero is declined, not computed.
     (check-false (first-title "-500c to k"))
     (check-false (first-title "-1 kelvin to c")))))

(test-case "length and weight"
  (with-stub-fetcher
   (lambda ()
     (check-equal? (first-title "5 km in mi") "3.106856 mi")
     (check-equal? (first-title "12 mm to cm") "1.2 cm")
     (check-equal? (first-title "26.2 mi to km") "42.164813 km")
     (check-equal? (first-title "10 kg to lb") "22.046226 lb")
     (check-equal? (first-title "1 st to kg") "6.350293 kg")
     (check-false (first-title "100 dogs to cats"))
     (check-false (first-title "5 km to lb")))))

;; ---- currency --------------------------------------------------------------

(test-case "currency renders from the cache"
  (with-fresh-data-dir
   (lambda ()
     (with-stub-fetcher
      (lambda ()
        (check-false (first-title "100 usd to eur")) ; no cache yet: no row
        (write-rates-cache! fixture-rates)
        (check-equal? (first-title "100 usd to eur") "92.00 EUR")
        (check-equal? (first-title "1 eur to usd") "1.09 USD")
        (check-equal? (first-title "100$ to €") "92.00 EUR")
        (check-equal? (first-title "50 usd to cny") "356.00 CNY")
        (check-equal? (first-title "1 usd to jpy") "151.40 JPY")
        (check-false (first-title "100 usd to xyz"))
        (check-false (first-title "100 usd to usd")))))))

(test-case "stale cache still renders"
  (with-fresh-data-dir
   (lambda ()
     (with-stub-fetcher
      (lambda ()
        (write-rates-cache! fixture-rates #:fetched-at (- (current-seconds) 200000))
        (check-equal? (first-title "100 usd to eur") "92.00 EUR"))))))

(test-case "refresh persists the injected fetcher's snapshot"
  (with-fresh-data-dir
   (lambda ()
     (parameterize ([current-rates-fetcher (lambda () fixture-rates)])
       (check-true (refresh-rates!))
       (define cache (rates-cache))
       (check-true (hash? cache))
       (check-equal? (hash-ref cache 'base) "USD")
       (check-equal? (hash-ref (hash-ref cache 'rates) 'EUR) 0.92))
     (parameterize ([current-rates-fetcher (lambda () #f)])
       (check-false (refresh-rates!))))))

;; ---- engine integration ----------------------------------------------------

(test-case "engine search surfaces conversion rows on the calculator surface"
  (with-fresh-data-dir
   (lambda ()
     (with-stub-fetcher
      (lambda ()
        (write-rates-cache! fixture-rates)
        (define engine
          (make-engine #:clipboard-store #f #:snippet-store #f #:plugin-manager #f))
        (define rows (engine-search engine "100 usd to eur"))
        (check-true (pair? rows))
        (check-equal? (list-ref (car rows) 3) "Calculator")
        (check-equal? (list-ref (car rows) 4) "92.00 EUR")
        (define unit-rows (engine-search engine "32f to c"))
        (check-equal? (list-ref (car unit-rows) 4) "0 °C")
        (parameterize ([today '(2026 10 22)])
          (define date-rows (engine-search engine "days until 2027-01-01"))
          (check-equal? (list-ref (car date-rows) 4) "71 days")))))))
