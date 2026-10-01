#lang racket/base

;; Plugin gallery tests: catalog integrity, install/uninstall lifecycle
;; through the real engine actions, the non-gallery refusal guard, and the
;; path-traversal guard on wire-supplied ids. Plugin *queries* after
;; install only assert against the manifest load (no subprocess spawns),
;; except a real `ts` query when python3 exists, mirroring CI reality.

(require racket/file
         racket/list
         racket/string
         rackunit
         "../app/core/engine.rkt"
         "../app/core/gallery.rkt"
         "../app/core/paths.rkt"
         "../app/core/plugins.rkt")

(define (row-id row) (list-ref row 0))
(define (row-arg row) (list-ref row 4))
(define (row-badge row) (list-ref row 7))

(define (with-fresh-data-dir thunk)
  (define dir (make-temporary-file "fulcrum-galtest-~a" 'directory))
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

;; An engine with a live plugin manager over the (env-pinned) plugins dir.
(define (gallery-engine)
  (make-engine #:clipboard-store #f
               #:snippet-store #f
               #:plugin-manager (make-plugin-manager (plugins-dir))))

(test-case "catalog is complete, unique, and stable"
  (define catalog (gallery-catalog))
  (check-equal? (length catalog) 11)
  (check-equal? (length (remove-duplicates (map gallery-entry-id catalog)))
                (length catalog))
  (check-true (equal? catalog
                      (sort catalog string<? #:key gallery-entry-name)))
  (for ([entry (in-list catalog)])
    (check-true (non-empty-string? (gallery-entry-id entry)))
    (check-true (non-empty-string? (gallery-entry-name entry)))
    (check-true (non-empty-string? (gallery-entry-version entry)))
    (check-true (list? (gallery-entry-permissions entry)))))

(test-case "install/uninstall ride the engine actions end to end"
  (with-fresh-data-dir
   (lambda ()
     (define engine (gallery-engine))

     ;; Listing: query "gallery" shows every entry once, with the right
     ;; action per install state. (Other providers may add unrelated rows,
     ;; e.g. the web fallback — count only gallery actions.)
     (define rows (engine-search engine "gallery"))
     (define gallery-rows
       (filter (lambda (row) (member (row-id row) '("gallery.install" "gallery.uninstall")))
               rows))
     (check-equal? (length gallery-rows) 11)
     (check-true (andmap (lambda (row) (pair? (member (row-id row) '("gallery.install" "gallery.uninstall"))))
                         gallery-rows))

     ;; Install epoch through the engine action: "ok" plus a notify event.
     (define outcome (engine-run engine "gallery.install" "epoch"))
     (check-equal? (car outcome) "ok")
     (check-equal? (map car (cdr outcome)) '(notify))

     ;; The reload inside the action makes epoch queryable immediately.
     (check-not-false (findf (lambda (p) (string=? (plugin-id p) "epoch"))
                             (plugin-manager-plugins
                              (engine-plugins engine))))
     ;; Unknown id and double install are loud errors, not no-ops.
     (check-true (string-contains? (car (engine-run engine "gallery.install" "nope"))
                                   "unknown"))
     (check-true (string-contains? (car (engine-run engine "gallery.install" "epoch"))
                                   "already installed"))

     ;; The installed entry now offers uninstall in the listing.
     (define after (engine-search engine "gallery"))
     (define epoch-row
       (findf (lambda (row) (and (equal? (row-id row) "gallery.uninstall")
                                 (equal? (row-arg row) "epoch")))
              after))
     (check-true (and epoch-row #t))
     (check-equal? (row-badge epoch-row) "Installed")

     ;; Uninstall again through the engine.
     (check-equal? (car (engine-run engine "gallery.uninstall" "epoch")) "ok")
     (check-false (directory-exists? (build-path (plugins-dir) "epoch"))))))

(test-case "uninstall refuses plugins the gallery did not install"
  (with-fresh-data-dir
   (lambda ()
     (define engine (gallery-engine))
     ;; A user-installed plugin: manifest present, no gallery marker.
     (define dir (build-path (plugins-dir) "users-own"))
     (make-directory* dir)
     (call-with-output-file (build-path dir "manifest.json")
       (lambda (out)
         (write-string "{\"id\":\"users-own\",\"name\":\"Own\",\"entry\":{\"exec\":[\"x\"]}}" out)))
     (define outcome (engine-run engine "gallery.uninstall" "users-own"))
     (check-true (string-contains? (car outcome) "refusing"))
     (check-true (directory-exists? dir)))))

(test-case "wire-supplied ids cannot escape the plugins directory"
  (with-fresh-data-dir
   (lambda ()
     (define engine (gallery-engine))
     (check-true (string-contains? (car (engine-run engine "gallery.uninstall" "../settings"))
                                   "invalid plugin id"))
     (check-true (string-contains? (car (engine-run engine "gallery.install" "a/b"))
                                   "invalid plugin id")))))

(test-case "fuzzy queries suggest installs for missing plugins"
  (with-fresh-data-dir
   (lambda ()
     (define engine (gallery-engine))
     (define rows (engine-search engine "unit converter"))
     (define install-row
       (findf (lambda (row) (and (equal? (row-id row) "gallery.install")
                                 (equal? (row-arg row) "unit")))
              rows))
     (check-true (and install-row #t))
     (check-equal? (row-badge install-row) "Install"))))

(test-case "installed epoch answers a real query when python3 exists"
  (with-fresh-data-dir
   (lambda ()
     (unless (find-executable-path "python3")
       (displayln "gallery-test: python3 not on PATH; skipping spawn assertion"))
     (define engine (gallery-engine))
     (check-equal? (car (engine-run engine "gallery.install" "epoch")) "ok")
     ;; The installed plugin's manifest lists the ts command; the engine's
     ;; plugin provider claims "ts …" queries. Only meaningful with the
     ;; interpreter present (CI runners all have python3) — except Windows
     ;; runners, where PATH carries the Microsoft Store python3.exe *alias
     ;; stub*, which exists but is not an interpreter, so the spawn yields
     ;; no rows.
     (when (and (find-executable-path "python3")
                (not (equal? (system-type 'os) 'windows)))
       (define rows (engine-search engine "ts 1700000000"))
       (check-true (pair? (findf (lambda (row) (equal? (row-id row) "plugin:epoch:convert"))
                                 rows))))))) 
