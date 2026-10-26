#lang racket/base

;; Shared search normalization. Literal display text always remains the
;; strongest field; these derived fields only add offline Chinese pinyin
;; recall for the common Racket ranker used by every native host.

(require racket/contract
         racket/list
         racket/promise
         racket/runtime-path
         racket/string)

(provide pinyin-variants
         search-fields-with-pinyin)

(define-runtime-path pinyin-data-path "data/pinyin.rktd")
(define max-variants 8)

(define pinyin-table
  (delay
    (call-with-input-file pinyin-data-path read)))

(define (possible-han? ch)
  (define cp (char->integer ch))
  (or (= cp #x3007)
      (<= #x3400 cp #x4DBF)
      (<= #x4E00 cp #x9FFF)
      (<= #xF900 cp #xFAFF)
      (<= #x20000 cp #x323AF)))

(define (readings-for ch)
  (and (possible-han? ch)
       (hash-ref (force pinyin-table) (char->integer ch) #f)))

(define (separator? ch)
  (not (or (char-alphabetic? ch) (char-numeric? ch))))

(define (append-literal state ch)
  (define full (car state))
  (define initials (cdr state))
  (define piece
    (cond
      [(separator? ch)
       (if (or (string=? full "") (string-suffix? full " ")) "" " ")]
      [else (string (char-downcase ch))]))
  (cons (string-append full piece)
        (string-append initials piece)))

(define (expand-reading state reading)
  (cons (string-append (car state) reading)
        (string-append (cdr state) (substring reading 0 1))))

(define (take-bounded xs)
  (take xs (min max-variants (length xs))))

(define/contract (pinyin-variants text)
  (-> string? (listof (cons/c string? string?)))
  (if (not (for/or ([ch (in-string text)]) (possible-han? ch)))
      '()
      (let loop ([chars (string->list text)]
                 [states (list (cons "" ""))])
        (cond
          [(null? chars)
           (remove-duplicates
            (for/list ([state (in-list states)])
              (cons (string-trim (car state))
                    (string-trim (cdr state))))
            equal?)]
          [else
           (define readings (readings-for (car chars)))
           (define next
             (if (and readings (> (vector-length readings) 0))
                 (for*/list ([state (in-list states)]
                             [reading (in-vector readings)])
                   (expand-reading state reading))
                 (for/list ([state (in-list states)])
                   (append-literal state (car chars)))))
           (loop (cdr chars) (take-bounded (remove-duplicates next equal?)))]))))

(define/contract (search-fields-with-pinyin fields)
  (-> (listof (cons/c (>/c 0.0) string?))
      (listof (cons/c (>/c 0.0) string?)))
  (append
   fields
   (append*
    (for/list ([field (in-list fields)])
      (define weight (car field))
      (append*
       (for/list ([variant (in-list (pinyin-variants (cdr field)))])
         (list (cons (* weight 0.58) (car variant))
               (cons (* weight 0.48) (cdr variant)))))))))
