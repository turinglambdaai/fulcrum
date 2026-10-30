#lang racket/base

;; BYOK AI: prompt building, provider response parsing, the local-only key
;; store, and the backend surface (rows that never touch the network, the
;; key-save route, and the honest refusals when unconfigured).

(require racket/file
         racket/string
         rackunit
         "../app/backend.rkt"
         "../app/core/ai.rkt"
         "../app/core/engine.rkt"
         "../app/core/paths.rkt"
         "../app/core/settings.rkt")

(define (row-id row) (list-ref row 0))
(define (row-arg row) (list-ref row 4))
(define (row-badge row) (list-ref row 7))

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-aitest-~a" 'directory))
  (parameterize ([current-environment-variables
                  (let ([env (current-environment-variables)])
                    (environment-variables-set! env #"FULCRUM_DATA_DIR"
                                                (string->bytes/utf-8 (path->string dir)))
                    env)])
    (dynamic-wind
      void
      thunk
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files dir))))))

(test-case "prompt building: verbs, clipboard context, bare questions"
  ;; summarize with a clipboard
  (check-true (string-contains?
               (build-ai-prompt "summarize" "long text here")
               "Summarize the following"))
  (check-true (string-contains?
               (build-ai-prompt "summarize" "long text here")
               "long text here"))
  ;; translate carries the target language
  (check-true (string-contains?
               (build-ai-prompt "translate zh" "hello")
               "into zh"))
  ;; translate with no target falls back to English
  (check-true (string-contains?
               (build-ai-prompt "translate" "hello")
               "into English"))
  ;; a bare question becomes the question, with clipboard as context
  (define ask (build-ai-prompt "what is a red-black tree?" "some clipboard"))
  (check-true (string-contains? ask "Question: what is a red-black tree?"))
  (check-true (string-contains? ask "some clipboard"))
  ;; no clipboard → no context block
  (check-false (string-contains? (build-ai-prompt "hi" "") "Clipboard contents")))

(test-case "provider response parsing"
  (check-equal?
   (parse-ai-response
    "openai"
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"  a sum  \"}}]}")
   "a sum")
  (check-equal?
   (parse-ai-response
    "anthropic"
    "{\"content\":[{\"type\":\"text\",\"text\":\" the answer \"}]}")
   "the answer")
  (check-equal?
   (parse-ai-response "ollama" "{\"response\":\"local answer\"}")
   "local answer")
  ;; Malformed and error bodies become readable strings, never exceptions.
  (check-true (string-prefix? (parse-ai-response "openai" "{\"nope\":1}")
                              "AI response missing"))
  (check-true (string-prefix? (parse-ai-response "openai" "not json")
                              "AI returned an unreadable")))

(test-case "the key store is local-only JSON"
  (with-fresh-data-dir
   (lambda ()
     (define path (ai-keys-path))
     (check-equal? (ai-get-key path "openai") "")
     (ai-save-key! path "openai" "sk-test-123")
     (check-equal? (ai-get-key path "openai") "sk-test-123")
     ;; A second provider does not clobber the first.
     (ai-save-key! path "anthropic" "sk-ant-1")
     (check-equal? (ai-get-key path "openai") "sk-test-123")
     (check-equal? (ai-get-key path "anthropic") "sk-ant-1")
     ;; The file lives in the data dir and nothing else mirrors it.
     (check-true (file-exists? path))
     (check-false (directory-exists? (build-path (data-dir) ".." "sync-fulcrum"))))))

(test-case "ai rows: setup guidance, key save, run rows without network"
  (with-fresh-data-dir
   (lambda ()
     (define manager (make-settings-manager (settings-path)))
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:plugin-manager #f))
     (parameterize ([current-settings manager]
                    [current-engine engine])
       ;; Unconfigured: bare "ai" shows setup, and nothing else does.
       (check-equal? (ai-rows "unrelated query") '())
       (define setup (ai-rows "ai"))
       (check-equal? (length setup) 1)
       (check-equal? (row-id (car setup)) "ai.help")
       (check-equal? (row-badge (car setup)) "setup")

       ;; "ai key sk-..." offers a save row; running it writes the local
       ;; key file (the notify event would need a server, so catch).
       (define key-rows (ai-rows "ai key sk-live-9"))
       (check-equal? (row-id (car key-rows)) "ai.key")
       (check-equal? (row-arg (car key-rows)) "sk-live-9")
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (run-action "ai.key" (row-arg (car key-rows))))
       ;; No provider yet → refused loudly and nothing stored.
       (check-equal? (ai-get-key (ai-keys-path) "") "")

       ;; Pick a provider through the settings cycle, then the key saves.
       (settings-act! "ai-provider") ; "" → openai
       (check-equal? (settings-get manager 'ai-provider) "openai")
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (run-action "ai.key" "sk-live-9"))
       (check-equal? (ai-get-key (ai-keys-path) "openai") "sk-live-9")

       ;; Ready: bare "ai" is a cheatsheet; "ai <anything>" is a run row
       ;; that carries the query text for the backend to build the prompt.
       (check-equal? (row-badge (car (ai-rows "ai"))) "ready")
       (define run-rows (ai-rows "ai summarize"))
       (check-equal? (length run-rows) 1)
       (check-equal? (row-id (car run-rows)) "ai.run")
       (check-equal? (row-arg (car run-rows)) "summarize")

       ;; Running without a clipboard store refuses honestly (nothing to
       ;; summarize) instead of calling the provider with an empty input.
       (check-equal? (run-action "ai.run" "summarize")
                     "nothing on the clipboard to work on")))))

(test-case "chat history threading and the natural-question row"
  (with-fresh-data-dir
   (lambda ()
     ;; History append bounds the transcript to 8 exchanges.
     (define one (ai-history-append '() "q1" "a1"))
     (check-equal? (length one) 2)
     (define grown
       (for/fold ([h '()] #:result h)
                 ([i (in-range 12)])
         (ai-history-append h (format "q~a" i) (format "a~a" i))))
     (check-equal? (length grown) 16)
     (check-equal? (cdr (car grown)) "q4") ; oldest kept exchange (user)

     (define manager (make-settings-manager (settings-path)))
     (define engine (make-engine #:clipboard-store #f
                                 #:snippet-store #f
                                 #:plugin-manager #f))
     (parameterize ([current-settings manager]
                    [current-engine engine])
       ;; Unconfigured: a natural question gets NO AI row.
       (check-equal? (ai-ask-row "what is entropy exactly?") '())

       ;; Configure (provider cycle + key save through the routes).
       (settings-act! "ai-provider")
       (with-handlers ([exn:fail? void])
         (run-action "ai.key" "sk-chat-test"))
       ;; Now the question row appears, without any ai prefix.
       (define ask (ai-ask-row "what is entropy exactly?"))
       (check-equal? (length ask) 1)
       (check-equal? (list-ref (car ask) 4) "what is entropy exactly?")
       (check-equal? (list-ref (car ask) 0) "ai.run")

       ;; ai.copy with no answer yet refuses honestly.
       (check-true (string-prefix? (car (ai-copy-last-answer))
                                   "no AI answer"))

       ;; After a (simulated) answer the last-answer row offers the copy.
       (ai-set-last-answer! "entropy is a measure of disorder")
       (define rows (rows-for engine "ai"))
       (define last-row
         (findf (lambda (r) (equal? (list-ref r 0) "ai.copy")) rows))
       (check-true (and last-row #t))
       (check-equal? (list-ref last-row 4)
                     "entropy is a measure of disorder")
       (check-equal? (car (ai-copy-last-answer)) "copied")

       ;; The ⌘K panel offers paste-back. A headless test cannot deliver
       ;; host events: Rivet now reports an unbound event emitter rather
       ;; than the older "no Rivet server" error. Both identify event
       ;; dispatch, not an empty-answer refusal. A bound emitter can
       ;; instead accept the action and return "copied".
       (define panel (row-actions-for "ai.copy" "entropy is a measure of disorder"))
       (check-equal? (list-ref (car panel) 0) "ai.paste")
       (define paste-result
         (with-handlers ([exn:fail? exn-message])
           (run-action "ai.paste" "")))
       (check-true (or (equal? paste-result "copied")
                       (and (string? paste-result)
                            (or (string-contains? paste-result "no Rivet server")
                                (string-contains? paste-result
                                                  "no Rivet event emitter is bound")))))

       ;; "ai model <name>" saves the model through the settings route;
       ;; bare "ai model" offers the syntax with the current value.
       (check-equal? (row-arg (car (ai-rows "ai model"))) "")
       (define model-rows (ai-rows "ai model gpt-4o-mini-2025"))
       (check-equal? (row-id (car model-rows)) "ai.model")
       (check-equal? (row-arg (car model-rows)) "gpt-4o-mini-2025")
       (define model-set
         (with-handlers ([exn:fail? (lambda (_) 'emit-error)])
           (run-action "ai.model" "gpt-4o-mini-2025")))
       ;; The save reaches the settings store either way (the event emit
       ;; needs a live server; the refusal paths return strings instead).
       (check-equal? (settings-get manager 'ai-model) "gpt-4o-mini-2025")
       (check-true (or (equal? model-set "ok")
                       (equal? model-set 'emit-error)))

       ;; "ai persona <text>" persists; bare "ai persona" shows it.
       (check-equal? (row-arg (car (ai-rows "ai persona"))) "")
       (define persona-rows (ai-rows "ai persona 说话像海盗"))
       (check-equal? (row-id (car persona-rows)) "ai.persona")
       (check-equal? (row-arg (car persona-rows)) "说话像海盗")

       ;; Chat reset clears memory.
       (ai-set-history! (ai-history-append '() "q" "a"))
       (with-handlers ([exn:fail? void])
         (run-action "ai.reset" ""))
       (check-equal? (ai-history) '())
       (check-equal? (ai-last-answer) "")

       ;; Undo drops the last exchange.
       (ai-set-history! (ai-history-append '() "q1" "a1"))
       (ai-set-history! (ai-history-append (ai-history) "q2" "a2"))
       (with-handlers ([exn:fail? void])
         (run-action "ai.undo" ""))
       (check-equal? (length (ai-history)) 2)

       ;; Memory persists to disk and restores.
       (ai-set-history! (ai-history-append '() "saved q" "saved a"))
       (ai-set-last-answer! "saved answer")
       (check-true (file-exists? (ai-memory-path)))
       ;; Simulate a restart: snapshot the persisted file, wipe the live
       ;; boxes (which persists the wipe), put the snapshot back, restore.
       (define snapshot (file->string (ai-memory-path)))
       (ai-set-history! '())
       (ai-set-last-answer! "")
       (call-with-output-file (ai-memory-path)
         (lambda (o) (display snapshot o)) #:exists 'truncate)
       (ai-restore-memory!)
       (check-equal? (ai-history)
                     (ai-history-append '() "saved q" "saved a"))
       (check-equal? (ai-last-answer) "saved answer")

       ;; Persona round-trips through the settings store.
       (with-handlers ([exn:fail? void])
         (run-action "ai.persona" "说话像海盗"))
       (check-equal? (settings-get manager 'ai-persona) "说话像海盗")))))

;; Streaming wire formats, parsed without any network: the three provider
;; framings, plus the framing lines every reader must skip.
(test-case "stream-line->delta parses openai SSE"
  (define piece (stream-line->delta
                 "openai"
                 "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}"))
  (check-equal? piece (cons "Hel" #f))
  (check-equal? (stream-line->delta "openai" "data: [DONE]") (cons "" #t))
  ;; role-only deltas carry no content: empty piece, stream continues.
  (check-equal? (stream-line->delta
                 "openai"
                 "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}")
                (cons "" #f))
  (check-false (stream-line->delta "openai" ": keep-alive comment")))

(test-case "stream-line->delta parses anthropic SSE"
  (define piece
    (stream-line->delta
     "anthropic"
     "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}"))
  (check-equal? piece (cons "lo" #f))
  (check-equal? (stream-line->delta
                 "anthropic"
                 "data: {\"type\":\"message_stop\"}")
                (cons "" #t))
  ;; Message lifecycle events are framing, not text.
  (check-equal? (stream-line->delta
                 "anthropic"
                 "data: {\"type\":\"message_start\"}")
                (cons "" #f)))

(test-case "stream-line->delta parses ollama NDJSON"
  (define piece
    (stream-line->delta "ollama" "{\"message\":{\"content\":\"hi\"},\"done\":false}"))
  (check-equal? piece (cons "hi" #f))
  (check-equal? (stream-line->delta "ollama" "{\"message\":{},\"done\":true}")
                (cons "" #t)))
