#lang racket/base

;; Per-command bindings (#48): store persistence and validation, and the
;; ranking contract — an alias surfaces its command without plugin grammar.

(require racket/file
         rackunit
         "../app/core/bindings.rkt"
         "../app/core/engine.rkt"
         "../app/core/paths.rkt")

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-bindtest-~a" 'directory))
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

(test-case "bindings persist and round-trip"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-bindings-store))
     (binding-set! store "sys.run:Lock Screen" "lock" "ctrl+alt+l")
     (binding-set! store "win.left" "lh" #f)
     ;; A second store over the same file sees exactly the same bindings.
     (define reloaded (make-bindings-store))
     (define lock (binding-lookup reloaded "sys.run:Lock Screen"))
     (check-true (binding? lock))
     (check-equal? (binding-alias lock) "lock")
     (check-equal? (binding-hotkey lock) "ctrl+alt+l")
     (check-equal? (binding-alias (binding-lookup reloaded "win.left")) "lh")
     (check-equal? (length (bindings-list-all reloaded)) 2))))

(test-case "binding validation"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-bindings-store))
     (check-exn exn:fail:contract?
                (lambda () (binding-set! store "win.left" "  padded  " #f)))
     (check-exn exn:fail:contract?
                (lambda () (binding-set! store "win.left" (make-string 40 #\a) #f)))
     (check-exn exn:fail:contract?
                (lambda () (binding-set! store "win.left" #f "ctrl+shift+")))
     (check-exn exn:fail:contract?
                (lambda () (binding-set! store "win.left" #f "space")))
     ;; Neither field is a set — clearing goes through binding-clear!.
     (check-exn exn:fail:contract? (lambda () (binding-set! store "win.left" #f #f)))
     (check-equal? (bindings-list-all store) '()))))

(test-case "clear removes and reports"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-bindings-store))
     (binding-set! store "win.left" "lh" #f)
     (check-true (binding-clear! store "win.left"))
     (check-false (binding-lookup store "win.left"))
     ;; Clearing a missing binding is false, not a lie.
     (check-false (binding-clear! store "win.left")))))

(test-case "aliases join ranking fields"
  (with-fresh-data-dir
   (lambda ()
     (define store (make-bindings-store))
     (binding-set! store "win.left" "lh" #f)
     (define eng (make-engine #:clipboard-store #f
                              #:snippet-store #f
                              #:bindings-store store
                              #:plugin-manager #f))
     ;; The alias alone surfaces the command; without the binding it would
     ;; not rank (the keywords list only spells out "window left half tile").
     (define rows (engine-search eng "lh"))
     (check-true (pair? rows))
     (check-equal? (list-ref (car rows) 0) "win.left")
     ;; The bare command name still ranks as before.
     (define by-name (engine-search eng "left half"))
     (check-true (pair? by-name))
     (check-equal? (list-ref (car by-name) 0) "win.left"))))

(test-case "engine without a bindings store still searches"
  (with-fresh-data-dir
   (lambda ()
     (define eng (make-engine #:clipboard-store #f
                              #:snippet-store #f
                              #:plugin-manager #f))
     (define rows (engine-search eng "left half"))
     (check-true (pair? rows))
     (check-equal? (list-ref (car rows) 0) "win.left"))))

(test-case "failed atomic writes do not expose transient bindings"
  (define dir (make-temporary-file "fulcrum-binding-io-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "bindings.json"))
     (define store (make-bindings-store path))
     (binding-set! store "win.left" "left" "ctrl+alt+l")
     ;; A directory at the store path forces the atomic rename to fail,
     ;; independently of permission differences on CI runners.
     (rename-file-or-directory path (build-path dir "saved.json"))
     (make-directory path)
     (check-exn exn:fail?
                (lambda ()
                  (binding-set! store "win.left" "changed" "ctrl+alt+m")))
     (check-equal? (binding-alias (binding-lookup store "win.left")) "left")
     (check-exn exn:fail?
                (lambda () (binding-clear! store "win.left")))
     (check-true (binding? (binding-lookup store "win.left")))
     ;; A fresh store can still recover the last committed snapshot.
     (define reloaded (make-bindings-store (build-path dir "saved.json")))
     (check-equal? (binding-alias (binding-lookup reloaded "win.left")) "left"))
   (lambda () (delete-directory/files dir))))
