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

(require json
         racket/file
         racket/format
         racket/list
         racket/string
         (prefix-in rivet-info: rivet/app-info)
         rivet/backend
         "core/ai.rkt"
         "core/apps.rkt"
         "core/clipboard.rkt"
         "core/engine.rkt"
         "core/fuzzy.rkt"
         "core/gallery.rkt"
         "core/paths.rkt"
         "core/plugins.rkt"
         "core/quicklinks.rkt"
         (rename-in "core/settings.rkt" [settings-list core:settings-list])
         (rename-in "core/snippets.rkt" [snippet-list core:snippet-list])
         "update.rkt")

(provide start
         current-engine
         current-settings
         app-version
         rows-for
         settings-act!
         ai-rows
         ai-ask-row
         ai-copy-last-answer
         ai-effective-provider
         current-ai-history
         current-ai-last-answer
         plugins-disabled-ids
         plugin-detail-rows
         run-action)

;; Staged and packaged apps carry the true version in rivet-app-info.rktd
;; (written by `raco rivet build`). Headless tests have no stage, so fall
;; back to the literal — which must track rivet.rktd. This value feeds the
;; update check: drift here means every install believes it is outdated
;; (0.2.0 shipped believing it was 0.1.0).
(define app-version
  (with-handlers ([exn:fail? (lambda (_) "0.3.0")])
    (string-append (rivet-info:app-version))))

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

;; Queries that name a backend surface outright ("ai", "settings") put
;; those rows first — twelve fuzzy app hits must not bury the settings
;; list below the fold.
(define backend-surface-words '("ai" "settings" "quicklinks" "links" "gallery" "plugins"))

(define (rows-for engine query)
  (define rows (engine-search engine query))
  (define filtered
    (if (settings-get (settings!) 'web-search-enabled)
        rows
        (filter (lambda (row) (not (string=? (list-ref row 3) "Web Search")))
                rows)))
  (define backend-rows
    (let ([pc (plugin-center-rows query)]
          [sr (settings-rows query)]
          [ar (append (ai-rows query) (ai-ask-row query))])
      ;; The surface the query names leads its own rows.
      (case (string-trim (string-downcase query))
        [("plugins" "plugin") (append pc sr ar)]
        [("ai") (append ar sr pc)]
        [("settings") (append sr ar pc)]
        [else (append sr ar pc)])))
  (if (member (string-trim (string-downcase query)) backend-surface-words)
      (append backend-rows filtered)
      (append filtered backend-rows)))

;; ---- settings-as-rows ----------------------------------------------------
;;
;; The hosts have no settings surface yet, so the launcher itself is the
;; settings UI: query `settings` (or a key/description fuzzy match) lists
;; every managed key with its current value as the badge; running a row
;; cycles or toggles the value and notifies the new one.

(define managed-setting-keys
  '(theme max-results clipboard-enabled web-search-enabled plugins-enabled ai-provider))

(define max-results-cycle '(8 12 16 20 25))

(define (next-setting-value key current)
  (case key
    [(theme)
     (cond [(string=? current "system") "light"]
           [(string=? current "light") "dark"]
           [else "system"])]
    [(max-results)
     (let* ([cycle max-results-cycle]
            [pos (index-of cycle current)])
       (if pos (list-ref cycle (modulo (add1 pos) (length cycle))) 12))]
    [(ai-provider)
     (let* ([cycle ai-providers]
            [pos (index-of cycle current)])
       (if pos (list-ref cycle (modulo (add1 pos) (length cycle))) ""))]
    [else (not current)]))

(define (setting-badge value)
  (cond [(boolean? value) (if value "on" "off")]
        [else (format "~a" value)]))

(define (settings-rows query)
  (define s (settings!))
  (for/list ([key (in-list managed-setting-keys)]
             #:when (fuzzy-score-fields
                     (string-trim query)
                     (list (cons 1.0 (symbol->string key))
                           (cons 0.7 "settings setting")
                           (cons 0.3 (format "~a" (settings-get s key))))))
    (define value (settings-get s key))
    (list "settings.set"
          (format "~a" key)
          (case key
            [(theme) "UI theme · select to cycle system → light → dark"]
            [(max-results) "Maximum results shown · select to cycle"]
            [(ai-provider) "BYOK AI provider · select to cycle empty → openai → anthropic → ollama"]
            [else "Select to toggle"])
          "Setting"
          (symbol->string key)
          "setting" ""
          (setting-badge value))))

(define (settings-act! key)
  (define sym (string->symbol key))
  (if (member sym managed-setting-keys)
      (let ([next (next-setting-value sym (settings-get (settings!) sym))])
        (settings-set! (settings!) sym next)
        (case sym
          [(theme) (state-set! theme (settings-get (settings!) 'theme))])
        (cons "ok" (list (cons 'notify (format "~a = ~a" sym next)))))
      (cons (format "unknown setting: ~a" key) '())))

;; Comma-separated settings string ↔ the disabled-id set the loader wants.
(define (plugins-disabled-ids)
  (filter non-empty-string?
          (map string-trim (string-split
                            (settings-get (settings!) 'plugins-disabled) ","))))

(define (set-plugins-disabled! ids)
  (settings-set! (settings!) 'plugins-disabled (string-join ids ",")))

;; ---- BYOK AI -------------------------------------------------------------
;;
;; Like the settings rows, AI lives at the backend level: it needs the
;; settings manager and the key file, which the engine never sees. Rows
;; appear instantly (no network in search); running one makes the
;; provider call and copies the answer to the clipboard.

(define (ai-effective-provider)
  (settings-get (settings!) 'ai-provider))

(define (ai-effective-model)
  (define model (settings-get (settings!) 'ai-model))
  (if (non-empty-string? model)
      model
      (default-ai-model (ai-effective-provider))))

(define (ai-effective-base-url)
  (define url (settings-get (settings!) 'ai-base-url))
  (if (non-empty-string? url)
      url
      (default-ai-base-url (ai-effective-provider))))

(define (ai-row id title subtitle arg badge)
  (list id title subtitle "AI" arg "sparkles" "" badge))

;; Conversation memory and the last answer live for the backend session
;; only — the clipboard answer is still the primary hand-off.
(define current-ai-history (make-parameter '()))
(define current-ai-last-answer (make-parameter ""))

(define (ai-copy-last-answer)
  (define answer (current-ai-last-answer))
  (if (non-empty-string? answer)
      (cons "copied" (list (cons 'copy-to-clipboard answer)))
      (cons "no AI answer yet" '())))

(define (ai-rows query)
  (define trimmed (string-trim query))
  (define lowered (string-downcase trimmed))
  (if (not (or (string=? lowered "ai") (string-prefix? lowered "ai ")))
      '()
      (let* ([rest (if (string=? lowered "ai")
                       ""
                       (string-trim (substring trimmed 3)))]
             [provider (ai-effective-provider)]
             [status (ai-configured-status
                      provider (ai-get-key (ai-keys-path) provider))])
        (cond
          ;; "ai key <secret>" — the one-line onboarding row.
          [(string-prefix? lowered "ai key")
           (define secret
             (if (> (string-length trimmed) 7)
                 (string-trim (substring trimmed 7))
                 ""))
           (if (non-empty-string? secret)
               (list (ai-row "ai.key"
                             "Save AI API key"
                             "stored in ai-keys.json on this machine only · never synced"
                             secret "Save"))
               (list (ai-row "ai.key"
                             "Save an AI API key"
                             "ai key <your-secret> · get one from your provider"
                             "" "")))]
          ;; Bare "ai": setup status / verb cheatsheet.
          [(string=? rest "")
           (if (equal? status "ready")
               (append
                (if (non-empty-string? (current-ai-last-answer))
                    (list (ai-row "ai.copy"
                                  (format "Copy last answer: ~a…"
                                          (substring (current-ai-last-answer)
                                                     0 (min 60 (string-length
                                                               (current-ai-last-answer)))))
                                  "your previous AI answer"
                                  (current-ai-last-answer) "Answer"))
                    '())
                (list (ai-row "ai.help"
                              (format "AI ready — ~a · ~a" provider (ai-effective-model))
                              "ai summarize · ai clean · ai translate <lang> · ai explain · ai chat <msg> · ai <question>"
                              "" "ready")))
               (list (ai-row "ai.help"
                             "AI needs setup"
                             (format "~a · run: ai key <your-api-key>, then settings → ai-provider"
                                     status)
                             "" "setup")))]
          ;; Everything else is a run row. No network during search.
          [else
           (define title
             (cond
               [(string-prefix? lowered "summarize") "Summarize the clipboard"]
               [(string-prefix? lowered "clean") "Clean up the clipboard text"]
               [(string-prefix? lowered "translate")
                (define target (string-trim (substring trimmed 14)))
                (format "Translate the clipboard → ~a"
                        (if (non-empty-string? target) target "English"))]
               [(string-prefix? lowered "explain") "Explain, with the clipboard as context"]
               [else (format "Ask AI: ~a" rest)]))
           (list (ai-row "ai.run" title
                         (format "↵ runs on ~a · the answer copies to your clipboard"
                                 (if (equal? status "ready")
                                     (format "~a · ~a" provider (ai-effective-model))
                                     status))
                         rest "AI"))]))))

;; Natural questions (config "…?") deserve an AI row without the ai
;; prefix — only when the user has AI configured, never otherwise.
(define (ai-ask-row query)
  (define trimmed (string-trim query))
  (define lowered (string-downcase trimmed))
  (define status
    (ai-configured-status
     (ai-effective-provider) (ai-get-key (ai-keys-path) (ai-effective-provider))))
  (if (and (equal? status "ready")
           (not (string-prefix? lowered "ai "))
           (not (string=? lowered "ai"))
           (>= (string-length trimmed) 8)
           (string-suffix? trimmed "?"))
      (list (ai-row "ai.run"
                    (format "Ask AI: ~a" trimmed)
                    "↵ asks; the answer copies to your clipboard"
                    trimmed "AI"))
      '()))

(define (ai-newest-clipboard-text engine)
  (define store (engine-clipboard engine))
  (if store
      (let ([items (clipboard-list store 1)])
        (if (pair? items) (clipboard-item-text (car items)) ""))
      ""))

;; The AI run action, flat on purpose: one provider call, the answer
;; lands in the clipboard, chat mode threads the session history.
(define (ai-run! engine arg)
  (define provider (ai-effective-provider))
  (define status
    (ai-configured-status provider (ai-get-key (ai-keys-path) provider)))
  (cond
    [(not (equal? status "ready")) (cons status '())]
    ;; Clipboard verbs need something on the clipboard; refusing here
    ;; keeps a typo from firing a provider call with empty input.
    [(and (for/or ([v (in-list '("summarize" "clean" "translate" "explain"))])
            (string-prefix? arg v))
          (string=? (string-trim (ai-newest-clipboard-text engine)) ""))
     (cons "nothing on the clipboard to work on" '())]
    [else
     (define chat? (string-prefix? arg "chat"))
     (define prompt
       (if chat?
           (string-trim (substring arg 4))
           (build-ai-prompt arg (ai-newest-clipboard-text engine))))
     (define history (if chat? (current-ai-history) '()))
     (define answer
       (ai-request provider (ai-effective-base-url)
                   (ai-get-key (ai-keys-path) provider)
                   (ai-effective-model) prompt #:history history))
     (if (string-prefix? answer "AI ")
         ;; Error strings from ai-request all start with "AI ".
         (cons answer '())
         (begin
           (current-ai-last-answer answer)
           (when chat?
             (current-ai-history
              (ai-history-append (current-ai-history)
                                 (string-trim (substring arg 4))
                                 answer)))
           (cons "copied" (list (cons 'copy-to-clipboard answer)))))]))

(define (ai-act! engine id arg)
  (case (string->symbol id)
    [(ai.key)
     (if (non-empty-string? (string-trim arg))
         (let ([provider (ai-effective-provider)])
           (if (string=? provider "")
               (cons "set ai-provider first (settings → ai-provider)" '())
               (begin
                 (ai-save-key! (ai-keys-path) provider (string-trim arg))
                 (cons "ok" (list (cons 'notify
                                        (format "AI key saved for ~a (local only)" provider)))))))
         (cons "empty key" '()))]
    [(ai.help)
     (cons "ok" (list (cons 'notify "ai summarize · ai clean · ai translate <lang> · ai explain · ai <question>")))]
    [(ai.run) (ai-run! engine arg)]
    [(ai.copy) (ai-copy-last-answer)]
    [(ai.reset)
     (current-ai-history '())
     (current-ai-last-answer "")
     (cons "ok" (list (cons 'notify "AI conversation reset")))]
    [else (cons (format "unknown ai action: ~a" id) '())]))

;; ---- plugin center actions ----------------------------------------------

;; Third-party plugins come from an arbitrary source folder; the
;; destination id is the folder's declared plugin id (never the folder
;; name), so a spoofed folder name cannot escape the plugins directory.
(define (plugins-install-from! source)
  (define manifest-path (build-path source "manifest.json"))
  (cond
    [(not (directory-exists? source))
     (cons (format "no such directory: ~a" source) '())]
    [(not (file-exists? manifest-path))
     (cons "source has no manifest.json" '())]
    [else
     (define id
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (hash-ref (string->jsexpr (file->string manifest-path)) 'id #f)))
     (cond
       [(not (string? id))
        (cons "manifest has no id" '())]
       [(regexp-match? #px"^[a-z0-9][a-z0-9-]*$" id)
        (define dest (build-path (plugins-dir) (string->path id)))
        (cond
          [(directory-exists? dest)
           (cons (format "already installed: ~a" id) '())]
          [else
           (with-handlers ([exn:fail?
                            (lambda (e)
                              (cons (format "install failed: ~a" (exn-message e)) '()))])
             (copy-directory/files source dest)
             (when (engine-plugins (engine!))
               (plugin-manager-reload! (engine-plugins (engine!))))
             (cons "ok" (list (cons 'notify (format "Plugin installed: ~a" id)))))])]
       [else (cons (format "manifest id is not installable: ~a" id) '())])]))

(define (plugins-act! engine id arg)
  (case (string->symbol id)
    [(plugins.toggle)
     (define ids (plugins-disabled-ids))
     (define disabled? (member arg ids))
     (define next
       (if disabled?
           (filter (lambda (x) (not (string=? x arg))) ids)
           (append ids (list arg))))
     (set-plugins-disabled! next)
     (when (engine-plugins engine)
       (plugin-manager-reload! (engine-plugins engine)))
     (cons "ok" (list (cons 'notify
                            (format "~a ~a"
                                    (if disabled? "Enabled" "Disabled") arg))))]
    [(plugins.install)
     (if (non-empty-string? (string-trim arg))
         (plugins-install-from! (string->path (string-trim arg)))
         (cons "no path given" '()))]
    [(plugins.uninstall)
     ;; Explicit user intent from the center: any plugin directory goes,
     ;; gallery-owned or user-installed.
     (cond
       [(not (regexp-match? #px"^[a-z0-9][a-z0-9-]*$" arg))
        (cons (format "invalid plugin id: ~a" arg) '())]
       [else
        (define dir (build-path (plugins-dir) (string->path arg)))
        (if (directory-exists? dir)
            (with-handlers ([exn:fail?
                             (lambda (e)
                               (cons (format "uninstall failed: ~a" (exn-message e)) '()))])
              (delete-directory/files dir)
              (when (engine-plugins engine)
                (plugin-manager-reload! (engine-plugins engine)))
              (cons "ok" (list (cons 'notify (format "Uninstalled ~a" arg)))))
            (cons (format "not installed: ~a" arg) '()))])]
    [else (cons (format "unknown plugin action: ~a" id) '())]))

;; ---- plugin center -------------------------------------------------------
;;
;; The launcher IS the plugin center: query `plugins` lists every
;; installed plugin with an enable/disable toggle, a row that reveals the
;; plugins directory, and — via the gallery rows underneath — one-click
;; install for everything not yet installed. `install plugin <path>`
;; copies a third-party plugin folder into place.

;; Detail view: `plugins <name>` where the text names one installed
;; plugin (or one catalog entry) expands what a marketplace page would
;; show — every command with a copyable usage example, the permission
;; declarations, and the category. Transparency is the trust story.
(define (plugin-detail-rows text)
  (define manager (engine-plugins (engine!)))
  (define installed
    (if manager
        (for/list ([p (in-list (plugin-manager-plugins manager))]
                   #:when (string-contains?
                           (string-downcase (plugin-name p))
                           (string-downcase text)))
          p)
        '()))
  (define catalog-hit
    (findf (lambda (e)
             (or (string-ci=? (gallery-entry-name e) text)
                 (string-ci=? (gallery-entry-id e) text)))
           (gallery-catalog)))
  (define entry
    (or (and (= (length installed) 1)
             (findf (lambda (e)
                      (string-ci=? (gallery-entry-id e)
                                   (plugin-id (car installed))))
                    (gallery-catalog)))
        catalog-hit))
  (if (not entry)
      '()
      (let* ([raw (gallery-entry-raw entry)]
             [detail
              (list (list "noop"
                          (format "~a v~a" (gallery-entry-name entry)
                                  (gallery-entry-version entry))
                          (format "~a · by ~a"
                                  (gallery-entry-description entry)
                                  (hash-ref raw 'author "unknown"))
                          "Plugin" (gallery-entry-id entry) "plugin" ""
                          (hash-ref raw 'category "plugin")))]
             [commands-raw
              (let ([cs (hash-ref raw 'commands #f)])
                (if (list? cs) cs '()))]
             [command-rows
              (for/list ([c (in-list commands-raw)]
                         #:when (and (hash? c) (string? (hash-ref c 'keyword #f))))
                (define example (hash-ref c 'example #f))
                (if (string? example)
                    (list "plugins.example"
                          (format "~a · ~a" (hash-ref c 'keyword)
                                  (hash-ref c 'name "command"))
                          (format "~a · ↵ copies the example, paste to run"
                                  (hash-ref c 'description ""))
                          "Plugin" example "plugin" "" "Try it")
                    (list "noop"
                          (format "~a · ~a" (hash-ref c 'keyword)
                                  (hash-ref c 'name "command"))
                          (hash-ref c 'description "")
                          "Plugin" "" "plugin" "" "")))]
             [perms (gallery-entry-permissions entry)]
             [permission-row
              (if (null? perms)
                  (list (list "noop"
                              "Permissions: none declared"
                              "this plugin declares no capabilities"
                              "Plugin" "" "plugin" "" ""))
                  (list (list "noop"
                              (format "Permissions: ~a" (string-join perms ", "))
                              "declared by the plugin's manifest"
                              "Plugin" "" "plugin" "" "")))])
        (append detail command-rows permission-row))))

(define (plugin-center-rows query)
  (define trimmed (string-trim query))
  (define lowered (string-downcase trimmed))
  (cond
    [(string-prefix? lowered "install plugin ")
     (define path (string-trim (substring trimmed 15)))
     (if (non-empty-string? path)
         (list (list "plugins.install"
                     "Install plugin from folder"
                     (format "↵ copies ~a into Fulcrum's plugins directory" path)
                     "Plugin" path "plugin" "" "Install"))
         '())]
    [(and (or (string-prefix? lowered "plugins ")
              (string-prefix? lowered "plugin "))
          (>= (string-length trimmed) 8))
     ;; Text after "plugins": the detail view when it names one plugin,
     ;; otherwise filter the installed toggles by name.
     (define text (string-trim (substring trimmed 8)))
     (define detail (plugin-detail-rows text))
     (if (not (null? detail))
         detail
         (let ([manager (engine-plugins (engine!))])
           (if (not manager)
               '()
               (for/list ([p (in-list (plugin-manager-plugins manager))]
                          #:when (string-contains?
                                  (string-downcase (plugin-name p))
                                  (string-downcase text)))
                 (define id (plugin-id p))
                 (define on? (not (member id (plugins-disabled-ids))))
                 (list "plugins.toggle"
                       (if on? (format "Disable ~a" (plugin-name p))
                           (format "Enable ~a" (plugin-name p)))
                       (format "v~a" (plugin-version p))
                       "Plugin" id "plugin" ""
                       (if on? "Enabled" "Disabled"))))))]
    [else
     (define manager (engine-plugins (engine!)))
     (if (not manager)
         '()
         (let* ([disabled (plugins-disabled-ids)]
                [toggle-row
                 (lambda (p)
                   (define id (plugin-id p))
                   (define on? (not (member id disabled)))
                   (list "plugins.toggle"
                         (if on?
                             (format "Disable ~a" (plugin-name p))
                             (format "Enable ~a" (plugin-name p)))
                         (format "v~a · ~a"
                                 (plugin-version p)
                                 (string-join
                                  (for/list ([c (in-list (plugin-commands p))])
                                    (plugin-command-keyword c))
                                  " · "))
                         "Plugin" id "plugin" ""
                         (if on? "Enabled" "Disabled")))])
           (cons (list "file.open"
                       "Open plugins directory"
                       (path->string (plugins-dir))
                       "Plugin" (path->string (plugins-dir)) "plugin" "" "Open")
                 (map toggle-row (plugin-manager-plugins manager)))))]))

;; ---- RPCs ---------------------------------------------------------------

(define-rpc (health : String)
  (format "fulcrum ~a apps=~a" app-version (engine-app-count (engine!))))

(define-rpc (search [query String] : (List (List String)))
  (rows-for (engine!) query))

(define-rpc (run-action [id String] [arg String] : String)
  ;; Settings and AI rows are backend-owned (the engine holds no settings
  ;; or keys), so they route here before the engine.
  (define outcome
    (cond
      [(string-prefix? id "settings.") (settings-act! arg)]
      [(string-prefix? id "ai.") (ai-act! (engine!) id arg)]
      [(string=? id "plugins.example")
       ;; Copying a usage example: the panel hides and the example sits
       ;; on the clipboard, ready to paste into a fresh query.
       (cons "copied" (list (cons 'copy-to-clipboard arg)))]
      [(string-prefix? id "plugins.") (plugins-act! (engine!) id arg)]
      [else (engine-run (engine!) id arg)]))
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
      (for/list ([s (in-list (core:snippet-list store))])
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
  (for/list ([entry (in-list (core:settings-list (settings!)))])
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
  (define snip-store
    (make-snippet-store (snippets-path)
                        #:sync-root (or (sync-root-override)
                                        (settings-get manager 'sync-root))))
  (define link-store
    (make-quicklink-store (quicklinks-path)
                          #:sync-root (or (sync-root-override)
                                          (settings-get manager 'sync-root))))
  (define plug-mgr
    (and (settings-get manager 'plugins-enabled)
         (make-plugin-manager (plugins-dir)
                              #:timeout-ms (settings-get manager 'plugins-timeout-ms)
                              #:disabled-thunk plugins-disabled-ids)))
  (define engine
    (make-engine #:clipboard-store clip-store
                 #:snippet-store snip-store
                 #:quicklink-store link-store
                 #:plugin-manager plug-mgr
                 #:max-results (settings-get manager 'max-results)))
  (engine-rebuild-index! engine)
  (current-settings manager)
  (current-engine engine)
  (state-set! theme (settings-get manager 'theme))
  (state-set! hotkey (settings-get manager 'hotkey))
  (serve-fds in-fd out-fd))
