#lang racket/base

;; Fulcrum settings.
;;
;; Typed keys over `rivet/system`'s atomic JSON settings store. Values are
;; validated on read and on write; a stored value that no longer validates
;; (a hand-edited file, a downgrade) falls back to the default rather than
;; poisoning every consumer, while `settings-set!` rejects invalid writes
;; loudly because the UI must know.

(require racket/contract
         racket/list
         racket/string
         (prefix-in rivet: rivet/system))

(provide make-settings-manager
         settings-get
         settings-set!
         settings-list
         (struct-out settings-entry))

(struct settings-entry (key value description) #:transparent)

(struct settings-manager (store schema) #:transparent)

(define schema
  (hasheq
   'theme
   (list (lambda (v) (member v '("system" "light" "dark"))) "system"
         "UI theme: system, light, or dark")
   'hotkey
   (list string? "alt+space"
         "Global hotkey that summons the launcher (applied by the host)")
   'max-results
   (list (lambda (v) (and (exact-integer? v) (>= v 5) (<= v 25))) 12
         "Maximum results shown in the list")
   'clipboard-enabled
   (list boolean? #t
         "Record clipboard changes into history")
   'clipboard-limit
   (list (lambda (v) (and (exact-integer? v) (>= v 10) (<= v 100000))) 1000
         "Maximum clipboard history entries kept on device")
   'web-search-enabled
   (list boolean? #t
         "Offer web-search rows (bangs and fallback)")
   'default-engine
   (list (lambda (v) (member v '("!g" "!d" "!gh" "!so" "!w" "!yt" "!m" "!t"))) "!g"
         "Bang used for the generic web-search fallback row")
   'plugins-enabled
   (list boolean? #t
         "Load plugins from the plugins directory")
   'plugins-timeout-ms
   (list (lambda (v) (and (exact-integer? v) (>= v 100) (<= v 10000))) 2000
         "Per-call plugin process timeout in milliseconds")
   'update-base-url
   (list (lambda (v) (and (string? v)
                          (or (string-prefix? v "https://")
                              (string-prefix? v "http://"))))
         "https://downloads.jrtx.site/fulcrum"
         "Base URL the updater fetches the channel manifest from")))

(define/contract (make-settings-manager path)
  (-> path? settings-manager?)
  (settings-manager (rivet:make-settings-store path) schema))

(define/contract (settings-get manager key)
  (-> settings-manager? symbol? any/c)
  (define spec (hash-ref (settings-manager-schema manager) key #f))
  (unless spec (error 'settings-get "unknown settings key: ~a" key))
  (define default (cadr spec))
  (define valid? (car spec))
  (define stored
    (with-handlers ([exn:fail? (lambda (_) default)])
      (rivet:settings-ref (settings-manager-store manager) key default)))
  (if (valid? stored) stored default))

(define/contract (settings-set! manager key value)
  (-> settings-manager? symbol? any/c boolean?)
  (define spec (hash-ref (settings-manager-schema manager) key #f))
  (unless spec (error 'settings-set! "unknown settings key: ~a" key))
  (define valid? (car spec))
  (unless (valid? value)
    (raise-argument-error 'settings-set!
                          (format "valid value for ~a" key) value))
  (rivet:settings-set! (settings-manager-store manager) key value)
  #t)

(define/contract (settings-list manager)
  (-> settings-manager? (listof settings-entry?))
  (for/list ([key (in-list (sort (hash-keys (settings-manager-schema manager)) symbol<?))])
    (define spec (hash-ref (settings-manager-schema manager) key))
    (settings-entry (symbol->string key)
                    (format "~a" (settings-get manager key))
                    (caddr spec))))
