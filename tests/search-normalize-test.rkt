#lang racket/base

(require rackunit
         "../app/core/fuzzy.rkt"
         "../app/core/search-normalize.rkt")

(define (derived-score query text)
  (fuzzy-score-fields query
                      (search-fields-with-pinyin
                       (list (cons 1.0 text)))))

(test-case "full pinyin and initials discover Chinese names"
  (check-true (exact-integer? (derived-score "weixin" "微信")))
  (check-true (exact-integer? (derived-score "wx" "微信")))
  (check-true (> (derived-score "微信" "微信")
                 (derived-score "weixin" "微信"))))

(test-case "mixed Han and Latin text keeps word boundaries"
  (check-true (exact-integer? (derived-score "wx work" "微信 Work"))))

(test-case "polyphonic readings are bounded and searchable"
  (define variants (pinyin-variants "重庆"))
  (check-true (<= (length variants) 8))
  (check-not-false (member "chongqing" (map car variants)))
  (check-true (exact-integer? (derived-score "cq" "重庆"))))

(test-case "traditional Chinese and u-umlaut keyboard spelling"
  (check-true (exact-integer? (derived-score "taiwan" "臺灣")))
  (check-true (exact-integer? (derived-score "nv" "女"))))

(test-case "non-Chinese fields are unchanged"
  (define fields (list (cons 1.0 "Firefox")))
  (check-equal? (search-fields-with-pinyin fields) fields)
  (check-false (derived-score "zzz" "Firefox")))
