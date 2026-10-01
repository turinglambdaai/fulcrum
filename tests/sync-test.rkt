#lang racket/base

;; Sync beta tests: mirror-on-write for settings and snippets, restore of a
;; wiped data directory via FULCRUM_SYNC_DIR, newest-wins conflict policy,
;; and the bootstrap precedence (environment beats the stored setting).

(require json
         racket/file
         racket/string
         rackunit
         "../app/core/paths.rkt"
         "../app/core/settings.rkt"
         "../app/core/snippets.rkt"
         "../app/core/sync.rkt")

(define (with-dirs thunk)
  (define data-dir (make-temporary-file "fulcrum-syncdata-~a" 'directory))
  (define sync-dir (make-temporary-file "fulcrum-syncroot-~a" 'directory))
  (parameterize ([current-environment-variables
                  (let ([env (current-environment-variables)])
                    (environment-variables-set! env #"FULCRUM_SYNC_DIR"
                                                (string->bytes/utf-8 (path->string sync-dir)))
                    env)])
    (dynamic-wind
      (lambda () (thunk data-dir sync-dir))
      void
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files data-dir)
          (delete-directory/files sync-dir))))))

(define (settings-path-in dir) (build-path dir "settings.json"))
(define (mirror-for sync-root name)
  (build-path sync-root "fulcrum" name))

(test-case "settings mirror on every write and restore a wiped data dir"
  (with-dirs
   (lambda (data-dir sync-root)
     (define path (settings-path-in data-dir))
     (define m (make-settings-manager path))
     (check-true (settings-set! m 'theme "dark"))
     ;; The mirror exists and carries the write.
     (check-true (file-exists? (mirror-for sync-root "settings.json")))

     ;; A new manager on the same file agrees; now wipe the data dir and
     ;; rebuild: FULCRUM_SYNC_DIR must bring the file back.
     (check-equal? (settings-get (make-settings-manager path) 'theme) "dark")
     (delete-directory/files data-dir)
     (make-directory* data-dir)
     (check-false (file-exists? path))
     (define restored (make-settings-manager path))
     (check-equal? (settings-get restored 'theme) "dark")
     (check-true (file-exists? path)))))

(test-case "newer mirror wins over an older local file"
  (with-dirs
   (lambda (data-dir sync-root)
     (define path (settings-path-in data-dir))
     (define m (make-settings-manager path))
     (settings-set! m 'theme "dark")
     ;; Advance the mirror far into the future and change a value by hand:
     ;; restore must prefer the newer mirror regardless of content source.
     (sleep 1.1)
     (call-with-output-file (mirror-for sync-root "settings.json") #:exists 'replace
       (lambda (out) (write-string "{\"theme\":\"light\"}" out)))
     (define reloaded (make-settings-manager path))
     (check-equal? (settings-get reloaded 'theme) "light"))))

(test-case "no sync root: no mirror, no failure"
  (with-dirs
   (lambda (data-dir sync-root)
     ;; Point the override at a fresh empty root? No — remove it: an empty
     ;; FULCRUM_SYNC_DIR behaves like none at all.
     (parameterize ([current-environment-variables
                     (let ([env (current-environment-variables)])
                       (environment-variables-set! env #"FULCRUM_SYNC_DIR" #"")
                       env)])
       (define path (settings-path-in data-dir))
       (define m (make-settings-manager path))
       (check-true (settings-set! m 'theme "dark"))
       (check-false (directory-exists? (build-path sync-root "fulcrum")))))))

(test-case "stored sync-root mirrors without an environment override"
  (with-dirs
   (lambda (data-dir sync-root)
     (parameterize ([current-environment-variables
                     (let ([env (current-environment-variables)])
                       (environment-variables-set! env #"FULCRUM_SYNC_DIR" #"")
                       env)])
       (define path (settings-path-in data-dir))
       (define m (make-settings-manager path))
       (settings-set! m 'sync-root (path->string sync-root))
       (settings-set! m 'theme "dark")
       (check-true (file-exists? (mirror-for sync-root "settings.json")))
       (define mirrored
         (call-with-input-file (mirror-for sync-root "settings.json") read-json))
       (check-equal? (hash-ref mirrored 'theme) "dark")))))

(test-case "snippets mirror and restore like settings"
  (with-dirs
   (lambda (data-dir sync-root)
     (define path (build-path data-dir "snippets.json"))
     (define store (make-snippet-store path #:sync-root (path->string sync-root)))
     (snippet-save! store "Release checklist" "text" "rel")
     (check-true (file-exists? (mirror-for sync-root "snippets.json")))

     ;; Wipe and restore through the same constructor the backend calls.
     (delete-directory/files data-dir)
     (make-directory* data-dir)
     (define revived (make-snippet-store path #:sync-root (path->string sync-root)))
     (check-equal? (snippet-count revived) 1)
     (check-equal? (snippet-name (car (snippet-list revived)))
                   "Release checklist"))))

(test-case "sync-restore! reports what it did"
  (with-dirs
   (lambda (data-dir sync-root)
     (define path (build-path data-dir "notes.json"))
     ;; Nothing anywhere: none.
     (check-equal? (sync-restore! path (path->string sync-root)) 'none)
     ;; Local only: the mirror is primed.
     (call-with-output-file path (lambda (out) (write-string "{}" out)))
     (check-equal? (sync-restore! path (path->string sync-root)) 'primed)
     (check-true (file-exists? (mirror-for sync-root "notes.json")))
     ;; Newer mirror: restored.
     (sleep 1.1)
     (call-with-output-file (mirror-for sync-root "notes.json") #:exists 'replace
       (lambda (out) (write-string "{\"v\":2}" out)))
     (check-equal? (sync-restore! path (path->string sync-root)) 'restored)
     (check-equal? (hash-ref (call-with-input-file path read-json) 'v) 2))))
