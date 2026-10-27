#lang racket/base

;; Per-command bindings (#48): an optional alias and an optional global
;; hotkey attached to a launcher command. A binding id names an action the
;; backend already knows how to run — "<actionId>:<arg>" (for example
;; "sys.run:Lock Screen"); ids without an argument are bare action ids
;; ("win.left"). Pressing a bound hotkey runs the action directly, panel
;; hidden; an alias joins the row's ranking fields so "ch" surfaces
;; Clipboard History without plugin grammar.
;;
;; Same durability rule as every store: atomic JSON snapshots. Sync
;; mirroring is deliberately out of the first slice — the hotkey grammar is
;; cross-platform, but which commands exist is platform-dependent, so a
;; synced binding may not resolve on every machine. Revisit with the sync
;; work rather than syncing broken references.

(require racket/contract
         racket/list
         racket/string
         "paths.rkt"
         "store.rkt")

(provide (struct-out binding)
         (struct-out bindings-store)
         make-bindings-store
         bindings-list-all
         binding-set!
         binding-clear!
         binding-lookup
         binding-alias-for
         valid-alias?
         valid-hotkey-spec?)

(struct binding (id alias hotkey) #:transparent)

(struct bindings-store (path items lock) #:mutable)

(define max-alias-chars 32)
(define max-bindings 200)

;; Aliases are short ranking hints, not expansions: printable, no leading or
;; trailing space, no control characters. Everything else is the query
;; engine's job.
(define (valid-alias? v)
  (and (string? v)
       (<= 1 (string-length v) max-alias-chars)
       (string=? v (string-trim v))
       (andmap (lambda (ch) (and (char>=? ch #\space) (not (char=? ch #\rubout))))
               (string->list v))))

;; Same hotkey grammar the settings store enforces and all three hosts
;; parse: modifiers (alt/ctrl/shift/cmd/win/super) + a key.
(define hotkey-regexp
  #px"^(?:(alt|ctrl|shift|cmd|win|super)\\+)+(space|[a-z]|[0-9]|f(?:[1-9]|1[0-2])|comma|period|minus|equal|tab)$")

(define (valid-hotkey-spec? v)
  (and (string? v) (regexp-match? hotkey-regexp v)))

;; ---- persistence ---------------------------------------------------------

(define (load-items path)
  (define raw (read-json-file path '()))
  (for/hasheq ([entry (in-list (if (list? raw) raw '()))]
               #:when (and (hash? entry)
                           (string? (hash-ref entry 'id #f))))
    (define alias (hash-ref entry 'alias #f))
    (define hotkey (hash-ref entry 'hotkey #f))
    (values (string->symbol (hash-ref entry 'id))
            (binding (hash-ref entry 'id)
                     (and (string? alias) (valid-alias? alias) alias)
                     (and (string? hotkey) (valid-hotkey-spec? hotkey) hotkey)))))

;; Serialize a proposed snapshot before publishing it in memory. A failed
;; atomic rename must not leave a hotkey active only until the next restart.
(define (persist-items! store items)
  (write-json-atomic!
   (bindings-store-path store)
   (for/list ([b (in-list (sort (hash-values items) string<? #:key binding-id))])
     (hasheq 'id (binding-id b)
             'alias (binding-alias b)
             'hotkey (binding-hotkey b)))))

;; ---- CRUD ----------------------------------------------------------------

(define/contract (make-bindings-store [path (bindings-path)])
  (->* () (path?) bindings-store?)
  (bindings-store path (load-items path) (make-semaphore 1)))

(define (binding-key id) (string->symbol id))

(define/contract (bindings-list-all store)
  (-> bindings-store? (listof binding?))
  (sort (hash-values (bindings-store-items store))
        string<? #:key binding-id))

(define/contract (binding-lookup store id)
  (-> bindings-store? string? (or/c binding? #f))
  (hash-ref (bindings-store-items store) (binding-key id) #f))

;; Alias lookup used per keystroke by the ranking providers: one hash ref,
;; no locks — items is replaced atomically, never mutated in place.
(define/contract (binding-alias-for store id)
  (-> (or/c bindings-store? #f) string? (or/c string? #f))
  (and store
       (let ([b (hash-ref (bindings-store-items store) (binding-key id) #f)])
         (and b (binding-alias b)))))

(define/contract (binding-set! store id alias hotkey)
  (-> bindings-store? string? (or/c string? #f) (or/c string? #f) binding?)
  (unless (and (string? id) (non-empty-string? id))
    (raise-argument-error 'binding-set! "non-empty string id" id))
  (unless (or (not alias) (valid-alias? alias))
    (raise-argument-error 'binding-set! "valid alias" alias))
  (unless (or (not hotkey) (valid-hotkey-spec? hotkey))
    (raise-argument-error 'binding-set! "valid hotkey" hotkey))
  (unless (or alias hotkey)
    (raise-argument-error 'binding-set! "an alias or a hotkey is required" id))
  (define record (binding id alias hotkey))
  (call-with-semaphore
   (bindings-store-lock store)
   (lambda ()
     (define next (hash-set (bindings-store-items store) (binding-key id) record))
     (unless (<= (hash-count next) max-bindings)
       (raise-argument-error 'binding-set! "binding limit reached" id))
     (persist-items! store next)
     (set-bindings-store-items! store next)
     record)))

(define/contract (binding-clear! store id)
  (-> bindings-store? string? boolean?)
  (call-with-semaphore
   (bindings-store-lock store)
   (lambda ()
     (define next (hash-remove (bindings-store-items store) (binding-key id)))
     (define removed? (< (hash-count next) (hash-count (bindings-store-items store))))
     (persist-items! store next)
     (set-bindings-store-items! store next)
     removed?)))
