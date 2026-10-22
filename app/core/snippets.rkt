#lang racket/base

;; Snippets store.
;;
;; Named text expansions with optional keywords. The backend owns storage,
;; CRUD, and search; hosts render them and request copies through events.
;; Same durability rule as every other store: atomic JSON snapshots.

(require json
         racket/contract
         racket/file
         racket/list
         racket/path
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
         snippet-count
         snippet-export!
         snippet-import!)

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


;; ---- portable bundles --------------------------------------------------
;;
;; Export never replaces another file. Import validates the entire versioned
;; bundle and checks keyword claims before mutating the store. IDs/timestamps
;; survive a round-trip; imports merge by ID rather than wiping local data.

(define snippet-bundle-format "fulcrum-snippets")
(define snippet-bundle-version 1)
(define max-bundle-bytes (* 32 1024 1024))

(define (snippet->json s)
  (hasheq 'id (snippet-id s)
          'name (snippet-name s)
          'keyword (snippet-keyword s)
          'text (snippet-text s)
          'ts (snippet-ts s)))

(define/contract (snippet-export! store destination)
  (-> snippet-store? string? exact-nonnegative-integer?)
  (unless (non-empty-string? (string-trim destination))
    (raise-argument-error 'snippet-export! "non-empty path" destination))
  (define path (expand-user-path (string->path destination)))
  (define parent (or (path-only path) (current-directory)))
  (unless (directory-exists? parent)
    (raise-user-error 'snippet-export! "destination directory does not exist"))
  (when (or (file-exists? path) (directory-exists? path))
    (raise-user-error 'snippet-export! "destination already exists (refusing to overwrite)"))
  (define snapshot
    (call-with-semaphore (snippet-store-lock store)
      (lambda () (map snippet->json (snippet-list store)))))
  (define tmp (make-temporary-file "fulcrum-snippets-~a.json" #f parent))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp
        (lambda (out)
          (write-json (hasheq 'format snippet-bundle-format
                              'version snippet-bundle-version
                              'snippets snapshot) out))
        #:exists 'replace)
      (rename-file-or-directory tmp path))
    (lambda ()
      (when (file-exists? tmp) (delete-file tmp))))
  (length snapshot))

(define (json->snippet entry)
  (unless (hash? entry)
    (raise-user-error 'snippet-import! "invalid snippet entry"))
  (define id (hash-ref entry 'id #f))
  (define name (hash-ref entry 'name #f))
  (define keyword (hash-ref entry 'keyword #f))
  (define text (hash-ref entry 'text #f))
  (define ts (hash-ref entry 'ts #f))
  (unless (and (string? id)
               (<= 1 (string-length id) 128)
               (string? name)
               (non-empty-string? (string-trim name))
               (<= (string-length name) max-name-chars)
               (string? keyword)
               (<= (string-length keyword) max-keyword-chars)
               (string? text)
               (<= (string-length text) max-text-chars)
               (real? ts)
               (<= 0 ts))
    (raise-user-error 'snippet-import! "invalid snippet field or length"))
  (snippet id name keyword text ts))

(define (check-snippet-claims! entries)
  (define ids (make-hash))
  (define keywords (make-hash))
  (for ([s (in-list entries)])
    (when (hash-has-key? ids (snippet-id s))
      (raise-user-error 'snippet-import! "duplicate snippet ID"))
    (hash-set! ids (snippet-id s) #t)
    (unless (string=? (snippet-keyword s) "")
      (let ([key (string-foldcase (snippet-keyword s))])
        (when (hash-has-key? keywords key)
          (raise-user-error 'snippet-import!
                            (format "duplicate keyword: ~a" (snippet-keyword s))))
        (hash-set! keywords key #t)))))

(define/contract (snippet-import! store source)
  (-> snippet-store? string? exact-nonnegative-integer?)
  (unless (non-empty-string? (string-trim source))
    (raise-argument-error 'snippet-import! "non-empty path" source))
  (define path (expand-user-path (string->path source)))
  (when (> (file-size path) max-bundle-bytes)
    (raise-user-error 'snippet-import! "bundle exceeds 32 MiB limit"))
  ;; read-json-file deliberately swallows errors for cache stores; portable
  ;; user-supplied imports must instead reject malformed or truncated JSON.
  (define bundle (call-with-input-file path read-json))
  (unless (and (hash? bundle)
               (equal? (hash-ref bundle 'format #f) snippet-bundle-format)
               (equal? (hash-ref bundle 'version #f) snippet-bundle-version)
               (list? (hash-ref bundle 'snippets #f))
               (<= (length (hash-ref bundle 'snippets)) 10000))
    (raise-user-error 'snippet-import! "unsupported or malformed bundle"))
  (define incoming (map json->snippet (hash-ref bundle 'snippets)))
  (check-snippet-claims! incoming)
  (call-with-semaphore
   (snippet-store-lock store)
   (lambda ()
     (define ids (for/hash ([s (in-list incoming)])
                   (values (snippet-id s) #t)))
     (define retained
       (filter (lambda (s) (not (hash-has-key? ids (snippet-id s))))
               (snippet-store-items store)))
     (define merged (append incoming retained))
     ;; Also catch keyword collisions with entries already on the machine.
     (check-snippet-claims! merged)
     (set-snippet-store-items! store merged)
     (persist! store)))
  (length incoming))
