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
         "../core/ai.rkt"
         "../core/paths.rkt"
         "../core/store.rkt"
         "../core/sync.rkt"
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
         "Base URL the updater fetches the channel manifest from")
   'sync-root
   (list string? ""
         "Sync beta: directory a file sync service replicates (iCloud Drive, Dropbox, Syncthing); settings and snippets mirror there. Empty disables sync")
   'ai-provider
   (list (lambda (v) (member v ai-providers)) ""
         "BYOK AI provider: empty (off), openai, anthropic, or ollama")
   'ai-model
   (list string? ""
         "AI model; empty uses the provider default (gpt-4o-mini / claude-3-5-haiku / llama3.2)")
   'ai-base-url
   (list (lambda (v) (or (string=? v "") (string-prefix? v "http")))
         ""
         "AI base URL; empty uses the provider default (ollama defaults to http://localhost:11434)")))

;; The sync root has to be readable before the typed manager exists (the
;; restore decision precedes loading), so peek the raw file once. A file
;; that does not parse simply means "no sync root yet".
(define (peek-sync-root path)
  (with-handlers ([exn:fail? (lambda (_) "")])
    (define raw (read-json-file path (hash)))
    (define value (if (hash? raw) (hash-ref raw 'sync-root #f) #f))
    (if (string? value) value "")))

(define/contract (make-settings-manager path #:sync-root [override #f])
  (->* (path?) (#:sync-root (or/c string? #f)) settings-manager?)
  ;; Restore from a newer mirror before the store reads the file, so a
  ;; wiped machine comes back with its settings intact. FULCRUM_SYNC_DIR
  ;; (or an explicit override) beats the stored setting: the setting lives
  ;; in the file that restore would bring back.
  (sync-restore! path (or override (sync-root-override) (peek-sync-root path)))
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
  ;; Mirror the whole file after every successful write. Reading the root
  ;; back through the typed manager also means a mid-session sync-root
  ;; change takes effect from the very next write.
  (sync-mirror! (rivet:settings-store-path (settings-manager-store manager))
                (or (sync-root-override) (settings-get manager 'sync-root)))
  #t)

(define/contract (settings-list manager)
  (-> settings-manager? (listof settings-entry?))
  (for/list ([key (in-list (sort (hash-keys (settings-manager-schema manager)) symbol<?))])
    (define spec (hash-ref (settings-manager-schema manager) key))
    (settings-entry (symbol->string key)
                    (format "~a" (settings-get manager key))
                    (caddr spec))))
