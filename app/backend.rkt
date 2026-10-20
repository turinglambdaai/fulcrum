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
         "core/store.rkt"
         (rename-in "core/settings.rkt" [settings-list core:settings-list])
         (rename-in "core/snippets.rkt" [snippet-list core:snippet-list])
         "update.rkt")

(provide start
         boot!
         current-engine
         current-settings
         app-version
         rows-for
         settings-act!
         ai-rows
         ai-ask-row
         ai-copy-last-answer
         ai-effective-provider
         ai-history
         ai-last-answer
         ai-set-history!
         ai-set-last-answer!
         ai-restore-memory!
         plugins-disabled-ids
         plugin-detail-rows
         row-actions-for
         plugin-detail-for
         plugin-pref-current-value
         plugin-pref-spec
         plugin-set-rows
         app-roots-fingerprint-cache
         refresh-app-index-if-stale!
         rebuild-app-index!
         run-action)

;; Staged and packaged apps carry the true version in rivet-app-info.rktd
;; (written by `raco rivet build`). Headless tests have no stage, so fall
;; back to the literal — which must track rivet.rktd. This value feeds the
;; update check: drift here means every install believes it is outdated
;; (0.2.0 shipped believing it was 0.1.0).
(define app-version
  (with-handlers ([exn:fail? (lambda (_) "0.13.1")])
    (string-append (rivet-info:app-version))))

;; The updater learns the running version from here (the packaged app reads
;; rivet-app-info.rktd, headless tests parameterize it directly).
(current-update-version app-version)

;; ---- States -------------------------------------------------------------

(define-state theme : String "system")
(define-state hotkey : String "alt+space")
(define-state language : String "zh")
(define-state version : String app-version)

;; ---- Events -------------------------------------------------------------

(define-event notify : String)
(define-event copy-to-clipboard : String)
(define-event open-url : String)
(define-event update-available : String)
;; The host writes the pasteboard, hides the panel, and synthesizes the
;; platform paste keystroke into the previously frontmost app.
(define-event paste-to-frontmost : String)
;; Streaming finished successfully: the full answer also lands here so
;; hosts can fill the clipboard without hiding the panel (the user is
;; reading it).
(define-event ai-finished : String)

;; ---- update records ------------------------------------------------------
;;
;; Wire DTOs for the updater (the family shape taskly ships). Optional
;; fields travel as null when unfilled; hosts decode them as nil/null.

;; Result of update-check. status: "available" | "up-to-date" | "error" |
;; "throttled"; version/build/published-at/installer/size-bytes are only
;; filled for "available".
(define-record UpdateCheck
  ([status : String]
   [error : (Optional String)]
   [current-version : String]
   [available-version : (Optional String)]
   [build : (Optional Int64)]
   [published-at : (Optional String)]
   [installer : (Optional String)]
   [size-bytes : (Optional Int64)]))

;; Polled by the host while a download runs. phase: idle | checking |
;; downloading | downloaded | error. `downloaded-path` names the verified
;; installer under <data-dir>/updates once phase reaches "downloaded".
(define-record UpdateState
  ([phase : String]
   [percent : Int64]
   [message : (Optional String)]
   [downloaded-path : (Optional String)]
   [available-version : (Optional String)]))

;; Live AI answer wire shape. `text` is the answer so far while running and
;; the full answer when done; `error` is filled only for phase "error".
(define-record AiStream
  ([phase : String]
   [text : String]
   [error : (Optional String)]))

;; FPP2 plugin detail payload: plain text plus key-value pairs, rendered
;; natively by every host (no WebView, no markdown in v2.0).
(define-record DetailView
  ([text : String]
   [metadata : (List (List String))]))

;; The live answer itself: the streaming request runs on a backend thread
;; and pushes phase running → done|error through this State; hosts render
;; the text as it grows. phase: idle | running | done | error.
(define-state ai-stream : AiStream (AiStream "idle" "" (void)))

;; Bumped whenever backend-side data changed in a way that should refresh
;; the on-screen rows without new user input — currently FPP2 daemon
;; results-changed pushes. Hosts re-run the current query when it moves.
(define-state search-revision : Int64 0)

(define search-revision-box (box 0))

(define (bump-search-revision!)
  (set-box! search-revision-box (add1 (unbox search-revision-box)))
  (with-handlers ([exn:fail? void])
    (state-set! search-revision (unbox search-revision-box))))

(define (nullable value)
  (if value value (void)))

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
      [(paste-to-frontmost) (paste-to-frontmost (cdr entry))]
      [(open-url) (open-url (cdr entry))]
      [else (notify (format "~a" entry))])))

;; Queries that name a backend surface outright ("ai", "settings", "update")
;; put those rows first — twelve fuzzy app hits must not bury the settings
;; list below the fold.
(define backend-surface-words
  '("ai" "about" "settings" "quicklinks" "links" "gallery" "plugins"
    "update" "updates"))

;; The one row every settings surface leads with: hosts map it to their
;; native settings window (the same delegation shape as about.open). The
;; query-syntax rows below it stay for people who prefer typing.
(define (settings-open-row)
  (list "settings.open"
        "Settings…"
        "Theme, hotkey, AI provider and key, sync, updates — in a window"
        "Setting" "" "setting" "" "Open"))

(define (settings-quick-rows)
  (cons
   (settings-open-row)
   (for/list ([key (in-list '(theme hotkey language ai-provider))])
     (define val (settings-get (settings!) key))
     (define label
       (case key
         [(theme) "Theme"]
         [(hotkey) "Hotkey"]
         [(language) "Language"]
         [(ai-provider) "AI Provider"]
         [else (format "~a" key)]))
     (list "settings.set"
           (format "~a  ·  ~a" label val)
           "↵ cycles to the next value"
           "Setting"
           (symbol->string key)
           "setting" ""
           (format "~a" val)))))

;; ---- about-as-rows --------------------------------------------------------
;;
;; The launcher is also the About surface (the hosts have no dedicated
;; about menu on Windows/Linux): query `about` lists one row each host
;; maps to its native about panel — version, website, feedback, license.

(define (about-rows query)
  (define trimmed (string-trim query))
  (if (or (member (string-downcase trimmed) '("about" "about fulcrum"))
          (fuzzy-score-fields
           trimmed
           (list (cons 1.0 "about")
                 (cons 0.5 "version license website feedback"))))
      (list (list "about.open"
                  "About Fulcrum"
                  (format "v~a · website, feedback and license" app-version)
                  "About" "" "about" "" ""))
      '()))

(define (rows-for engine query)
  (define rows (engine-search engine query))
  ;; Discoverability: an empty query always shows a Settings row so the
  ;; user can find the settings without knowing to type "settings".
  (define settings-entry
    (if (string=? (string-trim query) "")
        (settings-quick-rows)
        '()))
  (define filtered
    (if (settings-get (settings!) 'web-search-enabled)
        rows
        (filter (lambda (row) (not (string=? (list-ref row 3) "Web Search")))
                rows)))
  (define backend-rows
    (let ([pc (plugin-center-rows query)]
          [sr (settings-rows query)]
          [ar (append (ai-rows query) (ai-ask-row query))]
          [ur (update-rows query)]
          [ab (about-rows query)])
      ;; The surface the query names leads its own rows.
      (case (string-trim (string-downcase query))
        [("about") (append ab sr ar pc ur)]
        [("plugins" "plugin") (append pc sr ar ur ab)]
        [("ai") (append ar sr pc ur ab)]
        [("update" "updates") (append ur sr ar pc ab)]
        [("settings") (append sr ar pc ur ab)]
        [else (append sr ar pc ur ab)])))
  (append settings-entry
    (if (member (string-trim (string-downcase query)) backend-surface-words)
      (append backend-rows filtered)
      (append filtered backend-rows))))

;; ---- settings-as-rows ----------------------------------------------------
;;
;; The hosts have no settings surface yet, so the launcher itself is the
;; settings UI: query `settings` (or a key/description fuzzy match) lists
;; every managed key with its current value as the badge; running a row
;; cycles or toggles the value and notifies the new one.

(define managed-setting-keys
  '(language theme hotkey max-results clipboard-enabled expansion-enabled web-search-enabled plugins-enabled ai-provider))

(define max-results-cycle '(8 12 16 20 25))

;; Presets the settings row cycles through — every entry passes the hotkey
;; grammar and registers on all three platforms.
(define hotkey-cycle '("alt+space" "ctrl+alt+space" "ctrl+shift+space" "alt+shift+space"))

(define (next-setting-value key current)
  (case key
    [(language)
     (cond [(string=? current "zh") "en"]
           [else "zh"])]
    [(theme)
     (cond [(string=? current "system") "light"]
           [(string=? current "light") "dark"]
           [else "system"])]
    [(hotkey)
     (let ([pos (index-of hotkey-cycle current)])
       (if pos (list-ref hotkey-cycle (modulo (add1 pos) (length hotkey-cycle)))
           (car hotkey-cycle)))]
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
  (define trimmed (string-trim query))
  (define key-rows
    (for/list ([key (in-list managed-setting-keys)]
               #:when (fuzzy-score-fields
                       trimmed
                       (list (cons 1.0 (symbol->string key))
                             (cons 0.7 "settings setting")
                             (cons 0.3 (format "~a" (settings-get s key))))))
      (define value (settings-get s key))
      (list "settings.set"
            (format "~a" key)
            (case key
              [(language) "UI language · select to toggle zh ↔ en (update dialogs follow it)"]
              [(theme) "UI theme · select to cycle system → light → dark"]
              [(hotkey) "Global hotkey · select to cycle alt+space → ctrl+alt+space → ctrl+shift+space → alt+shift+space"]
              [(max-results) "Maximum results shown · select to cycle"]
              [(ai-provider) "BYOK AI provider · select to cycle empty → openai → anthropic → ollama"]
              [else "Select to toggle"])
            "Setting"
            (symbol->string key)
            "setting" ""
            (setting-badge value))))
  ;; The window row leads whenever the query is about settings at all.
  (if (fuzzy-score-fields
       trimmed
       (list (cons 1.0 "settings") (cons 0.6 "preferences options configure")))
      (cons (settings-open-row) key-rows)
      key-rows))

(define (settings-act! key)
  (define sym (string->symbol key))
  (if (member sym managed-setting-keys)
      (let ([next (next-setting-value sym (settings-get (settings!) sym))])
        (settings-set! (settings!) sym next)
        (case sym
          [(theme) (state-set! theme (settings-get (settings!) 'theme))]
          [(hotkey) (state-set! hotkey (settings-get (settings!) 'hotkey))]
          [(language) (state-set! language (settings-get (settings!) 'language))])
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

;; Conversation memory and the last answer. Module-level boxes, NOT
;; parameters: every RVT1 request runs on its own worker thread, and a
;; parameter written in one worker is invisible to the next (this is also
;; why the old parameter-based chat memory never actually survived a
;; round-trip in production, while single-threaded tests stayed green).
;; The streaming thread and later RPCs share these; one semaphore guards
;; the pair against a concurrent reset.
(define ai-memory-lock (make-semaphore 1))
(define ai-history-box (box '()))
(define ai-last-answer-box (box ""))

(define (ai-history)
  (unbox ai-history-box))

(define (ai-last-answer)
  (unbox ai-last-answer-box))

;; Persistent memory (Raycast-2.0 "Memory" parity): the transcript and the
;; last answer survive restarts. The file is local-only by construction —
;; the same never-synced policy as ai-keys.json, because a transcript is
;; sensitive.
(define (ai-restore-memory!)
  (with-handlers ([exn:fail? void])
    (define raw (read-json-file (ai-memory-path) (hash)))
    (when (hash? raw)
      (define hist (hash-ref raw 'history '()))
      ;; JSON arrays come back as lists; memory stores pairs.
      (when (and (list? hist)
                 (andmap (lambda (e)
                           (and (list? e) (= (length e) 2)
                                (string? (list-ref e 0))
                                (string? (list-ref e 1))))
                         hist))
        (set-box! ai-history-box
                  (for/list ([e (in-list hist)])
                    (cons (list-ref e 0) (list-ref e 1)))))
      (define last (hash-ref raw 'last-answer #f))
      (when (string? last) (set-box! ai-last-answer-box last)))))

(define (ai-persist-memory!)
  ;; Memory stores pairs; JSON needs lists. (The swallow-on-failure here
  ;; once hid exactly this: pairs are not jsexpr, so nothing was ever
  ;; written and the "persistence" silently saved nothing.)
  (with-handlers ([exn:fail? void])
    (write-json-atomic!
     (ai-memory-path)
     (hasheq 'history (for/list ([e (in-list (ai-history))])
                        (list (car e) (cdr e)))
             'last-answer (ai-last-answer)))))

(define (ai-set-history! h)
  (set-box! ai-history-box h)
  (ai-persist-memory!))

(define (ai-set-last-answer! a)
  (set-box! ai-last-answer-box a)
  (ai-persist-memory!))

(define (ai-copy-last-answer)
  (define answer (ai-last-answer))
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
          ;; "ai undo" — drop the last chat exchange (the minimal
          ;; branching primitive: roll the conversation back to try a
          ;; different direction).
          [(string=? lowered "ai undo")
           (if (null? (ai-history))
               (list (ai-row "ai.undo" "Nothing to undo"
                             "the conversation has no exchanges yet" "" ""))
               (list (ai-row "ai.undo"
                             "Undo the last exchange"
                             (format "↵ drops ~a and retries from there"
                                     (let ([last (cdr (reverse (ai-history)))])
                                       (if (and (pair? last) (string? (cdar last)))
                                           (format "“~a”" (cdar last))
                                           "the last exchange"))))
                     "" ""))]
          ;; "ai persona <text…>" — persistent personalization: the text
          ;; rides a system message on every request.
          [(string-prefix? lowered "ai persona")
           (define value-part
             (string-trim (substring trimmed (min (string-length trimmed) 11))))
           (define current (settings-get (settings!) 'ai-persona))
           (if (non-empty-string? value-part)
               (list (ai-row "ai.persona"
                             (format "Set AI persona: ~a" value-part)
                             (format "↵ saves · current: ~a"
                                     (if (non-empty-string? current) current "none"))
                             value-part "Set"))
               (list (ai-row "ai.persona"
                             "Set the AI persona"
                             (format "ai persona <text…> · current: ~a"
                                     (if (non-empty-string? current) current "none"))
                             "" "")))]
          ;; "ai model <name>" — the one-line model setter (model names are
          ;; free-form, so a settings cycle does not fit).
          [(string-prefix? lowered "ai model")
           (define value-part
             (string-trim (substring trimmed (min (string-length trimmed) 9))))
           (if (non-empty-string? value-part)
               (list (ai-row "ai.model"
                             (format "Set AI model: ~a" value-part)
                             (format "↵ saves · current: ~a"
                                     (let ([m (settings-get (settings!) 'ai-model)])
                                       (if (non-empty-string? m) m "provider default")))
                             value-part "Set"))
               (list (ai-row "ai.model"
                             "Set the AI model"
                             (format "ai model <name> · current: ~a"
                                     (let ([m (settings-get (settings!) 'ai-model)])
                                       (if (non-empty-string? m) m "provider default")))
                             "" "")))]
          ;; Bare "ai": setup status / verb cheatsheet.
          [(string=? rest "")
           (if (equal? status "ready")
               (append
                (if (non-empty-string? (ai-last-answer))
                    (list (ai-row "ai.copy"
                                  (format "Copy last answer: ~a…"
                                          (substring (ai-last-answer)
                                                     0 (min 60 (string-length
                                                               (ai-last-answer)))))
                                  "your previous AI answer"
                                  (ai-last-answer) "Answer"))
                    '())
                (list (ai-row "ai.help"
                              (format "AI ready — ~a · ~a" provider (ai-effective-model))
                              "ai summarize · ai clean · ai translate <lang> · ai explain · ai chat <msg> · ai undo · ai persona <text> · ai model <name> · ai <question>"
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
                         (format "↵ runs on ~a · the answer streams here and copies to your clipboard"
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
                    "↵ asks; the answer streams here and copies to your clipboard"
                    trimmed "AI"))
      '()))

(define (ai-newest-clipboard-text engine)
  (define store (engine-clipboard engine))
  (if store
      (let ([items (clipboard-list store 1)])
        (if (pair? items) (clipboard-item-text (car items)) ""))
      ""))

;; The AI run action: validate, then hand the provider call to a backend
;; thread (ai-request-streaming) and return "started" immediately — the
;; answer streams to hosts through the ai-stream State and lands on the
;; clipboard via ai-finished when complete. run-action therefore never
;; blocks on a model.
(define ai-streaming? (box #f))

(define (start-ai-stream! chat? raw-arg prompt)
  (set-box! ai-streaming? #t)
  (state-set! ai-stream (AiStream "running" "" (void)))
  (define provider (ai-effective-provider))
  (define key (ai-get-key (ai-keys-path) provider))
  (define model (ai-effective-model))
  (define base-url (ai-effective-base-url))
  (define history (if chat? (ai-history) '()))
  ;; Delta pushes are State frames; throttle so a fast model cannot flood
  ;; the wire (150 ms is well under human reading latency).
  (define last-push (box 0.0))
  (thread
   (lambda ()
     (define answer
       (ai-request-streaming provider base-url key model prompt
                             #:history history
                             #:on-delta
                             (lambda (partial)
                               (define now (current-inexact-milliseconds))
                               (when (> (- now (unbox last-push)) 150)
                                 (set-box! last-push now)
                                 (with-handlers ([exn:fail? void])
                                   (state-set! ai-stream
                                               (AiStream "running" partial
                                                         (void))))))))
     (set-box! ai-streaming? #f)
     (cond
       ;; Error strings from ai-request-streaming all start with "AI ".
       [(string-prefix? answer "AI ")
        (with-handlers ([exn:fail? void])
          (state-set! ai-stream (AiStream "error" "" answer)))
        (notify answer)]
       [else
        (ai-set-last-answer! answer)
        (when chat?
          (ai-set-history!
           (ai-history-append history (string-trim (substring raw-arg 4)) answer)))
        (with-handlers ([exn:fail? void])
          (state-set! ai-stream (AiStream "done" answer (void))))
        (ai-finished answer)]))))

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
    [(unbox ai-streaming?)
     (cons "AI is already answering — wait for it or ask something new later" '())]
    [else
     (define chat? (string-prefix? arg "chat"))
     (define prompt
       (if chat?
           (string-trim (substring arg 4))
           (build-ai-prompt arg (ai-newest-clipboard-text engine))))
     (start-ai-stream! chat? arg prompt)
     (cons "started" '())]))

;; Drop the last chat exchange — the minimal branching primitive: roll
;; the conversation back to try a different direction.
(define (ai-undo-exchange!)
  (define hist (ai-history))
  (cond
    [(null? hist) (cons "nothing to undo" '())]
    [else
     (define kept
       (let loop ([h hist])
         (if (<= (length h) 2)
             '()
             (cons (car h) (loop (cdr h))))))
     (ai-set-history! kept)
     (ai-set-last-answer! "")
     (cons "ok" (list (cons 'notify "Undone: dropped the last exchange")))]))

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
    [(ai.undo) (ai-undo-exchange!)]
    [(ai.persona)
     (define text (string-trim arg))
     (cond
       [(not (non-empty-string? text))
        (cons "empty persona" '())]
       [(> (string-length text) 2048)
        (cons "persona too long (max 2048)" '())]
       [else
        (settings-set! (settings!) 'ai-persona text)
        (cons "ok" (list (cons 'notify "AI persona saved")))])]
    [(ai.model)
     (define name (string-trim arg))
     (cond
       [(not (non-empty-string? name))
        (cons "empty model name" '())]
       [(> (string-length name) 128)
        (cons "model name too long (max 128)" '())]
       [else
        (settings-set! (settings!) 'ai-model name)
        (cons "ok" (list (cons 'notify (format "AI model = ~a" name))))])]
    [(ai.help)
     (cons "ok" (list (cons 'notify "ai summarize · ai clean · ai translate <lang> · ai explain · ai model <name> · ai <question>")))]
    [(ai.run) (ai-run! engine arg)]
    [(ai.copy) (ai-copy-last-answer)]
    [(ai.paste)
     (define answer (ai-last-answer))
     (if (non-empty-string? answer)
         (cons "copied" (list (cons 'paste-to-frontmost answer)))
         (cons "no AI answer yet" '()))]
    [(ai.reset)
     (call-with-semaphore ai-memory-lock
       (lambda ()
         (ai-set-history! '())
         (ai-set-last-answer! "")))
     (cons "ok" (list (cons 'notify "AI conversation reset")))]
    [else (cons (format "unknown ai action: ~a" id) '())]))

;; ---- FPP2 plugin preferences ----------------------------------------------
;;
;; The manifest declares the schema; the backend stores the values and
;; injects them into every request (environment at spawn + the prefs
;; payload). Secret values live in their own local-only file — same policy
;; as ai-keys.json, never mirrored to sync.

(define (read-plugin-json path)
  (with-handlers ([exn:fail? (lambda (_) (hash))])
    (define raw (read-json-file path (hash)))
    (if (hash? raw) raw (hash))))

(define (plugin-by-id plugin-id)
  (findf (lambda (p) (string=? (plugin-id p) plugin-id))
         (plugin-manager-plugins (engine-plugins (engine!)))))

(define (plugin-pref-spec plugin-id pref-name)
  (define p (plugin-by-id plugin-id))
  (and p
       (findf (lambda (spec)
                (string=? (plugin-pref-name spec) pref-name))
              (plugin-preferences p))))

;; Current value for one preference: stored value, else the manifest
;; default. Booleans coerce to real booleans for the payload.
(define (plugin-pref-current-value plugin-id spec)
  (define stored
    (hash-ref (read-plugin-json (if (string=? (plugin-pref-type spec) "secret")
                                    (plugin-secrets-path)
                                    (plugin-prefs-path)))
              (string->symbol plugin-id)
              (hash)))
  (define raw
    (hash-ref stored
              (string->symbol (plugin-pref-name spec))
              (plugin-pref-default spec)))
  (if (string=? (plugin-pref-type spec) "boolean")
      (string=? raw "true")
      raw))

;; The manager's injection thunk: symbol name → jsexpr per plugin.
(define (plugin-prefs-for plugin-id)
  (with-handlers ([exn:fail? (lambda (_) (hash))])
    (define p (plugin-by-id plugin-id))
    (if (or (not p) (null? (plugin-preferences p)))
        (hash)
        (for/hash ([spec (in-list (plugin-preferences p))])
          (values (string->symbol (plugin-pref-name spec))
                  (plugin-pref-current-value plugin-id spec))))))

(define (plugin-pref-store! plugin-id spec value)
  (define path (if (string=? (plugin-pref-type spec) "secret")
                   (plugin-secrets-path)
                   (plugin-prefs-path)))
  (define file (read-plugin-json path))
  (define table (hash-ref file (string->symbol plugin-id) (hash)))
  (write-json-atomic!
   path
   (hash-set file (string->symbol plugin-id)
             (hash-set table (string->symbol (plugin-pref-name spec)) value))))

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
        (make-directory* (plugins-dir))
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
    [(plugin.pref.cycle)
     ;; Boolean/select preferences cycle right from the plugin center row.
     (define parts (string-split arg link-save-separator))
     (cond
       [(not (and (engine-plugins engine) (= (length parts) 2)))
        (cons "invalid plugin.pref.cycle payload" '())]
       [else
        (define spec (plugin-pref-spec (list-ref parts 0) (list-ref parts 1)))
        (cond
          [(not spec) (cons (format "no such preference: ~a" (list-ref parts 1)) '())]
          [else
           (define current (plugin-pref-current-value (list-ref parts 0) spec))
           (define next
             (cond
               [(string=? (plugin-pref-type spec) "boolean")
                (if current "false" "true")]
               [(string=? (plugin-pref-type spec) "select")
                (define choices (plugin-pref-choices spec))
                (define cur-str (if current (format "~a" current) ""))
                (define pos (index-of choices cur-str))
                (if pos
                    (list-ref choices (modulo (add1 pos) (length choices)))
                    (car choices))]
               [else (plugin-pref-default spec)]))
           (plugin-pref-store! (list-ref parts 0) spec
                               (if (boolean? next) next (format "~a" next)))
           (plugin-manager-prefs-changed! (engine-plugins engine)
                                          (list-ref parts 0))
           (cons "ok" (list (cons 'notify
                                  (format "~a = ~a"
                                          (plugin-pref-name spec)
                                          (if (boolean? next)
                                              (if next "true" "false")
                                              next)))))])])]
    [(plugin.set)
     ;; `plugin set <id> <pref> <value…>` — the editing idiom for free-text
     ;; and secret preferences (the query box is the only text entry).
     (define parts (string-split arg link-save-separator))
     (cond
       [(not (and (engine-plugins engine) (= (length parts) 3)))
        (cons "invalid plugin.set payload" '())]
       [else
        (define spec (plugin-pref-spec (list-ref parts 0) (list-ref parts 1)))
        (define value (list-ref parts 2))
        (cond
          [(not spec)
           (cons (format "no such preference: ~a" (list-ref parts 1)) '())]
          [(not (validate-plugin-pref-value spec value))
           (cons (format "invalid value for ~a (~a)"
                         (list-ref parts 1)
                         (plugin-pref-type spec))
                 '())]
          [else
           (plugin-pref-store! (list-ref parts 0) spec value)
           (plugin-manager-prefs-changed! (engine-plugins engine)
                                          (list-ref parts 0))
           (cons "ok" (list (cons 'notify
                                  (format "~a = ~a"
                                          (plugin-pref-name spec)
                                          (if (string=? (plugin-pref-type spec) "secret")
                                              "••••••"
                                              value)))))])])]
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
              (when (directory-exists? dir)
                (error 'plugins-uninstall "directory survived deletion: ~a" dir))
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
;; `plugin set <id> <pref> <value…>` — the one-line preference editor for
;; text and secret preferences (boolean/select cycle from their rows in
;; the plugin detail view). The value is everything after the pref name,
;; spaces included.
(define plugin-set-prefix "plugin set ")

(define (plugin-set-rows trimmed)
  (define rest (string-trim (substring trimmed (string-length plugin-set-prefix))))
  (define parts (string-split rest " "))
  (if (< (length parts) 3)
      (list (list "noop"
                  "Set a plugin preference"
                  "plugin set <plugin-id> <pref> <value…> · e.g. docker set host tcp://…"
                  "Plugin" "" "plugin" "" ""))
      (let* ([plugin-id (car parts)]
             [pref-name (cadr parts)]
             [value (string-trim
                     (substring rest
                                (+ 1 (string-length plugin-id)
                                   1 (string-length pref-name))))])
        (define spec (with-handlers ([exn:fail? (lambda (_) #f)])
                       (plugin-pref-spec plugin-id pref-name)))
        (cond
          [(not spec)
           (list (list "noop"
                       (format "Unknown preference: ~a ~a" plugin-id pref-name)
                       "query plugins <name> to see the preferences a plugin declares"
                       "Plugin" "" "plugin" "" ""))]
          [else
           (list (list "plugin.set"
                       (format "Set ~a · ~a" (plugin-pref-label spec) plugin-id)
                       (format "↵ saves ~a"
                               (if (string=? (plugin-pref-type spec) "secret")
                                   "the secret (local only, never synced)"
                                   (format "~a" value)))
                       "Plugin"
                       (string-append plugin-id "\u001F" pref-name "\u001F" value)
                       "plugin" "" "Set"))]))))

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
                              "Plugin" "" "plugin" "" "")))]
             [prefs-rows
              ;; FPP2 preferences: boolean/select cycle in place; text and
              ;; secret preferences copy their `plugin set` template.
              (let ([p (and (= (length installed) 1) (car installed))])
                (if (or (not p) (null? (plugin-preferences p)))
                    '()
                    (for/list ([spec (in-list (plugin-preferences p))])
                      (define current
                        (plugin-pref-current-value (plugin-id p) spec))
                      (define shown
                        (if (string=? (plugin-pref-type spec) "secret")
                            (if (or (not current)
                                    (string=? (format "~a" current) ""))
                                "(unset)"
                                "••••••")
                            (format "~a" current)))
                      (if (member (plugin-pref-type spec) '("boolean" "select"))
                          (list "plugin.pref.cycle"
                                (format "~a = ~a"
                                        (plugin-pref-label spec) shown)
                                "↵ cycles the value"
                                "Plugin"
                                (string-append (plugin-id p)
                                               "\u001F"
                                               (plugin-pref-name spec))
                                "plugin" "" shown)
                          (list "plugins.example"
                                (format "~a = ~a"
                                        (plugin-pref-label spec) shown)
                                (format "↵ copies: plugin set ~a ~a <value…>"
                                        (plugin-id p)
                                        (plugin-pref-name spec))
                                "Plugin"
                                (format "plugin set ~a ~a "
                                        (plugin-id p)
                                        (plugin-pref-name spec))
                                "plugin" "" "Copy")))))])
        (append detail command-rows permission-row prefs-rows))))

(define (plugin-center-rows query)
  (define trimmed (string-trim query))
  (define lowered (string-downcase trimmed))
  (cond
    ;; `plugin set <id> <pref> <value…>` — the FPP2 preference editor.
    [(string-prefix? lowered "plugin set ")
     (plugin-set-rows trimmed)]
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
                 (map toggle-row
                      (append (plugin-manager-plugins manager)
                              (plugin-manager-disabled-plugins manager))))))]))

;; ---- RPCs ---------------------------------------------------------------

(define-rpc (health : String)
  (format "fulcrum ~a apps=~a" app-version (engine-app-count (engine!))))

;; ---- app index freshness -------------------------------------------------
;;
;; The app index is a startup snapshot; an application installed after
;; startup stayed invisible until relaunch. Every search stats the
;; discovery roots (a handful of stat calls, microseconds per keystroke):
;; an installed or removed bundle changes a root's mtime and only then does
;; the index rebuild inline. Unchanged roots cost the search path nothing.
;; The fingerprint cache is a parameter so tests can drive the refresh.

(define app-roots-fingerprint-cache (make-parameter #f))

;; Shared by the search RPC (staleness-gated) and index-rebuild (explicit);
;; returns the rebuilt index's key count. That is not the discovery list's
;; length on every platform: overlapping roots can hand back several bundles
;; under one resolved path, and the index is keyed by id, so the count is
;; read off the index itself. Discovery failures propagate to the caller's
;; guard so a platform-specific error degrades, never kills the worker.
(define (rebuild-app-index!)
  (engine-rebuild-index! (engine!))
  (app-roots-fingerprint-cache (application-roots-fingerprint))
  (engine-app-count (engine!)))

(define (refresh-app-index-if-stale!)
  (when (apps-index-stale? (app-roots-fingerprint-cache))
    (rebuild-app-index!)))

(define-rpc (search [query String] : (List (List String)))
  (refresh-app-index-if-stale!)
  (rows-for (engine!) query))

;; Secondary actions for one result row — the ⌘K panel's contents, in the
;; same 8-column row contract as search.
;; Plain function under the row-actions RPC so tests can drive the
;; backend-owned panels without a live wire.
(define (row-actions-for id arg)
  (cond
    ;; Backend-owned AI rows: the engine knows nothing about them. The
    ;; last-answer row offers paste-back in addition to the primary copy.
    [(string=? id "ai.copy")
     (list (list "ai.paste"
                 "Paste answer to frontmost"
                 "types the answer into the app you were using"
                 "AI" "" "sparkles" "" "Paste"))]
    [else (engine-row-actions (engine!) id arg)]))

(define-rpc (row-actions [id String] [arg String] : (List (List String)))
  (row-actions-for id arg))

(define-rpc (run-action [id String] [arg String] : String)
  ;; Settings, AI, plugin-center and update rows are backend-owned (the
  ;; engine holds no settings, keys, or update state), so they route here
  ;; before the engine.
  (define outcome
    (cond
      [(string=? id "settings.open")
       ;; The settings window is host-native (same delegation shape as
       ;; about.open); checked before the settings. prefix router.
       (cons "delegated" '())]
      [(string-prefix? id "settings.") (settings-act! arg)]
      [(string-prefix? id "ai.") (ai-act! (engine!) id arg)]
      [(or (string=? id "plugin.set") (string=? id "plugin.pref.cycle"))
       (plugins-act! (engine!) id arg)]
      [(string=? id "plugins.example")
       ;; Copying a usage example: the panel hides and the example sits
       ;; on the clipboard, ready to paste into a fresh query.
       (cons "copied" (list (cons 'copy-to-clipboard arg)))]
      [(string-prefix? id "plugins.") (plugins-act! (engine!) id arg)]
      [(string=? id "about.open")
       ;; About is host-native: every host maps this row to its own about
       ;; panel/dialog (same delegation shape as the win.* commands).
       (cons "delegated" '())]
      [(string-prefix? id "update.") (update-act! id)]
      [else (engine-run (engine!) id arg)]))
  (emit-events! (cdr outcome))
  (car outcome))

(define-rpc (index-rebuild : Int64)
  ;; Discovery touches the platform application roots; a platform-specific
  ;; failure must degrade to an error result, never kill the request worker.
  (with-handlers ([exn?
                   (lambda (e)
                     (notify (format "index rebuild failed: ~a" (exn-message e)))
                     -1)])
    (rebuild-app-index!)))

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

;; Plain function under the plugin-detail RPC so tests drive the detail
;; payload without a live wire. Returns the DetailView wire record.
(define (plugin-detail-for row-id arg)
  (define command-id
    (if (string-prefix? row-id "plugin-detail:")
        (substring row-id (string-length "plugin-detail:"))
        row-id))
  (define response
    (with-handlers ([exn:fail? (lambda (e) (format "plugin error: ~a" (exn-message e)))])
      (plugin-manager-detail! (engine-plugins (engine!)) command-id arg)))
  (if (hash? response)
      (DetailView
       (let ([t (hash-ref response 'text #f)])
         (if (string? t) (substring t 0 (min (string-length t) 16384)) ""))
       (for/list ([pair (in-list
                         (let ([md (hash-ref response 'metadata '())])
                           (if (list? md) (take-min-12 md) '())))]
                  #:when (and (list? pair) (>= (length pair) 2)
                              (string? (list-ref pair 0))
                              (string? (list-ref pair 1))))
         (list (list-ref pair 0) (list-ref pair 1))))
      (DetailView (format "plugin error: ~a" response) '())))

(define (take-min-12 xs)
  (if (> (length xs) 12) (take xs 12) xs))

(define-rpc (plugin-detail [row-id String] [arg String] : DetailView)
  (plugin-detail-for row-id arg))

;; ---- settings -----------------------------------------------------------

(define (coerce-setting-value key value)
  (case key
    [(max-results clipboard-limit plugins-timeout-ms update-last-check update-rollout-bucket)
     (define n (string->number (string-trim value)))
     (if n n (raise-argument-error 'settings-set "numeric string" value))]
    [(clipboard-enabled web-search-enabled plugins-enabled expansion-enabled)
     ;; on/off is what settings-list emits and the badges show; true/false
     ;; and 1/0 stay accepted for scripts.
     (cond
       [(member (string-trim value) '("true" "1" "on")) #t]
       [(member (string-trim value) '("false" "0" "off")) #f]
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
  ;; Reflect the host-rendered keys immediately across every open surface.
  (case sym
    [(theme) (state-set! theme (settings-get (settings!) 'theme))]
    [(hotkey) (state-set! hotkey (settings-get (settings!) 'hotkey))]
    [(language) (state-set! language (settings-get (settings!) 'language))])
  #t)

;; Readiness of the configured AI provider, for the settings window's AI
;; section: "ready", or the honest reason it is not (no provider, no key).
;; The key itself never crosses the wire.
(define-rpc (ai-status : String)
  (define provider (ai-effective-provider))
  (ai-configured-status provider (ai-get-key (ai-keys-path) provider)))

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
;;
;; The family pattern (rivet/distribution, taskly): the backend verifies
;; and downloads the signed artifact; hosts own installation and
;; presentation. The 4-hour silent-check throttle lives here (settings key
;; `update-last-check`) so all three hosts share one implementation, and
;; the sticky rollout bucket persists as `update-rollout-bucket`.
;;
;; Two surfaces drive the same state: the `update-check` / `update-download`
;; / `update-state` RPCs (the macOS host's update window), and update rows
;; in the launcher (query `update`) — the discoverable surface on every
;; platform, and the primary one on Windows/Linux.

(define update-throttle-seconds (* 4 60 60))

(define (format-bytes n)
  (cond
    [(>= n (* 1024 1024))
     (string-append (~r (/ n (* 1024 1024)) #:precision '(= 1)) " MB")]
    [(>= n 1024) (format "~a KB" (quotient n 1024))]
    [else (format "~a B" n)]))

;; Map the updater's plain hasheq onto the wire record.
(define (check->record result)
  (UpdateCheck
   (hash-ref result 'status "error")
   (nullable (hash-ref result 'message #f))
   (hash-ref result 'currentVersion app-version)
   (nullable (hash-ref result 'availableVersion #f))
   (nullable (hash-ref result 'build #f))
   (nullable (hash-ref result 'publishedAt #f))
   (nullable (hash-ref result 'installer #f))
   (nullable (hash-ref result 'sizeBytes #f))))

;; One check attempt: bypasses the throttle, records `update-last-check`
;; either way (a failing feed must not be retried in a tight loop by every
;; silent launch), and emits update-available so hosts can offer the
;; install. Never raises — network and manifest failures surface as
;; status "error".
(define (update-check! manual)
  (define manager (settings!))
  (define now (current-seconds))
  (define record
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (UpdateCheck "error" (nullable (exn-message e)) app-version
                         (void) (void) (void) (void) (void)))])
      (check->record
       (perform-check! (settings-get manager 'update-base-url)))))
  (with-handlers ([exn:fail? void])
    (settings-set! manager 'update-last-check now))
  (when (string=? (record-ref record 'status) "available")
    (update-available
     (format "update available: Fulcrum v~a (~a)"
             (or (record-ref record 'available-version) "?")
             (format-bytes (or (record-ref record 'size-bytes) 0)))))
  record)

(define-rpc (update-check [manual : Bool] : UpdateCheck)
  (if manual
      (update-check! #t)
      ;; Silent launch check: at most once per 4 hours (the family
      ;; throttle, shared by every host through this one key).
      (let ([last (settings-get (settings!) 'update-last-check)])
        (if (and (exact-integer? last)
                 (< (- (current-seconds) last) update-throttle-seconds))
            (UpdateCheck "throttled" (void) app-version
                         (void) (void) (void) (void) (void))
            (update-check! #f)))))

;; Runs on a backend worker thread; the host follows progress via
;; update-state. Never raises: failures surface through the state's phase.
(define-rpc (update-download : Void)
  (with-handlers
      ([exn:fail? (lambda (e) (set-update-error! (exn-message e)))])
    (start-download! (data-dir)))
  (void))

(define-rpc (update-state : UpdateState)
  (define s (update-state-snapshot))
  (UpdateState
   (hash-ref s 'phase "idle")
   (hash-ref s 'percent 0)
   (nullable (hash-ref s 'message #f))
   (nullable (hash-ref s 'downloadedPath #f))
   (nullable (hash-ref s 'availableVersion #f))))

;; ---- updates-as-rows ------------------------------------------------------
;;
;; The launcher IS the update UI on Windows and Linux, and a discoverable
;; second entry on macOS: query `update` lists the one row the current
;; phase wants — check, download (version + size), live progress, then
;; install (macOS swaps the bundle in place) or open the folder with
;; honest manual-install guidance (Windows/Linux).

(define (update-row id title subtitle arg badge)
  (list id title subtitle "Update" arg "update" "" badge))

(define (update-rows query)
  (define trimmed (string-trim query))
  (define lowered (string-downcase trimmed))
  (define state (update-state-snapshot))
  (define phase (hash-ref state 'phase "idle"))
  (define version (hash-ref state 'availableVersion #f))
  (if (or (member lowered '("update" "updates"))
          (fuzzy-score-fields
           trimmed
           (list (cons 1.0 "update")
                 (cons 0.6 "check for updates install new version software")
                 (cons 0.3 (format "fulcrum v~a" (or version ""))))))
      (case phase
        [(downloading)
         (list (update-row
                "update.progress"
                (format "Downloading Fulcrum v~a…" (or version "?"))
                "the download continues in the background; reopen this list for fresh progress"
                "" (format "~a%" (hash-ref state 'percent 0)))
               (update-row "update.check" "Check for updates again"
                           "re-fetch the signed channel manifest now" "" ""))]
        [(downloaded)
         (append
          (if (memq (system-type 'os) '(macosx windows))
              (list (update-row
                     "update.install"
                     (format "Quit and install Fulcrum v~a" (or version "?"))
                     (case (system-type 'os)
                       [(windows)
                        "runs the verified MSI, upgrades in place, and relaunches"]
                       [else
                        "swaps the downloaded bundle in place and relaunches"])
                     "" "Install"))
              '())
          (list (update-row
                 "update.reveal"
                 "Open the updates folder"
                 (or (hash-ref state 'downloadedPath #f) "")
                 "" "Open")
                (update-row
                 "update.hint"
                 "Install manually"
                 (case (system-type 'os)
                   [(windows)
                    "double-click the downloaded .msi and follow the installer; Fulcrum can be running during the upgrade"]
                   [else
                    "extract the .tar.gz and replace the current Fulcrum folder, then relaunch"])
                 "" "")))]
        [else
         (append
          (if version
              (list (update-row
                     "update.download"
                     (format "Download Fulcrum v~a" version)
                     (format "~a · ↵ downloads in the background"
                             (format-bytes
                              (or (update-candidate-size) 0)))
                     "" "Download"))
              '())
          (list (update-row
                 "update.check"
                 (if version
                     "Check for updates again"
                     "Check for updates now")
                 (format "current: Fulcrum v~a · fetches the signed channel manifest"
                         app-version)
                 "" "")))]
      ) '()))

;; The artifact size of the pending candidate, for the download row.
(define (update-candidate-size)
  (pending-artifact-size))

(define (update-act! id)
  (case (string->symbol id)
    [(update.check)
     ;; "stay", not "ok": the hosts keep the panel open on "stay" so the
     ;; user can actually read the result (an "ok" hides the panel before
     ;; the notify message is readable — and before an error could ever
     ;; be copied).
     (define record (update-check! #t))
     (define status (record-ref record 'status))
     (define err (record-ref record 'error))
     ;; record-ref hands back strings (the silent path's string=? at
     ;; update-check! depends on it); a case over symbol literals never
     ;; matched, so every manual check reported a bogus failure.
     (cond
       [(and (string? status) (string=? status "available"))
        (cons "stay"
              (list (cons 'notify
                          (format "Update available: Fulcrum v~a (~a)"
                                  (record-ref record 'available-version)
                                  (format-bytes
                                   (or (record-ref record 'size-bytes) 0))))))]
       [(and (string? status) (string=? status "up-to-date"))
        (cons "stay"
              (list (cons 'notify
                          (format "Fulcrum v~a is up to date" app-version))))]
       [else (cons (format "update check failed: ~a"
                           (if (and (string? err) (non-empty-string? err))
                               err
                               "unknown reason"))
                   '())])]
    [(update.download)
     (with-handlers
         ([exn:fail? (lambda (e)
                       (set-update-error! (exn-message e))
                       (cons (exn-message e) '()))])
       (start-download! (data-dir))
       (cons "downloading"
             (list (cons 'notify "Update download started"))))]
    [(update.install)
     ;; Native hosts own the last mile. macOS swaps the verified app bundle;
     ;; Windows hands the verified MSI to Rivet's MsiHandoff helper. Linux
     ;; remains install-shape-aware and does not bypass package-manager ownership.
     (if (memq (system-type 'os) '(macosx windows))
         (cons "quit-and-install" '())
         (cons "in-app install is unavailable for this Linux install; open the updates folder instead" '()))]
    [(update.reveal)
     (cons "ok" (list (cons 'open-url (updates-folder-uri))))]
    [(update.hint) (cons "ok" '())]
    [else (cons (format "unknown update action: ~a" id) '())]))

;; ---- lifecycle ----------------------------------------------------------

;; Everything `start` does before it serves: stores, plugin manager, engine,
;; the shared parameters. Split out so a test can boot the production
;; wiring against a fixture data directory without RVT1 fds — the plugin
;; manager's first load once raised because of boot ordering, and nothing
;; exercised this path.
(define (boot!)
  (ensure-data-dir!)
  (define manager (make-settings-manager (settings-path)))
  ;; Published before anything that reads it through `settings!`: the plugin
  ;; manager's first load consults the disabled-ids thunk, and with the
  ;; parameter still unset that raised inside the loader — every installed
  ;; plugin stayed unloaded until some later reload (an install, a toggle).
  (current-settings manager)
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
                              #:disabled-thunk plugins-disabled-ids
                              #:nudge-thunk bump-search-revision!
                              #:prefs-thunk plugin-prefs-for)))
  (define engine
    (make-engine #:clipboard-store clip-store
                 #:snippet-store snip-store
                 #:quicklink-store link-store
                 #:plugin-manager plug-mgr
                 #:max-results (settings-get manager 'max-results)))
  (engine-rebuild-index! engine)
  ;; The startup rebuild IS the fresh state; stamping the cache here keeps
  ;; the first search from re-scanning the roots redundantly.
  (app-roots-fingerprint-cache (application-roots-fingerprint))
  (current-engine engine)
  ;; The updater persists its throttle and rollout bucket in the settings
  ;; store; hand it the manager once it exists.
  (current-update-settings manager)
  (ai-restore-memory!)
  engine)

(define (start in-fd out-fd)
  (define engine (boot!))
  (define manager (settings!))
  (state-set! theme (settings-get manager 'theme))
  (state-set! hotkey (settings-get manager 'hotkey))
  (state-set! language (settings-get manager 'language))
  (void engine)
  (serve-fds in-fd out-fd))
