#lang racket/base

;; Fulcrum fuzzy matcher.
;;
;; The matcher answers one question for the search engine: does a candidate
;; string contain the query as an in-order subsequence, and how well?
;;
;; Scoring is heuristic and deterministic (same inputs, same score). It is
;; kept in one module with explicit component bonuses so tests can pin the
;; behavior that ranking and the UI rely on:
;;
;;   - multi-term queries split on spaces; every term must match
;;   - word-boundary matches and consecutive matches score higher
;;   - exact-case matches score slightly higher than case-folded ones
;;   - a candidate that starts with the query gets a strong prefix bonus
;;   - skipped characters (gaps) are penalized
;;
;; A candidate is matched against weighted fields (title, subtitle,
;; keywords): a term matches if it matches any field, and the best field
;; score wins. Scores are normalized to 0..1000; #f means "no match".
;; Callers must treat only ordering as contractual.

(require racket/contract
         racket/math
         racket/string)

(provide fuzzy-score
         fuzzy-score-fields)

(define score-upper-bound 1000)

(define (word-boundary? source index)
  (or (zero? index)
      (let ([prev (string-ref source (sub1 index))])
        (not (or (char-alphabetic? prev) (char-numeric? prev))))))

(define (folded ch)
  (char-downcase ch))

(define (prefix-score term text)
  ;; Candidates that start with a term are usually what the user means.
  (define tlen (string-length term))
  (and (<= tlen (string-length text))
       (for/and ([qc (in-string term)]
                 [cc (in-string text)])
         (char=? (folded qc) (folded cc)))
       (+ 120
          (if (and (> tlen 0) (char=? (string-ref term 0) (string-ref text 0)))
              10
              0))))

(define (subsequence-score term text)
  ;; Greedy in-order match of `term` inside `text`. Greedy is deliberate:
  ;; O(n) per candidate keeps full-index searches bounded, and the bonuses
  ;; recover most of the quality an optimal alignment would add. Returns a
  ;; score or #f.
  (define qlen (string-length term))
  (define clen (string-length text))
  (let loop ([qi 0]
             [ci 0]
             [score 0]
             [prev-match-ci -1])
    (cond
      [(= qi qlen) score]
      [(>= ci clen) #f]
      [else
       (define qc (string-ref term qi))
       (define cc (string-ref text ci))
       (if (char=? (folded qc) (folded cc))
           (let ([step (+ (if (word-boundary? text ci) 14 8)
                          (if (char=? qc cc) 4 0)
                          (if (= prev-match-ci (sub1 ci)) 10 0))])
             (loop (add1 qi) (add1 ci) (+ score step) ci))
           ;; Every gap character costs one point once matching has started.
           (loop qi (add1 ci) (if (zero? qi) score (sub1 score)) prev-match-ci))])))

(define (score-term term fields)
  (for/fold ([best #f])
            ([field (in-list fields)])
    (define raw
      (or (prefix-score term (cdr field))
          (subsequence-score term (cdr field))))
    (if raw
        (let ([weighted (exact-floor (* raw (car field)))])
          (if (or (not best) (> weighted best)) weighted best))
        best)))

(define/contract (fuzzy-score-fields query fields)
  (-> string? (listof (cons/c (>/c 0.0) string?)) (or/c exact-integer? #f))
  (define trimmed (string-trim query))
  (cond
    [(zero? (string-length trimmed)) #f]
    [else
     (define per-term
       (for/list ([term (in-list (string-split trimmed))])
         (score-term term fields)))
     (and (andmap values per-term)
          (let* ([total (apply + per-term)]
                 [normalized
                  (exact-floor (/ (* total 1000)
                                  (* (length per-term) 400)))]
                 [clamped (min score-upper-bound (max 0 normalized))])
            clamped))]))

(define/contract (fuzzy-score query candidate)
  (-> string? string? (or/c exact-integer? #f))
  (fuzzy-score-fields query (list (cons 1.0 candidate))))
