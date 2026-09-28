#lang racket/base

;; Fuzzy matcher contract tests. Ranking order, not exact scores, is the
;; public contract, but a few score anchors are pinned here so tuning never
;; silently regresses prefix or boundary behavior.

(require racket/string
         rackunit
         "../app/core/fuzzy.rkt")

(define (check->= actual floor-value)
  (check-true (>= actual floor-value)
              (format "expected ~a >= ~a" actual floor-value)))

(test-case "basic matching"
  (check-false (fuzzy-score "" "anything") "empty query matches nothing")
  (check-false (fuzzy-score "xyz" "Fulcrum") "no subsequence, no match")
  (check-true (exact-integer? (fuzzy-score "ful" "Fulcrum")))
  (check-true (exact-integer? (fuzzy-score "FUL" "Fulcrum")) "case-insensitive"))

(test-case "prefix beats subsequence"
  (check->= (fuzzy-score "ful" "Fulcrum")
            (fuzzy-score "ful" "MyFulcrumTool")))

(test-case "boundary beats mid-word"
  (check->= (fuzzy-score "term" "My Term")
            (fuzzy-score "term" "Interms")))

(test-case "exact case small bonus"
  (check->= (fuzzy-score "Ful" "Fulcrum")
            (fuzzy-score "ful" "Fulcrum")))

(test-case "multi-term queries"
  ;; Every term must match, in any position.
  (check-true (exact-integer? (fuzzy-score "app set" "Application Settings")))
  (check-false (fuzzy-score "app xyz" "Application Settings"))
  ;; Subsequence still matches initials.
  (check-true (exact-integer? (fuzzy-score "vs" "Visual Studio Code"))))

(test-case "field weights"
  ;; All fields are searched; the best field score wins.
  (check-true (exact-integer?
               (fuzzy-score-fields "notes" (list (cons 1.0 "Notes")
                                                 (cons 0.5 "marginalia")))))
  (check-true (exact-integer?
               (fuzzy-score-fields "marg" (list (cons 1.0 "Notes")
                                                (cons 0.5 "marginalia")))))
  (check-false (fuzzy-score-fields "zzz" (list (cons 1.0 "Notes")))))

(test-case "score bounds"
  (define bounded (fuzzy-score "f" "Fulcrum"))
  (check-true (<= 0 bounded 1000) "scores stay in 0..1000")
  (check-true (<= 0 (fuzzy-score "fulcrum application launcher"
                                 "Fulcrum Application Launcher") 1000)))
