#lang racket/base

;; BYOK AI — the business plan's phase-1 shape: the user's own key, our
;; cost zero, the privacy posture intact (the prompt leaves the machine
;; only when the user runs an AI row).
;;
;; Providers share one request shape in this file: OpenAI
;; /v1/chat/completions, Anthropic /v1/messages, Ollama /api/generate.
;; The answer always lands in the clipboard (run-action returns
;; "copied"), so a slow model never traps the user in the panel.
;;
;; The API key lives in ai-keys.json inside the data directory and is
;; deliberately NOT part of sync: the sync mirror would otherwise carry a
;; secret into a cloud folder. Provider/model/base-url settings sync fine.

(require json
         net/http-client
         racket/async-channel
         racket/contract
         racket/file
         racket/list
         racket/port
         racket/string
         "store.rkt")

(provide ai-providers
         default-ai-model
         default-ai-base-url
         ai-get-key
         ai-save-key!
         build-ai-prompt
         parse-ai-response
         ai-request
         ai-history-append
         ai-configured-status)

;; ---- configuration -------------------------------------------------------

(define ai-providers '("" "openai" "anthropic" "ollama"))

(define (default-ai-model provider)
  (case provider
    [("openai") "gpt-4o-mini"]
    [("anthropic") "claude-3-5-haiku-latest"]
    [("ollama") "llama3.2"]
    [else ""]))

(define (default-ai-base-url provider)
  (case provider
    [("openai") "https://api.openai.com"]
    [("anthropic") "https://api.anthropic.com"]
    [("ollama") "http://localhost:11434"]
    [else ""]))

;; Plain JSON {provider: key}. Never mirrored to the sync root — nothing
;; in this file's write path touches sync. `path` comes from paths.rkt's
;; ai-keys-path so tests can pin it with FULCRUM_DATA_DIR.
(define (ai-get-key path provider)
  (define raw (read-json-file path (hash)))
  (define key (if (hash? raw) (hash-ref raw (string->symbol provider) #f) #f))
  (if (string? key) key ""))

(define/contract (ai-save-key! path provider key)
  (-> path? string? string? void?)
  (unless (member provider ai-providers)
    (raise-argument-error 'ai-save-key! "known ai provider" provider))
  (define raw (read-json-file path (hash)))
  (define updated (hash-set (if (hash? raw) raw (hash))
                            (string->symbol provider) key))
  (write-json-atomic! path updated))

;; ---- prompts ---------------------------------------------------------------

;; Verbs act on the clipboard when there is one; the bare remainder is a
;; straight question. `text` is the query after "ai " ("summarize",
;; "translate zh", "what is a red-black tree?"). Returns the user-message
;; string.
(define (build-ai-prompt text clipboard)
  (define trimmed (string-trim text))
  (define context
    (if (non-empty-string? (string-trim clipboard))
        (string-append "Clipboard contents:\n"
                       (string-trim clipboard) "\n\n")
        ""))
  (define (verb-is? v)
    (or (string=? trimmed v)
        (string-prefix? trimmed (string-append v " "))))
  (define (after-verb v)
    (string-trim (substring trimmed (min (string-length trimmed)
                                         (add1 (string-length v))))))
  (cond
    [(verb-is? "summarize")
     (string-append "Summarize the following in 2-3 sentences."
                    " Reply with the summary only.\n\n"
                    (if (non-empty-string? (after-verb "summarize"))
                        (after-verb "summarize")
                        (string-trim clipboard)))]
    [(verb-is? "clean")
     (string-append "Clean up the following text: fix grammar and spelling,"
                    " keep the meaning and the language."
                    " Reply with the cleaned text only.\n\n"
                    (if (non-empty-string? (after-verb "clean"))
                        (after-verb "clean")
                        (string-trim clipboard)))]
    [(verb-is? "translate")
     (define target (after-verb "translate"))
     (string-append "Translate the following text into "
                    (if (non-empty-string? target) target "English")
                    ". Reply with the translation only.\n\n"
                    (string-trim clipboard))]
    [(verb-is? "explain")
     (string-append "Explain the following concisely.\n\n"
                    context
                    (if (non-empty-string? (after-verb "explain"))
                        (after-verb "explain")
                        (string-trim clipboard)))]
    [else
     (string-append context "Question: " trimmed)]))

;; ---- provider wire formats -------------------------------------------------

;; History entries are ready jsexpr messages ({role, content}); the new
;; user prompt is appended by the caller.
(define (openai-body model messages)
  (jsexpr->string (hasheq 'model model 'messages messages)))

(define (anthropic-body model messages)
  (jsexpr->string (hasheq 'model model 'max_tokens 1024 'messages messages)))

;; Ollama's chat endpoint speaks the same messages shape.
(define (ollama-body model messages)
  (jsexpr->string (hasheq 'model model 'messages messages 'stream #f)))

;; Pure: provider + raw JSON response text → answer string or an error
;; string the host can show in its status line.
(define (content-or-hint content)
  (if (string? content) (string-trim content)
      "AI response missing its text field"))

(define (choices-content body)
  (define choices (hash-ref body 'choices #f))
  (if (not (and (list? choices) (pair? choices)))
      #f
      (let ([first (car choices)])
        (if (not (hash? first))
            #f
            (let ([msg (hash-ref first 'message #f)])
              (if (hash? msg) (hash-ref msg 'content #f) #f))))))

(define (content-blocks-text body)
  (define blocks (hash-ref body 'content #f))
  (if (not (and (list? blocks) (pair? blocks)))
      #f
      (let ([first (car blocks)])
        (if (hash? first) (hash-ref first 'text #f) #f))))

(define (parse-ai-response provider raw)
  (with-handlers ([exn:fail? (lambda (_) "AI returned an unreadable response")])
    (define body (string->jsexpr raw))
    (if (not (hash? body))
        "AI returned an unreadable response"
        (case provider
          [("openai") (content-or-hint (choices-content body))]
          [("anthropic") (content-or-hint (content-blocks-text body))]
          [("ollama")
           (content-or-hint
            (or (hash-ref body 'response #f)
                (let ([msg (hash-ref body 'message #f)])
                  (and (hash? msg) (hash-ref msg 'content #f)))))]
          [else "unknown provider"]))))

;; Split "https://api.example.com/v1" into host + path prefix.
(define (split-base-url base-url)
  (define sans-scheme
    (cond
      [(string-prefix? base-url "https://") (substring base-url 8)]
      [(string-prefix? base-url "http://") (substring base-url 7)]
      [else base-url]))
  (define cut (index-of-char sans-scheme #\/))
  (if cut
      (cons (substring sans-scheme 0 cut) (substring sans-scheme cut))
      (cons sans-scheme "")))

;; One HTTP call per provider, in a thread bounded by timeout-ms so a
;; wedged provider cannot hang the backend RPC forever. Returns the
;; answer text or an error string.
(define/contract (ai-request provider base-url key model prompt
                             #:history [history '()]
                             #:timeout-ms [timeout-ms 45000])
  (->* (string? string? string? string? string?)
       (#:history (listof (cons/c string? string?))
        #:timeout-ms exact-nonnegative-integer?)
       string?)
  (define host+prefix (split-base-url base-url))
  (define host (car host+prefix))
  (define prefix (cdr host+prefix))
  (define ssl? (string-prefix? base-url "https://"))
  (define messages
    (append (for/list ([pair (in-list history)])
              (hasheq 'role (car pair) 'content (cdr pair)))
            (list (hasheq 'role "user" 'content prompt))))
  (define path
    (case provider
      [("openai") (string-append prefix "/v1/chat/completions")]
      [("anthropic") (string-append prefix "/v1/messages")]
      [else (string-append prefix "/api/chat")]))
  (define body
    (case provider
      [("openai") (openai-body model messages)]
      [("anthropic") (anthropic-body model messages)]
      [else (ollama-body model messages)]))
  (define headers
    (case provider
      [("openai")
       (list "Content-Type: application/json"
             (string-append "Authorization: Bearer " key))]
      [("anthropic")
       (list "Content-Type: application/json"
             (string-append "x-api-key: " key)
             "anthropic-version: 2023-06-01")]
      [else (list "Content-Type: application/json")]))

  (define result-ch (make-async-channel))
  (thread
   (lambda ()
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (async-channel-put
                         result-ch
                         (string-append "AI request failed: "
                                        (exn-message e))))])
       (define conn (http-conn))
       (http-conn-open! conn host #:ssl? ssl?)
       (dynamic-wind
         void
         (lambda ()
           (define-values (status-line _headers in)
             (http-conn-sendrecv! conn path
                                  #:method "POST"
                                  #:headers headers
                                  #:data-utf8/bytes body))
           (define raw (port->string in))
           (if (regexp-match? #rx"^HTTP/1\\.1 2" status-line)
               (async-channel-put result-ch
                                  (parse-ai-response provider raw))
               (async-channel-put
                result-ch
                (format "AI request failed (HTTP ~a)"
                        (or (let ([m (regexp-match #rx"[0-9]{3}" status-line)])
                              (and m (car m)))
                            "?")))))
         (lambda () (http-conn-close! conn))))))
  (define result (sync/timeout (/ timeout-ms 1000) result-ch))
  (or result "AI request timed out"))

(define (index-of-char s ch)
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

;; Conversation memory: append one exchange, bounded so a long chat
;; cannot grow the request without limit.
(define ai-history-max-exchanges 8)

(define/contract (ai-history-append history user assistant)
  (-> (listof (cons/c string? string?)) string? string?
      (listof (cons/c string? string?)))
  (define grown
    (append history (list (cons "user" user) (cons "assistant" assistant))))
  (define keep (* 2 ai-history-max-exchanges))
  (if (> (length grown) keep) (take-right grown keep) grown))

;; ---- status ---------------------------------------------------------------

;; "ready" | a short reason the AI rows will refuse to run.
(define (ai-configured-status provider key)
  (cond [(not (member provider ai-providers)) "unknown provider"]
        [(string=? provider "") "no provider configured"]
        [(string=? key "") (format "no API key for ~a" provider)]
        [else "ready"]))
