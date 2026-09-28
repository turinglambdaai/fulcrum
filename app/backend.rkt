#lang racket/base

;; Fulcrum backend — the single RVT1 surface shared by the macOS, Windows,
;; and Linux hosts. Everything declared here is the wire contract: changing
;; an RPC name, a State, an Event, or the 8-column result row layout is a
;; cross-platform release, not a local edit.
;;
;; Row layout (positional, all strings):
;;   (id title subtitle kind arg icon hint badge)
;;
;; Lifecycle: the embedded runtime calls `start` with the two RVT1 fds. The
;; engine is built once here (app discovery, stores, plugins) and shared by
;; every request worker through `current-engine`; tests can parameterize it
;; with an engine over fixture stores.

(require racket/format
         racket/string
         rivet/backend
         "core/apps.rkt"
         "core/clipboard.rkt"
         "core/engine.rkt"
         "core/paths.rkt"
         "core/plugins.rkt"
         "core/settings.rkt"
         "core/snippets.rkt"
         "update.rkt")

(provide start
         current-engine
         current-settings
         app-version)

(define app-version "0.1.0")

;; ---- States -------------------------------------------------------------

(define-state theme : String "system")
(define-state hotkey : String "alt+space")
(define-state version : String app-version)

;; ---- Events -------------------------------------------------------------

(define-event notify : String)
(define-event copy-to-clipboard : String)
(define-event open-url : String)
(define-event update-available : String)

;; ---- shared engine ------------------------------------------------------

(define current-engine (make-parameter #f))
(define current-settings (make-parameter #f))

(define (engine!)
  (define e (current-engine))
  (unless e (error 'backend "engine is not initialized; start was not called"))
  e)

(define (settings!)
  (define s (current-settings))
  (unless s (error 'backend "settings are not initialized; start was not called"))
  s)

;; Emits backend events produced by engine-run as RVT1 Events.
(define (emit-events! events)
  (for ([entry (in-list events)])
    (case (car entry)
      [(copy-to-clipboard) (copy-to-clipboard (cdr entry))]
      [(open-url) (open-url (cdr entry))]
      [else (notify (format "~a" entry))])))

(define (rows-for engine query)
  (define rows (engine-search engine query))
  (if (settings-get (settings!) 'web-search-enabled)
      rows
      (filter (lambda (row) (not (string=? (list-ref row 3) "Web Search")))
              rows)))

;; ---- RPCs ---------------------------------------------------------------

(define-rpc (health : String)
  (format "fulcrum ~a apps=~a" app-version (engine-app-count (engine!))))

(define-rpc (search [query String] : (List (List String)))
  (rows-for (engine!) query))

(define-rpc (run-action [id String] [arg String] : String)
  (define outcome (engine-run (engine!) id arg))
  (emit-events! (cdr outcome))
  (car outcome))

(define-rpc (index-rebuild : Int64)
  (engine-rebuild-index! (engine!)))

;; ---- clipboard ----------------------------------------------------------

(define-rpc (clipboard-record [text String] : String)
  (define store (engine-clipboard (engine!)))
  (if (and store (settings-get (settings!) 'clipboard-enabled))
      (let ([item (clipboard-record! store text)])
        (if item (clipboard-item-id item) ""))
      ""))

(define-rpc (clipboard-history [query String] : (List (List String)))
  (define store (engine-clipboard (engine!)))
  (if store
      (for/list ([item (in-list (if (string=? (string-trim query) "")
                                    (clipboard-list store 25)
                                    (clipboard-search store query)))])
        (define preview
          (let ([text (string-replace (clipboard-item-text item) "\n" " ")])
            (if (> (string-length text) 200)
                (string-append (substring text 0 200) "…")
                text)))
        (list (clipboard-item-id item)
              preview
              (if (clipboard-item-pinned? item) "pinned" "")
              "Clipboard"
              (clipboard-item-id item)
              "clipboard"
              ""
              ""))
      '()))

(define-rpc (clipboard-clear : Int64)
  (define store (engine-clipboard (engine!)))
  (if store (clipboard-clear! store) 0))

;; ---- snippets -----------------------------------------------------------

(define-rpc (snippet-list : (List (List String)))
  (define store (engine-snippets (engine!)))
  (if store
      (for/list ([s (in-list (snippet-list store))])
        (list (snippet-id s) (snippet-name s) (snippet-keyword s)
              (snippet-text s) "snippet" (snippet-id s) "" ""))
      '()))

(define-rpc (snippet-save [id String] [name String] [keyword String] [text String] : String)
  (define store (engine-snippets (engine!)))
  (if store
      (snippet-id (snippet-save! store name text keyword
                                 (if (string=? id "") #f id)))
      ""))

(define-rpc (snippet-delete [id String] : Bool)
  (define store (engine-snippets (engine!)))
  (if store (snippet-delete! store id) #f))

;; ---- settings -----------------------------------------------------------

(define (coerce-setting-value key value)
  (case key
    [(max-results clipboard-limit plugins-timeout-ms)
     (define n (string->number (string-trim value)))
     (if n n (raise-argument-error 'settings-set "numeric string" value))]
    [(clipboard-enabled web-search-enabled plugins-enabled)
     (cond
       [(member (string-trim value) '("true" "1")) #t]
       [(member (string-trim value) '("false" "0")) #f]
       [else (raise-argument-error 'settings-set "boolean string" value)])]
    [else value]))

(define-rpc (settings-list : (List (List String)))
  (for/list ([entry (in-list (settings-list (settings!)))])
    (list (settings-entry-key entry)
          (settings-entry-value entry)
          (settings-entry-description entry)
          "settings"
          (settings-entry-key entry)
          "setting"
          ""
          "")))

(define-rpc (settings-set [key String] [value String] : Bool)
  (define sym (string->symbol key))
  (settings-set! (settings!) sym (coerce-setting-value sym value))
  ;; Reflect the two keys the host renders directly.
  (case sym
    [(theme) (state-set! theme (settings-get (settings!) 'theme))]
    [(hotkey) (state-set! hotkey (settings-get (settings!) 'hotkey))])
  #t)

;; ---- plugins ------------------------------------------------------------

(define-rpc (plugins-list : (List (List String)))
  (define manager (engine-plugins (engine!)))
  (if manager
      (append
       (for/list ([p (in-list (plugin-manager-plugins manager))])
         (list (plugin-id p) (plugin-name p) (plugin-version p)
               (format "~a" (length (plugin-commands p)))
               (plugin-id p) "plugin" "" ""))
       (for/list ([error (in-list (plugin-manager-errors manager))])
         (list "" error "" "Plugin" "" "plugin" "" "")))
      '()))

(define-rpc (plugins-reload : Void)
  (define manager (engine-plugins (engine!)))
  (when manager (plugin-manager-reload! manager)))

;; ---- updates ------------------------------------------------------------

(define-rpc (update-check : String)
  (define status
    (fulcrum-update-check app-version (settings-get (settings!) 'update-base-url)))
  (when (string-prefix? status "update available")
    (update-available status))
  status)

;; ---- lifecycle ----------------------------------------------------------

(define (start in-fd out-fd)
  (ensure-data-dir!)
  (define manager (make-settings-manager (settings-path)))
  (define clip-store
    (and (settings-get manager 'clipboard-enabled)
         (make-clipboard-store (clipboard-path)
                               #:limit (settings-get manager 'clipboard-limit))))
  (define snip-store (make-snippet-store (snippets-path)))
  (define plug-mgr
    (and (settings-get manager 'plugins-enabled)
         (make-plugin-manager (plugins-dir)
                              #:timeout-ms (settings-get manager 'plugins-timeout-ms))))
  (define engine
    (make-engine #:clipboard-store clip-store
                 #:snippet-store snip-store
                 #:plugin-manager plug-mgr
                 #:max-results (settings-get manager 'max-results)))
  (engine-rebuild-index! engine)
  (current-settings manager)
  (current-engine engine)
  (state-set! theme (settings-get manager 'theme))
  (state-set! hotkey (settings-get manager 'hotkey))
  (serve-fds in-fd out-fd))
