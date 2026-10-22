#lang racket/base

;; End-to-end demo for the MCP spike: spawns spike-server.rkt as a real
;; subprocess, drives the MCP handshake (initialize → tools/list →
;; tools/call), and asserts the answers. Exit 0 means the spike works.
;;
;;   racket scripts/mcp/spike-demo.rkt
;;
;; The server runs against a throwaway data dir, so the demo never touches
;; the user's real launcher data.

(require json
         racket/file
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string)

;; Relative to this file, not the caller's cwd: the demo may run from
;; anywhere.
(define-runtime-path here ".")
(define root (path->string (simplify-path (build-path here ".." ".."))))
(define server (build-path root "scripts" "mcp" "spike-server.rkt"))

;; The server requires this repository's modules; the demo's own cwd is
;; irrelevant, but the child inherits the env, so pin the data dir here.
(define data-dir (make-temporary-file "fulcrum-mcp-demo-~a" 'directory))
(putenv "FULCRUM_DATA_DIR" (path->string data-dir))

;; This Racket's subprocess returns (values control stdout stdin stderr),
;; and subprocess does not resolve PATH — find racket explicitly.
(define racket-bin
  (or (find-executable-path "racket")
      (path->complete-path (find-system-path 'exec-file))))
(define-values (control stdout stdin _stderr)
  (subprocess #f #f #f racket-bin (path->string server)))

(define failures 0)
(define (check! name actual expected)
  (cond
    [(equal? actual expected)
     (printf "ok   ~a\n" name)]
    [else
     (set! failures (add1 failures))
     (printf "FAIL ~a\n  expected: ~s\n  actual:   ~s\n" name expected actual)]))

(define (send msg)
  (write-json msg stdin)
  (newline stdin)
  (flush-output stdin))

(define (receive who)
  ;; A wedged server must fail the demo, not hang it.
  (define line
    (sync/timeout 30 (handle-evt stdout (lambda (p) (read-line p 'any)))))
  (when (or (not line) (eof-object? line))
    (define err (port->string _stderr))
    (error 'spike-demo
           (format "server closed the pipe during ~a\nserver stderr: ~a"
                   who
                   (if (non-empty-string? err) err "(empty)"))))
  (define msg (string->jsexpr line))
  (when (hash-ref msg 'error #f)
    (error 'spike-demo
           (format "server returned an error during ~a: ~a" who (hash-ref msg 'error))))
  msg)

;; 1. MCP initialize handshake.
(send (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
              'params
              (hasheq 'protocolVersion "2025-06-18"
                      'capabilities (hasheq)
                      'clientInfo (hasheq 'name "spike-demo" 'version "0.1.0"))))
(define init (receive "initialize"))
(check! "initialize returns the server"
        (hash-ref (hash-ref init 'result (hasheq)) 'serverInfo #f)
        (hasheq 'name "fulcrum-mcp-spike" 'version "0.1.0"))
(send (hasheq 'jsonrpc "2.0" 'method "notifications/initialized"))

;; 2. Tool discovery.
(send (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/list" 'params (hasheq)))
(define tools (receive "tools/list"))
(check! "two read-only tools"
        (map (lambda (t) (hash-ref t 'name))
             (hash-ref (hash-ref tools 'result (hasheq)) 'tools '()))
        (list "fulcrum_search" "fulcrum_clipboard_history"))

;; 3. A real answer through the real engine — the product's own acceptance
;;    scenario: the calculator inline row for 12*12.
(send (hasheq 'jsonrpc "2.0" 'id 3 'method "tools/call"
              'params (hasheq 'name "fulcrum_search"
                              'arguments (hasheq 'query "12*12"))))
(define calc (receive "tools/call"))
(define calc-text
  (hash-ref (car (hash-ref (hash-ref calc 'result (hasheq)) 'content '())) 'text #f))
(check! "search answers 12*12"
        (and calc-text (string-contains? calc-text "144") #t) #t)

;; 4. The read-only clipboard tool answers honestly on an empty history.
(send (hasheq 'jsonrpc "2.0" 'id 4 'method "tools/call"
              'params (hasheq 'name "fulcrum_clipboard_history"
                              'arguments (hasheq 'query ""))))
(define clip (receive "tools/call"))
(define clip-text
  (hash-ref (car (hash-ref (hash-ref clip 'result (hasheq)) 'content '())) 'text #f))
(check! "clipboard history answers"
        (and (string? clip-text) (string-contains? clip-text "No results") #t) #t)

;; 5. Unknown tools are errors, not crashes.
(send (hasheq 'jsonrpc "2.0" 'id 5 'method "tools/call"
              'params (hasheq 'name "fulcrum_run_action" 'arguments (hasheq))))
(define unknown (receive "tools/call"))
(check! "no action surface for external agents"
        (hash-ref (hash-ref unknown 'result (hasheq)) 'isError #f) #t)

(close-output-port stdin)
(subprocess-wait control)

(if (zero? failures)
    (begin (printf "spike demo passed\n") (exit 0))
    (begin (printf "~a check(s) failed\n" failures) (exit 1)))
