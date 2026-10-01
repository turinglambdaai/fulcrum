#lang racket/base

;; Quicklinks — user-defined URL templates, the cheap half of Raycast's
;; quicklinks. A link is a name, a URL (optionally containing `{query}`),
;; and an optional keyword. A keyword claims `<keyword> …` queries exactly
;; like a plugin command; typing `yt nature` opens the YouTube search for
;; "nature". Links without `{query}` behave as plain bookmarks.
;;
;; Managed from the launcher itself: query `quicklinks` lists every link
;; with a delete action, and the one-line grammar
;; `add link <keyword> <url> [name…]` saves a new one. Same durability rule
;; as every store: atomic JSON snapshots, mirrored to the sync root.

(require net/uri-codec
         racket/contract
         racket/list
         racket/string
         "fuzzy.rkt"
         "paths.rkt"
         "store.rkt"
         "sync.rkt")

(provide (struct-out quicklink)
         (struct-out quicklink-store)
         make-quicklink-store
         link-save!
         link-delete!
         link-list
         link-search
         link-by-keyword
         expand-link-url)

(struct quicklink (id name url keyword) #:transparent)

(struct quicklink-store (path items lock sync-root) #:mutable)

(define max-url-chars 2000)
(define max-name-chars 100)
(define max-keyword-chars 32)

;; ---- persistence ---------------------------------------------------------

(define (load-items path)
  (define raw (read-json-file path '()))
  (for/list ([entry (in-list (if (list? raw) raw '()))]
             #:when (and (hash? entry)
                         (hash-has-key? entry 'id)
                         (string? (hash-ref entry 'url #f))
                         (string? (hash-ref entry 'name #f))))
    (quicklink (hash-ref entry 'id)
               (hash-ref entry 'name)
               (hash-ref entry 'url)
               (or (hash-ref entry 'keyword #f) ""))))

(define (persist! store)
  (write-json-atomic!
   (quicklink-store-path store)
   (for/list ([l (in-list (quicklink-store-items store))])
     (hasheq 'id (quicklink-id l)
             'name (quicklink-name l)
             'url (quicklink-url l)
             'keyword (quicklink-keyword l))))
  (sync-mirror! (quicklink-store-path store) (quicklink-store-sync-root store)))

(define (clip s limit)
  (if (> (string-length s) limit) (substring s 0 limit) s))

;; ---- CRUD ----------------------------------------------------------------

(define/contract (make-quicklink-store [path (quicklinks-path)] #:sync-root [sync-root ""])
  (->* () (path? #:sync-root string?) quicklink-store?)
  (sync-restore! path sync-root)
  (quicklink-store path (load-items path) (make-semaphore 1) sync-root))

(define/contract (link-save! store name url [keyword ""] [id #f])
  (->* (quicklink-store? string? string?) (string? (or/c string? #f)) quicklink?)
  (unless (non-empty-string? (string-trim name))
    (raise-argument-error 'link-save! "non-empty string name" name))
  (unless (non-empty-string? (string-trim url))
    (raise-argument-error 'link-save! "non-empty string url" url))
  (define record
    (quicklink (or id (format "l~a-~a" (current-inexact-milliseconds) (random 4294967087)))
               (clip (string-trim name) max-name-chars)
               (clip (string-trim url) max-url-chars)
               (clip (string-trim (or keyword "")) max-keyword-chars)))
  (call-with-semaphore
   (quicklink-store-lock store)
   (lambda ()
     (set-quicklink-store-items!
      store
      (cons record
            (filter (lambda (l)
                      (and (not (string=? (quicklink-id l) (quicklink-id record)))
                           (not (and id (string=? (quicklink-id l) id)))))
                    (quicklink-store-items store))))
     (persist! store)
     record)))

(define/contract (link-delete! store id)
  (-> quicklink-store? string? boolean?)
  (call-with-semaphore
   (quicklink-store-lock store)
   (lambda ()
     (define items (quicklink-store-items store))
     (set-quicklink-store-items!
      store
      (filter (lambda (l) (not (string=? (quicklink-id l) id))) items))
     (define removed? (< (length (quicklink-store-items store)) (length items)))
     (when removed? (persist! store))
     removed?)))

;; ---- queries -------------------------------------------------------------

(define/contract (link-list store)
  (-> quicklink-store? (listof quicklink?))
  (sort (quicklink-store-items store) string<? #:key quicklink-name))

(define/contract (link-search store query)
  (-> quicklink-store? string? (listof quicklink?))
  (for/list ([l (in-list (link-list store))]
             #:when (fuzzy-score-fields
                     query
                     (list (cons 1.0 (quicklink-name l))
                           (cons 0.9 (quicklink-keyword l))
                           (cons 0.4 (quicklink-url l)))))
    l))

(define/contract (link-by-keyword store query)
  (-> quicklink-store? string? (or/c (cons/c quicklink? string?) #f))
  ;; The link whose keyword claims this query, paired with the text after
  ;; the keyword ("yt nature" → link + "nature").
  (define trimmed (string-trim query))
  (for/first ([l (in-list (link-list store))]
              #:when (let ([k (quicklink-keyword l)])
                       (and (non-empty-string? k)
                            (or (string-ci=? trimmed k)
                                (string-prefix? (string-downcase trimmed)
                                                (string-append (string-downcase k) " "))))))
    (define k (quicklink-keyword l))
    (cons l (if (> (string-length trimmed) (string-length k))
                (string-trim (substring trimmed (string-length k)))
                ""))))

;; ---- expansion -----------------------------------------------------------

(define (expand-link-url link text)
  (define url (quicklink-url link))
  (if (string-contains? url "{query}")
      (string-replace url "{query}" (uri-encode text))
      url))
