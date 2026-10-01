#lang racket/base

;; Snippets store.
;;
;; Named text expansions with optional keywords. The backend owns storage,
;; CRUD, and search; hosts render them and request copies through events.
;; Same durability rule as every other store: atomic JSON snapshots.

(require racket/contract
         racket/list
         racket/string
         "../core/fuzzy.rkt"
         "../core/sync.rkt"
         "paths.rkt"
         "store.rkt")

(provide (struct-out snippet)
         (struct-out snippet-store)
         make-snippet-store
         snippet-save!
         snippet-delete!
         snippet-ref
         snippet-list
         snippet-search
         snippet-by-keyword
         snippet-count)

(struct snippet (id name keyword text ts) #:transparent)

(struct snippet-store (path items lock sync-root) #:mutable)

(define max-text-chars 100000)
(define max-name-chars 200)
(define max-keyword-chars 64)

(define (load-items path)
  (define raw (read-json-file path '()))
  (for/list ([entry (in-list (if (list? raw) raw '()))]
             #:when (and (hash? entry)
                         (hash-has-key? entry 'id)
                         (hash-has-key? entry 'name)
                         (hash-has-key? entry 'text)))
    (snippet (hash-ref entry 'id)
             (hash-ref entry 'name)
             (or (hash-ref entry 'keyword #f) "")
             (hash-ref entry 'text)
             (or (hash-ref entry 'ts #f) 0))))

(define (persist! store)
  (write-json-atomic!
   (snippet-store-path store)
   (for/list ([s (in-list (snippet-store-items store))])
     (hasheq 'id (snippet-id s)
             'name (snippet-name s)
             'keyword (snippet-keyword s)
             'text (snippet-text s)
             'ts (snippet-ts s))))
  (sync-mirror! (snippet-store-path store) (snippet-store-sync-root store)))

(define (clip s limit)
  (if (> (string-length s) limit) (substring s 0 limit) s))

(define/contract (make-snippet-store [path (snippets-path)] #:sync-root [sync-root ""])
  (->* () (path? #:sync-root string?) snippet-store?)
  ;; Restore from a newer mirror before loading, so a wiped machine comes
  ;; back with its snippets.
  (sync-restore! path sync-root)
  (snippet-store path (load-items path) (make-semaphore 1) sync-root))

(define/contract (snippet-save! store
                                name
                                text
                                [keyword ""]
                                [id #f])
  (->* (snippet-store? string? string?)
       (string? (or/c string? #f))
       snippet?)
  (unless (non-empty-string? (string-trim name))
    (raise-argument-error 'snippet-save! "non-empty string name" name))
  (define record
    (snippet (or id (format "s~a-~a" (current-inexact-milliseconds) (random 4294967087)))
             (clip name max-name-chars)
             (clip (or keyword "") max-keyword-chars)
             (clip text max-text-chars)
             (current-inexact-milliseconds)))
  (call-with-semaphore
   (snippet-store-lock store)
   (lambda ()
     (set-snippet-store-items!
      store
      (cons record
            (filter (lambda (s)
                      (and (not (string=? (snippet-id s) (snippet-id record)))
                           (not (and id (string=? (snippet-id s) id)))))
                    (snippet-store-items store))))
     (persist! store)
     record)))

(define/contract (snippet-delete! store id)
  (-> snippet-store? string? boolean?)
  (call-with-semaphore
   (snippet-store-lock store)
   (lambda ()
     (define items (snippet-store-items store))
     (set-snippet-store-items!
      store
      (filter (lambda (s) (not (string=? (snippet-id s) id))) items))
     (define removed? (< (length (snippet-store-items store)) (length items)))
     (when removed? (persist! store))
     removed?)))

(define/contract (snippet-ref store id)
  (-> snippet-store? string? (or/c snippet? #f))
  (findf (lambda (s) (string=? (snippet-id s) id)) (snippet-store-items store)))

(define/contract (snippet-list store)
  (-> snippet-store? (listof snippet?))
  (sort (snippet-store-items store) string<? #:key snippet-name))

(define/contract (snippet-search store query)
  (-> snippet-store? string? (listof snippet?))
  (for/list ([s (in-list (snippet-list store))]
             #:when (fuzzy-score-fields
                     query
                     (list (cons 1.0 (snippet-name s))
                           (cons 0.9 (snippet-keyword s))
                           (cons 0.4 (snippet-text s)))))
    s))

(define/contract (snippet-by-keyword store keyword)
  (-> snippet-store? string? (or/c snippet? #f))
  (define k (string-trim keyword))
  (and (non-empty-string? k)
       (findf (lambda (s)
                (and (non-empty-string? (snippet-keyword s))
                     (string-ci=? (snippet-keyword s) k)))
              (snippet-store-items store))))

(define/contract (snippet-count store)
  (-> snippet-store? exact-nonnegative-integer?)
  (length (snippet-store-items store)))
