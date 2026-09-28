#lang racket/base

;; FPP1 plugin protocol end-to-end tests. The fixture plugins are /bin/sh
;; scripts speaking one-JSON-object-per-line over stdio, which is the exact
;; contract real plugins implement in any language.

(require racket/file
         racket/list
         racket/string
         rackunit
         "../app/core/plugins.rkt")

(define fixture-plugin
  #<<SH
#!/bin/sh
# FPP1 fixture plugin: one JSON object in, one JSON object out per request.
while IFS= read -r line; do
  case "$line" in
    *'"op":"query"'*)
      printf '%s\n' '{"request_id":1,"results":[{"title":"Fixture result","subtitle":"from epoch fixture","arg":"42","icon":"plugin"}]}'
      ;;
    *'"op":"run"'*)
      printf '%s\n' '{"request_id":2,"status":"ok","message":"ran"}'
      ;;
    *)
      printf '%s\n' '{"error":"unknown op"}'
      ;;
  esac
done
SH
  )

(define hanging-plugin
  #<<SH
#!/bin/sh
# A plugin that never answers: must only cost its own timeout.
sleep 30
SH
  )

(define epoch-manifest
  (string-append
   "{\"id\":\"epoch\",\"name\":\"Epoch\",\"version\":\"0.1.0\","
   "\"description\":\"Time conversions\",\"icon\":\"plugin\","
   "\"entry\":{\"exec\":[\"/bin/sh\",\"plugin.sh\"]},"
   "\"commands\":[{\"id\":\"convert\",\"name\":\"Convert\",\"keyword\":\"ts\"}],"
   "\"permissions\":[]}"))

(define broken-manifest
  (string-append
   "{\"id\":\"broken\",\"name\":\"Broken\",\"version\":\"0.1.0\","
   "\"entry\":{\"exec\":[\"/bin/sh\",\"plugin.sh\"]},"
   "\"commands\":[{\"id\":\"hang\",\"name\":\"Hang\"}]}"))

(define (write-file! path contents)
  (call-with-output-file path
    (lambda (out) (displayln contents out))
    #:exists 'truncate))

(define (call-with-fixture-plugins thunk)
  (define dir (make-temporary-file "fulcrum-plugins-~a" 'directory))
  (define epoch (build-path dir "epoch"))
  (make-directory* epoch)
  (write-file! (build-path epoch "manifest.json") epoch-manifest)
  (write-file! (build-path epoch "plugin.sh") fixture-plugin)
  (define broken (build-path dir "broken"))
  (make-directory* broken)
  (write-file! (build-path broken "manifest.json") broken-manifest)
  (write-file! (build-path broken "plugin.sh") hanging-plugin)
  ;; A directory with no manifest must be reported, never crash the manager.
  (make-directory* (build-path dir "empty"))
  (dynamic-wind
    void
    (lambda () (thunk dir))
    (lambda () (delete-directory/files dir))))

(test-case "manifest loading and load errors"
  (call-with-fixture-plugins
   (lambda (dir)
     (define mgr (make-plugin-manager dir #:timeout-ms 2000))
     (define plugins (plugin-manager-plugins mgr))
     (check-equal? (length plugins) 2 "both manifests load; hangs are runtime, not load")
     (define epoch (findf (lambda (p) (string=? (plugin-id p) "epoch")) plugins))
     (check-true (and epoch #t))
     (check-equal? (length (plugin-commands epoch)) 1)
     (check-true (pair? (plugin-manager-errors mgr)) "missing manifest reported")
     (check-true (string-contains? (car (plugin-manager-errors mgr)) "empty"))
     ;; Entry args resolve against the plugin directory.
     (check-true (string-suffix? (cadr (plugin-entry epoch)) "plugin.sh")))))

(test-case "query returns typed rows"
  (call-with-fixture-plugins
   (lambda (dir)
     (define mgr (make-plugin-manager dir #:timeout-ms 2000))
     (define rows (plugin-manager-query mgr "ts 12345"))
     (check-equal? (length rows) 1)
     (check-equal? (list-ref (car rows) 0) "Fixture result")
     (check-equal? (list-ref (car rows) 2) "42")
     (check-equal? (list-ref (car rows) 4) "epoch:convert")
     (check-equal? (plugin-manager-query mgr "") '())
     (check-equal? (plugin-manager-query mgr "zzz-no-keyword") '()
                   "keyworded commands claim only their keyword"))))

(test-case "run reports status"
  (call-with-fixture-plugins
   (lambda (dir)
     (define mgr (make-plugin-manager dir #:timeout-ms 2000))
     (check-equal? (plugin-manager-run! mgr "epoch:convert" "42") "ok")
     (check-true
      (string-contains? (plugin-manager-run! mgr "nope:thing" "")
                        "unknown plugin command")))))

(test-case "hanging plugin is bounded by its timeout"
  (call-with-fixture-plugins
   (lambda (dir)
     (define mgr (make-plugin-manager dir #:timeout-ms 300))
     (define start (current-inexact-milliseconds))
     ;; "zzz" matches only the keyword-less broken command, so any rows
     ;; would have to come from the timed-out plugin.
     (check-equal? (plugin-manager-query mgr "zzz") '()
                   "timed-out query yields no rows")
     (check-true (< (- (current-inexact-milliseconds) start) 5000)
                 "timeout enforced well under the sleep 30"))))
