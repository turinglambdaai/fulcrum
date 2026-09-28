#lang racket/base

;; Fulcrum Plugin Protocol v1 (FPP1).
;;
;; A plugin is a directory under the plugins directory containing
;; manifest.json and an executable entry. The manifest declares metadata,
;; commands, and an argv-style entry:
;;
;;   {
;;     "id": "epoch",
;;     "name": "Epoch",
;;     "version": "0.1.0",
;;     "description": "Unix timestamp ↔ date",
;;     "icon": "plugin",
;;     "entry": {"exec": ["/usr/bin/python3", "epoch.py"]},
;;     "commands": [
;;       {"id": "convert", "name": "Convert timestamp", "keyword": "ts"}
;;     ],
;;     "permissions": []
;;   }
;;
;; Wire protocol: one JSON object per line on stdin/stdout.
;;   → {"op":"query","command":"<cid>","query":"...","request_id":1}
;;   ← {"request_id":1,"results":[{"title":"…","subtitle":"…","arg":"…","icon":"…"}]}
;;   → {"op":"run","command":"<cid>","arg":"…","request_id":2}
;;   ← {"request_id":2,"status":"ok","message":"optional"}
;;
;; Every query/run spawns a fresh process and kills it afterwards, with a
;; bounded timeout. There is deliberately no warm process lifecycle in v1:
;; the process boundary is the isolation story, and a hung plugin can only
;; cost its own timeout. Manifest permissions are advisory metadata in v1;
;; enforcing them per-plugin is a roadmap item, and the README says so.

(require json
         racket/async-channel
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "proc.rkt")

(provide (struct-out plugin)
         (struct-out plugin-command)
         (struct-out plugin-manager)
         make-plugin-manager
         plugin-manager-reload!
         plugin-manager-plugins
         plugin-manager-errors
         plugin-manager-query
         plugin-manager-run!)

(struct plugin (id name version description icon commands entry permissions)
  #:transparent)

(struct plugin-command (id name keyword description icon) #:transparent)

;; The manager is a closure holder: dirs, timeout, loaded plugins, and load
;; errors, guarded by one lock. Plugins themselves are immutable snapshots.
(struct plugin-manager (path timeout-ms state lock) #:mutable)

(define max-manifest-bytes 65536)
(define max-commands-per-plugin 32)
(define max-results-per-query 10)

(define (safe-read-json-file path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (when (> (file-size path) max-manifest-bytes)
      (error 'load-plugin "manifest too large"))
    (define text (file->string path))
    (string->jsexpr text)))

(define (manifest->plugin dir manifest)
  (define (str key [default #f])
    (define v (hash-ref manifest key default))
    (and (string? v) (non-empty-string? v) v))
  (define id (str 'id))
  (define name (str 'name))
  (define entry (hash-ref manifest 'entry #f))
  (define exec
    (and (hash? entry)
         (let ([argv (hash-ref entry 'exec #f)])
           (and (list? argv)
                (pair? argv)
                (andmap string? argv)
                ;; Arguments resolve against the plugin directory; the
                ;; program itself stays as written (absolute path or PATH
                ;; lookup) unless it clearly names a relative file.
                (cons (if (and (not (complete-path? (car argv)))
                               (string-contains? (car argv) "/"))
                          (path->string (build-path dir (car argv)))
                          (car argv))
                      (for/list ([a (in-list (cdr argv))])
                        (if (complete-path? a)
                            a
                            (path->string (build-path dir a)))))))))
  (define commands
    (let ([raw (hash-ref manifest 'commands '())])
      (if (and (list? raw) (<= (length raw) max-commands-per-plugin))
          (for/list ([c (in-list raw)]
                     #:when (and (hash? c) (string? (hash-ref c 'id #f))
                                 (string? (hash-ref c 'name #f))))
            (plugin-command (hash-ref c 'id)
                            (hash-ref c 'name)
                            (or (and (string? (hash-ref c 'keyword #f))
                                     (hash-ref c 'keyword))
                                "")
                            (or (and (string? (hash-ref c 'description #f))
                                     (hash-ref c 'description))
                                "")
                            (or (and (string? (hash-ref c 'icon #f))
                                     (hash-ref c 'icon))
                                "plugin")))
          '())))
  (define permissions
    (let ([raw (hash-ref manifest 'permissions '())])
      (if (list? raw) (filter string? raw) '())))
  (and id name exec
       (plugin id
               name
               (or (str 'version) "0.0.0")
               (or (str 'description) "")
               (or (str 'icon) "plugin")
               commands
               exec
               permissions)))

(define (load-plugins! mgr)
  (define dir (plugin-manager-path mgr))
  (make-directory* dir)
  (define plugins '())
  (define errors '())
  (for ([sub (in-list (sort (directory-list dir) string<? #:key path->string))])
    (define sub-dir (build-path dir sub))
    (when (directory-exists? sub-dir)
      (define manifest-path (build-path sub-dir "manifest.json"))
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (set! errors
                               (cons (format "~a: ~a"
                                             (path->string sub-dir)
                                             (exn-message e))
                                     errors)))])
        (if (file-exists? manifest-path)
            (let ([manifest (safe-read-json-file manifest-path)])
              (cond
                [(not (hash? manifest))
                 (set! errors
                       (cons (format "~a: manifest is not a JSON object"
                                     (path->string sub-dir))
                             errors))]
                [else
                 (define loaded (manifest->plugin sub-dir manifest))
                 (if loaded
                     (set! plugins (cons loaded plugins))
                     (set! errors
                           (cons (format "~a: manifest missing id, name, or entry.exec"
                                         (path->string sub-dir))
                                 errors)))]))
            (set! errors
                  (cons (format "~a: missing manifest.json" (path->string sub-dir))
                        errors))))))
  (set-plugin-manager-state! mgr (cons (reverse plugins) (reverse errors))))

;; ---- subprocess call ----------------------------------------------------

(define (call-plugin! exec timeout-ms request)
  ;; Returns a jsexpr response or an error string. The process is always
  ;; killed; a hung plugin costs at most its timeout.
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f (car exec) (cdr exec)))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (with-handlers ([exn:fail? (lambda (e) (format "plugin write failed: ~a" (exn-message e)))])
        (display (jsexpr->string request) stdin)
        (newline stdin)
        (flush-output stdin))
      (define result-ch (make-async-channel))
      (define reader
        (thread
         (lambda ()
           (with-handlers ([exn:fail?
                            (lambda (_)
                              (async-channel-put result-ch 'reader-failed))])
             (define line (read-line stdout 'any))
             (async-channel-put result-ch line)))))
      (define result (sync/timeout (/ timeout-ms 1000) result-ch))
      (cond
        [(not result) "plugin timed out"]
        [(eq? result 'reader-failed) "plugin crashed"]
        [(eof-object? result) "plugin exited without a response"]
        [(not (string? result)) "plugin sent an invalid response"]
        [else
         (with-handlers ([exn:fail? (lambda (_) "plugin sent invalid JSON")])
           (define response (string->jsexpr result))
           (if (hash? response) response "plugin sent a non-object response"))]))
    (lambda ()
      (subprocess-kill proc #t)
      (close-output-port stdin)
      (close-input-port stdout)
      (close-input-port stderr))))

;; ---- public API ---------------------------------------------------------

(define/contract (make-plugin-manager path #:timeout-ms [timeout-ms 2000])
  (->* (path?) (#:timeout-ms (and/c exact-integer? (>=/c 100) (<=/c 10000)))
       plugin-manager?)
  (define mgr (plugin-manager path timeout-ms #f (make-semaphore 1)))
  (plugin-manager-reload! mgr)
  mgr)

(define/contract (plugin-manager-reload! mgr)
  (-> plugin-manager? void?)
  (call-with-semaphore
   (plugin-manager-lock mgr)
   (lambda ()
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (set-plugin-manager-state! mgr (cons '() (list (exn-message e)))))])
       (load-plugins! mgr)))))

(define/contract (plugin-manager-plugins mgr)
  (-> plugin-manager? (listof plugin?))
  (define state (plugin-manager-state mgr))
  (if state (car state) '()))

(define/contract (plugin-manager-errors mgr)
  (-> plugin-manager? (listof string?))
  (define state (plugin-manager-state mgr))
  (if state (cdr state) '()))

(define (command-matches? command query)
  ;; A command with a keyword claims queries of the form "<keyword> ..." or
  ;; exactly "<keyword>"; a command without a keyword participates in every
  ;; query.
  (define keyword (plugin-command-keyword command))
  (cond
    [(string=? keyword "") #t]
    [(string-ci=? query keyword) #t]
    [(string-prefix? query (string-append keyword " ")) #t]
    [else #f]))

(define (query-text-for command query)
  (define keyword (plugin-command-keyword command))
  (if (and (not (string=? keyword "")) (> (string-length query) (string-length keyword)))
      (string-trim (substring query (string-length keyword)))
      ""))

(define/contract (plugin-manager-query mgr query)
  (-> plugin-manager? string? (listof (list/c string? string? string? string? string?)))
  ;; Returns rows of (title subtitle arg icon "<plugin-id>:<command-id>").
  (define trimmed (string-trim query))
  (if (zero? (string-length trimmed))
      '()
      (let ([command-rows
             (for*/list ([p (in-list (plugin-manager-plugins mgr))]
                         [c (in-list (plugin-commands p))]
                         #:when (command-matches? c trimmed))
               (define response
                 (call-plugin! (plugin-entry p)
                               (plugin-manager-timeout-ms mgr)
                               (hasheq 'op "query"
                                       'command (plugin-command-id c)
                                       'query (query-text-for c trimmed)
                                       'request_id (random 1000000))))
               (define results
                 (if (hash? response)
                     (let ([raw (hash-ref response 'results '())])
                       (if (list? raw) (take-min raw max-results-per-query) '()))
                     '()))
               (for/list ([r (in-list results)]
                          #:when (and (hash? r) (string? (hash-ref r 'title #f))))
                 (list (hash-ref r 'title)
                       (or (hash-ref r 'subtitle #f) "")
                       (or (hash-ref r 'arg #f) "")
                       (or (hash-ref r 'icon #f) (plugin-icon p))
                       (string-append (plugin-id p) ":" (plugin-command-id c)))))])
        ;; command-rows is one list of rows per plugin command; flatten it.
        (apply append command-rows))))

(define (take-min xs n)
  (if (> (length xs) n) (take xs n) xs))

;; Split "<plugin-id>:<command-id>" at the first colon. Plugin ids never
;; contain colons, so everything after the first one is the command id.
(define (split-command-id command-id)
  (define cut (index-of-char command-id #\:))
  (if cut
      (list (substring command-id 0 cut)
            (substring command-id (add1 cut)))
      (list command-id)))

(define (index-of-char s ch)
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

(define/contract (plugin-manager-run! mgr command-id arg)
  (-> plugin-manager? string? string? string?)
  ;; command-id is "<plugin-id>:<command-id>".
  (define parts (split-command-id command-id))
  (define plugin
    (and (= (length parts) 2)
         (findf (lambda (p) (string=? (plugin-id p) (car parts)))
                (plugin-manager-plugins mgr))))
  (cond
    [(not plugin) (format "unknown plugin command: ~a" command-id)]
    [else
     (define response
       (call-plugin! (plugin-entry plugin)
                     (plugin-manager-timeout-ms mgr)
                     (hasheq 'op "run"
                             'command (cadr parts)
                             'arg arg
                             'request_id (random 1000000))))
     (if (hash? response)
         (let ([status (hash-ref response 'status "error")])
           (if (string? status) status "error"))
         response)]))
