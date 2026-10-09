#lang racket/base

;; Settings manager tests over rivet/system's atomic settings store: typed
;; defaults, invalid-write rejection, stale-value fallback, round-trip.

(require racket/file
         racket/string
         rackunit
         "../app/core/settings.rkt")

(define (call-with-settings thunk)
  (define dir (make-temporary-file "fulcrum-settest-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (thunk dir))
    (lambda () (delete-directory/files dir))))

(test-case "defaults are typed and complete"
  (call-with-settings
   (lambda (dir)
     (define s (make-settings-manager (build-path dir "settings.json")))
     (check-equal? (settings-get s 'theme) "system")
     (check-equal? (settings-get s 'hotkey) "alt+space")
     (check-equal? (settings-get s 'max-results) 12)
     (check-true (settings-get s 'clipboard-enabled))
     (check-equal? (settings-get s 'default-engine) "!g")
     (check-equal? (settings-get s 'update-base-url)
                   "https://github.com/turinglambdaai/fulcrum/releases/latest/download"))))

(test-case "valid writes round-trip and persist"
  (call-with-settings
   (lambda (dir)
     (define path (build-path dir "settings.json"))
     (define s (make-settings-manager path))
     (check-true (settings-set! s 'theme "dark"))
     (check-equal? (settings-get s 'theme) "dark")
     (check-true (settings-set! s 'max-results 18))
     (check-equal? (settings-get s 'max-results) 18)
     (define reloaded (make-settings-manager path))
     (check-equal? (settings-get reloaded 'theme) "dark"))))

(test-case "invalid writes raise, unknown keys raise"
  (call-with-settings
   (lambda (dir)
     (define s (make-settings-manager (build-path dir "settings.json")))
     (check-exn exn:fail? (lambda () (settings-set! s 'theme "neon")))
     (check-exn exn:fail? (lambda () (settings-set! s 'max-results 999)))
     (check-exn exn:fail? (lambda () (settings-set! s 'not-a-key 1)))
     (check-exn exn:fail? (lambda () (settings-get s 'not-a-key))))))(test-case "stale stored values fall back to defaults"
  (call-with-settings
   (lambda (dir)
     (define path (build-path dir "settings.json"))
     ;; Simulate a hand-edited file with an out-of-schema value.
     (call-with-output-file path
       (lambda (out) (write-string "{\"theme\":\"banner\",\"max-results\":4000}" out))
       #:exists 'truncate)
     (define s (make-settings-manager path))
     (check-equal? (settings-get s 'theme) "system")
     (check-equal? (settings-get s 'max-results) 12))))

(test-case "settings-list enumerates every key with a description"
  (call-with-settings
   (lambda (dir)
     (define s (make-settings-manager (build-path dir "settings.json")))
     (define entries (settings-list s))
     (check-true (>= (length entries) 10))
     (check-true (andmap (lambda (e) (and (non-empty-string? (settings-entry-key e))
                                          (non-empty-string? (settings-entry-description e))))
                         entries)))))
