#lang racket/base

;; Web search providers.
;;
;; Two behaviors in one provider:
;;   - bangs: a leading "!<engine>" (or "<engine> " without the bang for the
;;     single-letter engines) routes the rest of the query to that engine
;;   - fallback: any other non-empty query offers a default-engine search row
;;
;; URLs are built with RFC 3986 percent-encoding; nothing is fetched here —
;; the row's action asks the host to open the URL in the default browser.

(require racket/contract
         racket/string)

(provide bang-engines
         web-bang->url
         web-search-row-target
         (struct-out web-bang))

(struct web-bang (prefix name url-template icon) #:transparent)

(define bangs
  (list (web-bang "!g" "Google" "https://www.google.com/search?q=~a" "globe")
        (web-bang "!d" "DuckDuckGo" "https://duckduckgo.com/?q=~a" "globe")
        (web-bang "!gh" "GitHub" "https://github.com/search?q=~a" "globe")
        (web-bang "!so" "Stack Overflow"
                  "https://stackoverflow.com/search?q=~a" "globe")
        (web-bang "!w" "Wikipedia" "https://en.wikipedia.org/wiki/Special:Search?search=~a" "globe")
        (web-bang "!yt" "YouTube" "https://www.youtube.com/results?search_query=~a" "globe")
        (web-bang "!m" "Google Maps" "https://www.google.com/maps/search/~a" "globe")
        (web-bang "!t" "translate.google.com"
                  "https://translate.google.com/?sl=auto&op=translate&text=~a" "globe")))

(define/contract (bang-engines)
  (-> (listof web-bang?))
  bangs)

(define (uri-encode s)
  ;; RFC 3986 unreserved characters survive; everything else is percent
  ;; encoded from the UTF-8 bytes. Spaces become %20.
  (define out (open-output-string))
  (for ([b (in-bytes (string->bytes/utf-8 s))])
    (define ch (integer->char b))
    (cond
      [(or (and (char>=? ch #\a) (char<=? ch #\z))
           (and (char>=? ch #\A) (char<=? ch #\Z))
           (and (char>=? ch #\0) (char<=? ch #\9))
           (memv ch '(#\- #\_ #\. #\~)))
       (display ch out)]
      [else (fprintf out "%~X" b)]))
  (get-output-string out))

(define/contract (web-bang->url bang text)
  (-> web-bang? string? string?)
  (format (web-bang-url-template bang) (uri-encode text)))

(define/contract (web-search-row-target query
                                        #:default-engine [default-engine "!g"])
  (->* (string?) (#:default-engine string?) (or/c (cons/c string? string?) #f))
  ;; Returns (prefix . url) for the best-matching bang, or a default-engine
  ;; target for any non-empty query, or #f for an empty query.
  (define trimmed (string-trim query))
  (if (zero? (string-length trimmed))
      #f
      (let ([match
             (findf (lambda (b)
                      (string-prefix? trimmed (string-append (web-bang-prefix b) " ")))
                    bangs)])
        (if match
            (cons (web-bang-prefix match)
                  (web-bang->url match
                                 (string-trim
                                  (substring trimmed
                                             (string-length (web-bang-prefix match))))))
            (let ([fallback (findf (lambda (b)
                                     (string=? (web-bang-prefix b) default-engine))
                                   bangs)])
              (cons "web" (web-bang->url fallback trimmed)))))))
