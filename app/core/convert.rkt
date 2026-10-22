#lang racket/base

;; Inline conversions for the calculator surface (#52).
;;
;; Three closed, bounded families answer without any plugin keyword:
;;   * natural-language dates — "next friday", "in 3 weeks",
;;     "2026-10-20 + 14d", "days until 2027-01-01"
;;   * units — "32f to c", "5 km in mi", "10 kg to lb" over a fixed
;;     temperature/length/weight table
;;   * currency — "100 usd to eur" from a cached daily rates table
;;
;; Rows come back as plain (title . subtitle) pairs; engine.rkt owns the
;; result struct and wraps them as Calculator rows running the calc.copy
;; action, so hosts render and copy them exactly like arithmetic with zero
;; host awareness of this module. The long tail stays with the `u` and
;; `cur` gallery plugins; these rows only cover the frequent head.
;;
;; Currency never blocks search: rows render synchronously from the cache
;; file (fresh or stale), and a stale cache schedules at most one quiet
;; background refresh per hour. The fetcher is a parameter so tests inject
;; a stub and never touch the network. All calendar math is proleptic
;; Gregorian integer arithmetic (Hinnant's civil-days algorithm) — no
;; floating point, no locale, exact across the whole representable range.

(require json
         net/http-client
         racket/async-channel
         racket/date
         racket/format
         racket/list
         racket/match
         racket/port
         racket/string
         "paths.rkt"
         "store.rkt")

(provide convert-row-data
         refresh-rates!
         rates-cache
         today
         current-rates-fetcher
         civil->days
         days->civil
         weekday-index
         add-days
         add-months
         date-rows
         unit-rows
         currency-rows)

;; ---- calendar core --------------------------------------------------------

(define (leap-year? year)
  (and (zero? (modulo year 4))
       (or (not (zero? (modulo year 100)))
           (zero? (modulo year 400)))))

(define month-lengths #(31 28 31 30 31 30 31 31 30 31 30 31))

(define (days-in-month year month)
  (if (and (= month 2) (leap-year? year))
      29
      (vector-ref month-lengths (sub1 month))))

;; Days since 1970-01-01, proleptic Gregorian. Integer-only, so date
;; arithmetic is exact and timezone-free.
(define (civil->days year month day)
  (define y (if (<= month 2) (sub1 year) year))
  (define era (floor (/ y 400)))
  (define yoe (- y (* era 400)))
  (define m-prime (if (<= month 2) (+ month 9) (- month 3)))
  (define doy (+ (quotient (+ 2 (* 153 m-prime)) 5) day -1))
  (define doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy))
  (+ (* era 146097) doe -719468))

(define (days->civil n)
  (define z (+ n 719468))
  (define era (floor (/ z 146097)))
  (define doe (- z (* era 146097)))
  (define yoe
    (quotient (- doe (quotient doe 1460) (- (quotient doe 36524))
                 (quotient doe 146096))
              365))
  (define year (+ yoe (* era 400)))
  (define doy
    (- doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)))))
  (define mp (quotient (+ (* doy 5) 2) 153))
  (define day (add1 (- doy (quotient (+ 2 (* 153 mp)) 5))))
  (define month (+ mp (if (< mp 10) 3 -9)))
  (list (if (<= month 2) (add1 year) year) month day))

;; 1970-01-01 was a Thursday; index 0 is Sunday.
(define (weekday-index days)
  (modulo (+ days 4) 7))

(define weekday-names
  '#("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))

(define weekday-aliases
  (make-hash
   '(("sunday" . 0) ("monday" . 1) ("tuesday" . 2) ("wednesday" . 3)
     ("thursday" . 4) ("friday" . 5) ("saturday" . 6)
     ("sun" . 0) ("mon" . 1) ("tue" . 2) ("tues" . 2) ("wed" . 3)
     ("weds" . 3) ("thu" . 4) ("thur" . 4) ("thurs" . 4)
     ("fri" . 5) ("sat" . 6))))

;; Tests parameterize this to freeze "today"; production reads the host clock.
(define today (make-parameter #f))

(define (today-ymd)
  (or (today)
      (let ([d (current-date)])
        (list (date-year d) (date-month d) (date-day d)))))

(define (parse-iso-date text)
  (define m (regexp-match #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})$" text))
  (and m
       (let* ([year (string->number (cadr m))]
              [month (string->number (caddr m))]
              [day (string->number (cadddr m))])
         (and (<= 1 month 12)
              (<= 1 day (days-in-month year month))
              (list year month day)))))

(define (iso-text ymd)
  (format "~a-~a-~a"
          (list-ref ymd 0)
          (~a (list-ref ymd 1) #:width 2 #:align 'right #:pad-string "0")
          (~a (list-ref ymd 2) #:width 2 #:align 'right #:pad-string "0")))

(define (ymd-weekday-name ymd)
  (vector-ref weekday-names
              (weekday-index (civil->days (car ymd) (cadr ymd) (caddr ymd)))))

(define (add-days ymd n)
  (days->civil (+ (civil->days (car ymd) (cadr ymd) (caddr ymd)) n)))

;; Calendar month/year arithmetic with day clamping (Jan 31 + 1 month is
;; Feb 28/29, not a rolled-over March date).
(define (add-months ymd n)
  (define total (+ (- (* (car ymd) 12) 1) (cadr ymd) n))
  (define year (quotient total 12))
  (define month (+ 1 (modulo total 12)))
  (list year month (min (caddr ymd) (days-in-month year month))))

(define (delta-days from to)
  (- (civil->days (car to) (cadr to) (caddr to))
     (civil->days (car from) (cadr from) (caddr from))))

;; ---- date rows -------------------------------------------------------------

(define (days-noun n)
  (if (= (abs n) 1) "day" "days"))

(define (date-rows query)
  (define q (string-downcase (string-trim query)))
  (define t (today-ymd))
  (define row
    (or
     ;; next friday / next tue — strictly future, today + 1..7
     (match (regexp-match #px"^next[ ]+([a-z]+)$" q)
       [(list _ name)
        (define index (hash-ref weekday-aliases name #f))
        (and index
             (let* ([offset
                     ;; Strictly future: 1..7 days out, never today.
                     (add1 (modulo (- index
                                      (weekday-index
                                       (civil->days (car t) (cadr t) (caddr t)))
                                      1)
                                   7))]
                    [target (add-days t offset)])
               (cons (format "~a (~a)" (iso-text target) (ymd-weekday-name target))
                     (format "next ~a · ~a from today"
                             name (days-noun offset)))))]
       [_ #f])
     ;; in 3 weeks / in 14 days / in 2 months / in 1 year
     (match (regexp-match #px"^in[ ]+([0-9]{1,4})[ ]+(days?|weeks?|months?|years?)$" q)
       [(list _ n-text unit)
        (define n (string->number n-text))
        (and n (positive? n)
             (let* ([target
                     (cond
                       [(string-prefix? unit "day") (add-days t n)]
                       [(string-prefix? unit "week") (add-days t (* 7 n))]
                       [(string-prefix? unit "month") (add-months t n)]
                       [else (add-months t (* 12 n))])]
                    [span (delta-days t target)])
               (cons (format "~a (~a)" (iso-text target) (ymd-weekday-name target))
                     (format "in ~a ~a · ~a from today"
                             n unit (days-noun span)))))]
       [_ #f])
     ;; 2026-10-20 + 14d / + 2w / + 3m / + 1y
     (match (regexp-match
             #px"^([0-9]{4}-[0-9]{2}-[0-9]{2})[ ]*\\+[ ]*([0-9]{1,4})[ ]*([dwmy])$" q)
       [(list _ iso n-text unit)
        (define base (parse-iso-date iso))
        (define n (string->number n-text))
        (and base n (positive? n)
             (let* ([target
                     (cond
                       [(string=? unit "d") (add-days base n)]
                       [(string=? unit "w") (add-days base (* 7 n))]
                       [(string=? unit "m") (add-months base n)]
                       [else (add-months base (* 12 n))])]
                    [span (delta-days base target)])
               (cons (format "~a (~a)" (iso-text target) (ymd-weekday-name target))
                     (format "~a + ~a~a · ~a" iso n unit (days-noun span)))))]
       [_ #f])
     ;; days until 2027-01-01 / days since 2026-01-01 — signed count
     (match (regexp-match #px"^days[ ]+(until|since)[ ]+([0-9]{4}-[0-9]{2}-[0-9]{2})$" q)
       [(list _ direction iso)
        (define target (parse-iso-date iso))
        (and target
             (let ([span ((if (string=? direction "since") - values)
                          (delta-days t target))])
               (cons (format "~a ~a" span (days-noun span))
                     (format "days ~a ~a" direction iso))))]
       [_ #f])))
  (if row (list row) '()))

;; ---- units -----------------------------------------------------------------

;; Exact rational factors, so "5 km in mi" never accumulates floating-point
;; noise on the way through SI.
;; Equal-based hashes throughout: these tables are keyed by strings from
;; the query, and `hasheq` would eq-compare fresh string objects to nothing.
(define length-table
  (hash "mm" 1/1000 "cm" 1/100 "m" 1 "km" 1000
        "in" 127/5000 "ft" 381/1250 "yd" 1143/1250 "mi" 201168/125))

(define weight-table
  (hash "mg" 1/1000000 "g" 1/1000 "kg" 1 "t" 1000
        "oz" 45359237/1600000000 "lb" 45359237/100000000
        "st" 317514659/50000000))

(define temperature-symbols
  (hash "c" "c" "celsius" "c" "centigrade" "c"
        "f" "f" "fahrenheit" "f"
        "k" "k" "kelvin" "k"))

(define (temperature-symbol unit)
  (match unit ["c" "°C"] ["f" "°F"] ["k" "K"] [_ unit]))

(define (to-celsius value from)
  (match from ["c" value] ["f" (/ (* (- value 32) 5) 9)] [_ (- value 273.15)]))

(define (from-celsius celsius to)
  (match to ["c" celsius] ["f" (+ (/ (* celsius 9) 5) 32)] [_ (+ celsius 273.15)]))

(define (format-value v)
  (define text (real->decimal-string (exact->inexact v) 6))
  (define trimmed (regexp-replace* #rx"0+$" text ""))
  (regexp-replace* #rx"\\.$" trimmed ""))

(define (format-currency v)
  (if (>= (abs v) 1)
      (~r (exact->inexact v) #:precision '(= 2))
      (~r (exact->inexact v) #:precision '(= 4))))

(define (unit-rows query)
  (define q (string-downcase (string-trim query)))
  (define m (regexp-match
             #px"^(-?[0-9]+(?:\\.[0-9]+)?)\\s*°?\\s*([a-z]+)\\s*(?:to|in|->|→)\\s*°?\\s*([a-z]+)$"
             q))
  (define row
    (and m
         (let ([value (string->number (cadr m))]
               [from (caddr m)]
               [to (cadddr m)])
           (and value
                (cond
                  [(and (hash-ref temperature-symbols from #f)
                        (hash-ref temperature-symbols to #f))
                   ;; A temperature below absolute zero is a nonsense input;
                   ;; the honest answer is no row, not a junk conversion.
                   (define from-s (hash-ref temperature-symbols from))
                   (define to-s (hash-ref temperature-symbols to))
                   (and (>= (to-celsius value from-s) -273.15)
                        (let* ([result (from-celsius (to-celsius value from-s) to-s)])
                          (cons (format "~a ~a" (format-value result) (temperature-symbol to-s))
                                (format "~a ~a = ~a ~a" (format-value value)
                                        (temperature-symbol from-s)
                                        (format-value result)
                                        (temperature-symbol to-s)))))]
                  [(and (hash-ref length-table from #f) (hash-ref length-table to #f))
                   ;; Factors are "SI per unit": SI = v × from, result = SI ÷ to.
                   (define result
                     (* value (/ (hash-ref length-table from)
                                 (hash-ref length-table to))))
                   (cons (format "~a ~a" (format-value result) to)
                         (format "~a ~a = ~a ~a" (format-value value) from
                                 (format-value result) to))]
                  [(and (hash-ref weight-table from #f) (hash-ref weight-table to #f))
                   (define result
                     (* value (/ (hash-ref weight-table from)
                                 (hash-ref weight-table to))))
                   (cons (format "~a ~a" (format-value result) to)
                         (format "~a ~a = ~a ~a" (format-value value) from
                                 (format-value result) to))]
                  [else #f])))))
  (if row (list row) '()))

;; ---- currency --------------------------------------------------------------

(define rates-refresh-interval-seconds 86400)
(define rates-retry-interval-seconds 3600)

;; Currency symbols are matched only where they are unambiguous; codes
;; always work. ¥ maps to CNY by documented decision (JPY users type "jpy").
(define currency-symbols
  (hash "$" "usd" "€" "eur" "£" "gbp" "¥" "cny" "₩" "krw"))

(define (rates-cache)
  (read-json-file (rates-path) #f))

;; Injected in tests; the default performs one bounded HTTPS GET against
;; the same keyless daily feed the `cur` plugin uses, and returns a
;; code → rate hash with USD base, or #f on any failure.
(define current-rates-fetcher (make-parameter #f))

(define (default-fetcher)
  (define result-ch (make-async-channel))
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (async-channel-put result-ch #f))])
       (define conn (http-conn))
       (http-conn-open! conn "open.er-api.com" #:ssl? #t)
       (dynamic-wind
         void
         (lambda ()
           (define-values (status-line _headers in)
             (http-conn-sendrecv! conn "/v6/latest/USD" #:method "GET"))
           (define raw (port->string in))
           (if (regexp-match? #rx"^HTTP/1\\.1 2" status-line)
               (let ([body (with-handlers ([exn:fail? (lambda (_) #f)])
                             (string->jsexpr raw))])
                 (async-channel-put
                  result-ch
                  (and (hash? body)
                       (equal? (hash-ref body 'result #f) 'success)
                       (hash-ref body 'rates #f))))
               (async-channel-put result-ch #f)))
         (lambda () (http-conn-close! conn))))))
  (sync/timeout 3 result-ch))

(define rates-attempt-lock (make-semaphore 1))
(define last-attempt-seconds (box 0))

;; Fetch once and persist the snapshot. Exported for tests; the background
;; refresh and this entry point share one write path.
(define (refresh-rates!)
  (define rates ((or (current-rates-fetcher) default-fetcher)))
  (and (hash? rates)
       (positive? (hash-count rates))
       (begin
         (write-json-atomic!
          (rates-path)
          (hasheq 'fetchedAt (current-seconds) 'base "USD" 'rates rates))
         #t)))

;; Fire-and-forget: never on the search path. At most one attempt per hour
;; so a dead network cannot spawn a thread per keystroke.
(define (maybe-refresh-rates!)
  (call-with-semaphore
   rates-attempt-lock
   (lambda ()
     (define cache (rates-cache))
     (define now (current-seconds))
     (define fetched-at (if (hash? cache) (hash-ref cache 'fetchedAt 0) 0))
     (when (< (+ (unbox last-attempt-seconds) rates-retry-interval-seconds) now)
       (set-box! last-attempt-seconds now)
       (when (or (not cache)
                 (< (+ fetched-at rates-refresh-interval-seconds) now))
         (thread
          (lambda ()
            (with-handlers ([exn:fail? (lambda (_) (void))])
              (refresh-rates!)))))))))

(define (normalize-currency token)
  (define lower (string-downcase token))
  (or (hash-ref currency-symbols lower #f) lower))

(define (currency-rows query)
  (define q (string-downcase (string-trim query)))
  (define m (regexp-match
             #px"^([0-9]+(?:\\.[0-9]+)?)\\s*([a-z$€£¥₩]{1,3})\\s*(?:to|in|->|→|as)\\s*([a-z$€£¥₩]{1,3})$"
             q))
  (define row
    (and m
         (let ([amount (string->number (cadr m))]
               [from (normalize-currency (caddr m))]
               [to (normalize-currency (cadddr m))])
           (and amount
                (not (string=? from to))
                (let ([cache (rates-cache)])
                  (define rates (and (hash? cache) (hash-ref cache 'rates #f)))
                  (define from-rate
                    (and rates (hash-ref rates (string->symbol (string-upcase from)) #f)))
                  (define to-rate
                    (and rates (hash-ref rates (string->symbol (string-upcase to)) #f)))
                  (and from-rate to-rate
                       (not (zero? from-rate))
                       (let ([result (/ (* amount to-rate) from-rate)])
                         (cons (format "~a ~a" (format-currency result) (string-upcase to))
                               (format "~a ~a = ~a · cached rates"
                                       (format-currency amount)
                                       (string-upcase from)
                                       (format-currency result))))))))))
  (if row (list row) '()))

;; Cheap prefilter so the refresh scheduler only wakes for money-shaped
;; queries; the row parse itself remains the authority.
(define (currency-looking? query)
  (and (regexp-match? #px"[0-9]" query)
       (regexp-match? #px"(?i:[a-z$€£¥₩])" query)
       (regexp-match? #px"\\s+(to|in|->|→|as)\\s+" query)))

;; ---- entry point -----------------------------------------------------------

;; One query → zero or more (title . subtitle) pairs. Never raises, never
;; touches the network on the caller's thread.
(define (convert-row-data query)
  (when (currency-looking? query) (maybe-refresh-rates!))
  (append (date-rows query) (unit-rows query) (currency-rows query)))
