#lang racket/base

;; Fulcrum MCP spike (#55) — a local stdio MCP server that embeds the same
;; Racket backend the native hosts embed, and exposes two READ-ONLY tools:
;;
;;   fulcrum_search            — one ranked search over the launcher engine
;;   fulcrum_clipboard_history — clipboard history, optionally filtered
;;
;; The spike deliberately exposes no action RPC (run-action, snippet-save,
;; settings-set, update-*): until tool results pass the same staged
;; permission ladder FPP2 is building, an external agent gets read access
;; only. docs/mcp.md records the decision and the threat model.
;;
;; MCP stdio transport: one JSON-RPC 2.0 message per line on stdin, one per
;; line on stdout. Point any MCP client at it:
;;
;;   { "mcpServers": { "fulcrum": { "command": "racket",
;;                                  "args": ["scripts/mcp/spike-server.rkt"] } } }
;;
;; `scripts/mcp/spike-demo.rkt` drives the full handshake end-to-end.

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         rivet/backend
         rivet/protocol)

;; ---- backend embed (the same init order the wire test uses) ---------------

(define-runtime-path here ".")
(define fulcrum-root
  (path->string (simplify-path (build-path here ".." ".."))))
(define plugins-mod (build-path fulcrum-root "app" "core" "plugins.rkt"))
(define (get rel sym)
  (dynamic-require (build-path fulcrum-root rel) sym))

(void (dynamic-require (build-path fulcrum-root "app" "backend.rkt") #f))

(define current-engine* (get "app/backend.rkt" 'current-engine))
(define current-settings* (get "app/backend.rkt" 'current-settings))
(define make-settings-manager (get "app/core/settings.rkt" 'make-settings-manager))
(define settings-path* (get "app/core/paths.rkt" 'settings-path))
(define clipboard-path* (get "app/core/paths.rkt" 'clipboard-path))
(define snippets-path* (get "app/core/paths.rkt" 'snippets-path))
(define make-clipboard-store* (get "app/core/clipboard.rkt" 'make-clipboard-store))
(define make-snippet-store* (get "app/core/snippets.rkt" 'make-snippet-store))
(define make-engine* (get "app/core/engine.rkt" 'make-engine))
(define rebuild! (get "app/core/engine.rkt" 'engine-rebuild-index!))
(define make-plugin-manager* (dynamic-require plugins-mod 'make-plugin-manager))

(define manager (make-settings-manager (settings-path*)))
(define eng
  (make-engine*
   #:clipboard-store (make-clipboard-store* (clipboard-path*))
   #:snippet-store (make-snippet-store* (snippets-path*))
   #:plugin-manager
   (make-plugin-manager* ((get "app/core/paths.rkt" 'plugins-dir)))))
;; void-wrapped: a plain top-level call would print its value to stdout and
;; corrupt the MCP stdio framing.
(void (rebuild! eng))
(current-settings* manager)
(current-engine* eng)

;; ---- RVT1 client side (pipes, the way hosts and the wire test do) ---------

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(void (thread (lambda () (serve server-in server-out))))

(define next-id (box 0))
(struct exn:rpc exn:fail:user ())

;; RVT1 frames carry (rpc-name arg ...) as one flat payload, the way the
;; wire test drives the backend.
(define (call-rpc . parts)
  (define id (begin0 (unbox next-id) (set-box! next-id (add1 (unbox next-id)))))
  (write-frame (frame message:request id (encode-value parts)) client-out)
  (let loop ()
    (define f
      (or (sync/timeout 10 client-in)
          (raise (exn:rpc (format "fulcrum-mcp: timeout waiting for ~a"
                                  (car parts))
                          (current-continuation-marks)))))
    (define frame (read-frame client-in))
    (match (frame-type frame)
      [(== message:response) (decode-value (frame-payload frame))]
      [(== message:error)
       (raise (exn:rpc (format "fulcrum-mcp: ~a failed: ~a"
                               (car parts)
                               (decode-value (frame-payload frame)))
                       (current-continuation-marks)))]
      [else (loop)])))

;; ---- MCP surface -----------------------------------------------------------

(define tools
  (list
   (hasheq 'name "fulcrum_search"
           'description
           "Search the local Fulcrum launcher index: installed apps, clipboard
history, snippets, quicklinks, inline calculator and date/unit conversions.
Returns the ranked rows the launcher itself would show."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'query (hasheq 'type "string"
                                          'description
                                          "The search text, e.g. firefox, 12*12, or next friday"))
                   'required (list "query")))
   (hasheq 'name "fulcrum_clipboard_history"
           'description
           "Read the on-device clipboard history Fulcrum records locally.
No cloud, no sync — this is the user's own history on this machine."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'query (hasheq 'type "string"
                                          'description "Optional filter; empty lists recent rows"))))))

(define (row-line row)
  (define title (list-ref row 1))
  (define subtitle (list-ref row 2))
  (define kind (list-ref row 3))
  (if (non-empty-string? subtitle)
      (format "~a — ~a (~a)" title subtitle kind)
      (format "~a (~a)" title kind)))

(define (rows-text rows)
  (if (null? rows)
      "No results."
      (string-join
       (for/list ([row (in-list (take rows (min 15 (length rows))))])
         (row-line row))
       "\n")))

(define (handle-tools-call params)
  (define args (hash-ref params 'arguments (hash)))
  (case (hash-ref params 'name)
    [("fulcrum_search")
     (text-result (rows-text (call-rpc "search" (hash-ref args 'query ""))))]
    [("fulcrum_clipboard_history")
     (text-result (rows-text (call-rpc "clipboard-history" (hash-ref args 'query ""))))]
    [else
     (hasheq 'content
             (list (hasheq 'type "text"
                           'text (format "unknown tool: ~a" (hash-ref params 'name))))
             'isError #t)]))

(define (text-result text)
  (hasheq 'content (list (hasheq 'type "text" 'text text))))

(define (handle method params)
  (case method
    [("initialize")
     (hasheq 'protocolVersion (hash-ref params 'protocolVersion "2024-11-05")
             'capabilities (hasheq 'tools (hasheq))
             'serverInfo (hasheq 'name "fulcrum-mcp-spike"
                                 'version "0.1.0"))]
    [("tools/list") (hasheq 'tools tools)]
    [("tools/call") (handle-tools-call params)]
    [else
     (raise (exn:rpc (format "method not found: ~a" method)
                     (current-continuation-marks)))]))

;; ---- stdio loop: one JSON-RPC 2.0 message per line -------------------------

(let loop ()
  (define line (read-line (current-input-port) 'any))
  (unless (eof-object? line)
    (define msg
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (string->jsexpr line)))
    (when (hash? msg)
      (define method (hash-ref msg 'method #f))
      (define id (hash-ref msg 'id #f))
      (cond
        [(and (string? method) id)
         (with-handlers
             ([exn:fail?
               (lambda (e)
                 (write-json (hasheq 'jsonrpc "2.0" 'id id
                                     'error (hasheq 'code -32603
                                                    'message (exn-message e))))
                 (newline)
                 (flush-output))])
           (write-json
            (hasheq 'jsonrpc "2.0" 'id id
                    'result (handle method (hash-ref msg 'params (hasheq)))))
           (newline)
           (flush-output))]
        [else
         ;; Notifications (initialized, cancelled, …) need no reply.
         (void)]))
    (loop)))
