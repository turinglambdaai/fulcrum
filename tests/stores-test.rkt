#lang racket/base

;; Clipboard and snippet store tests. Every test pins FULCRUM_DATA_DIR to a
;; fresh tmpdir so runs never touch real user data and never observe each
;; other's state.

(require json
         racket/file
         racket/list
         rackunit
         "../app/core/clipboard.rkt"
         "../app/core/paths.rkt"
         "../app/core/snippets.rkt")

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-test-~a" 'directory))
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

(test-case "clipboard record, dedupe, pin, limit"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-clipboard-store (clipboard-path) #:limit 3))
     (define first (clipboard-record! store "alpha"))
     (define second (clipboard-record! store "beta"))
     (check-equal? (clipboard-count store) 2)
     ;; Identical content moves to front, does not duplicate.
     (clipboard-record! store "alpha")
     (check-equal? (clipboard-count store) 2)
     (check-equal? (clipboard-item-id (car (clipboard-list store)))
                   (clipboard-item-id first))
     ;; Empty/whitespace content is rejected.
     (check-false (clipboard-record! store "   "))
     ;; Pin protects from the limit.
     (check-true (clipboard-item-pinned?
                  (clipboard-toggle-pin! store (clipboard-item-id second)))
                 "toggle-pin pins the item")
     (clipboard-record! store "gamma")
     (clipboard-record! store "delta")
     (clipboard-record! store "epsilon")
     (check-equal? (clipboard-count store) 3 "limit enforced")
     (check-true
      (and (findf (lambda (i) (string=? (clipboard-item-id i) (clipboard-item-id second)))
                  (clipboard-list store))
           #t)
      "pinned item survives eviction")
     ;; Clear keeps pins.
     (define removed (clipboard-clear! store))
     (check-true (>= removed 2))
     (check-equal? (clipboard-count store) 1))))

(test-case "clipboard persistence round-trip"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-clipboard-store (clipboard-path)))
     (clipboard-record! store "persisted text")
     (define reloaded (make-clipboard-store (clipboard-path)))
     (check-equal? (clipboard-count reloaded) 1)
     (check-equal? (clipboard-item-text (car (clipboard-list reloaded)))
                   "persisted text"))))

(test-case "clipboard search"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-clipboard-store (clipboard-path)))
     (clipboard-record! store "deploy command: make release")
     (clipboard-record! store "grocery list: apples")
     (check-equal? (length (clipboard-search store "release")) 1)
     (check-equal? (length (clipboard-search store "")) 2))))

(test-case "snippet CRUD and search"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-snippet-store (snippets-path)))
     (define s (snippet-save! store "Welcome mail" "Hi there, thanks for reaching out…" "hi"))
     (snippet-save! store "Changelog link" "https://fulcrum.jrtx.site/changelog")
     (check-equal? (snippet-count store) 2)
     ;; Update by id.
     (snippet-save! store "Welcome mail" "Updated body" "hello" (snippet-id s))
     (check-equal? (snippet-count store) 2)
     (check-equal? (snippet-text (snippet-ref store (snippet-id s))) "Updated body")
     (check-equal? (snippet-keyword (snippet-ref store (snippet-id s))) "hello")
     ;; Keyword lookup is exact and case-insensitive.
     (check-true (and (snippet-by-keyword store "HELLO") #t))
     (check-false (snippet-by-keyword store "welcome"))
     (check-equal? (length (snippet-search store "mail")) 1)
     (check-true (snippet-delete! store (snippet-id s)))
     (check-equal? (snippet-count store) 1))))

(test-case "snippet persistence round-trip"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-snippet-store (snippets-path)))
     (snippet-save! store "Signature" "— Fulcrum team" "sig")
     (define reloaded (make-snippet-store (snippets-path)))
     (check-equal? (snippet-count reloaded) 1)
     (check-equal? (snippet-keyword (car (snippet-list reloaded))) "sig"))))


(test-case "portable snippets export/import preserves IDs, timestamps and contents"
  (with-fresh-data-dir
   (lambda ()
     (define original (make-snippet-store (snippets-path)))
     (define a (snippet-save! original "Greeting" "Hello\nworld" "hi"))
     (define b (snippet-save! original "Closing" "Best regards" "bye"))
     (define bundle (build-path (data-dir) "portable-snippets.json"))
     (check-equal? (snippet-export! original (path->string bundle)) 2)
     (define exported (call-with-input-file bundle read-json))
     (check-equal? (hash-ref exported 'format) "fulcrum-snippets")
     (check-equal? (hash-ref exported 'version) 1)
     (define elsewhere (build-path (data-dir) "restored.json"))
     (define restored (make-snippet-store elsewhere))
     (check-equal? (snippet-import! restored (path->string bundle)) 2)
     (check-equal? (snippet-list restored) (snippet-list original))
     (check-equal? (snippet-id (snippet-by-keyword restored "HI")) (snippet-id a))
     (check-equal? (snippet-ts (snippet-ref restored (snippet-id b))) (snippet-ts b))
     ;; Reimport is idempotent and never duplicates the same identities.
     (check-equal? (snippet-import! restored (path->string bundle)) 2)
     (check-equal? (snippet-count restored) 2)
     (check-exn exn:fail? (lambda () (snippet-export! original (path->string bundle))))
     (check-equal? (snippet-count original) 2))))

(test-case "malformed or conflicting snippet bundles never partially import"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-snippet-store (snippets-path)))
     (define local (snippet-save! store "Local" "precious" "claimed"))
     (define path (build-path (data-dir) "unsafe.json"))
     (define (put value)
       (call-with-output-file path
         (lambda (out) (write-json value out))
         #:exists 'replace))
     (define (bundle items)
       (hasheq 'format "fulcrum-snippets" 'version 1 'snippets items))
     (define (entry id keyword text)
       (hasheq 'id id 'name id 'keyword keyword 'text text 'ts 123))
     (put (bundle (list (entry "other" "free" "valid")
                        (entry "collision" "CLAIMED" "unsafe"))))
     (check-exn exn:fail? (lambda () (snippet-import! store (path->string path))))
     (check-equal? (snippet-list store) (list local))
     ;; Invalid fields and duplicate IDs reject an entire bundle.
     (put (bundle (list (entry "new" "new" "ok")
                        (hasheq 'id "bad" 'name "Bad" 'keyword "oops" 'text 3 'ts 1))))
     (check-exn exn:fail? (lambda () (snippet-import! store (path->string path))))
     (put (bundle (list (entry "dup" "x" "a") (entry "dup" "y" "b"))))
     (check-exn exn:fail? (lambda () (snippet-import! store (path->string path))))
     (call-with-output-file path
       (lambda (out) (display "{\"format\":" out))
       #:exists 'replace)
     (check-exn exn:fail? (lambda () (snippet-import! store (path->string path))))
     (check-equal? (snippet-list store) (list local)))))
