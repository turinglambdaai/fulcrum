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
