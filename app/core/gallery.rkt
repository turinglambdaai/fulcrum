#lang racket/base

;; First-party plugin gallery.
;;
;; The gallery catalog is the embedded plugin payload (gallery-data.rkt,
;; generated from gallery/ by scripts/gen-gallery.rkt). Installing a plugin
;; materializes its files into the plugins directory: everything except
;; manifest.json first, then the manifest, into a staging directory that is
;; renamed into place — so the loader never sees a half-written plugin.
;;
;; Uninstall refuses directories without the gallery marker file: gallery
;; actions may only remove plugins the gallery itself installed, never
;; user-installed ones.

(require json
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/string
         "gallery-data.rkt")

(provide (struct-out gallery-entry)
         gallery-catalog
         gallery-entry-installed?
         gallery-install!
         gallery-uninstall!)

(struct gallery-entry (id name version description commands permissions) #:transparent)

(define marker-file ".fulcrum-gallery")

;; Plugin ids come from the wire (the run-action arg) as well as from the
;; catalog, so they are validated before ever touching the filesystem:
;; lowercase letters, digits, and dashes. This is the path-traversal guard
;; for install/uninstall.
(define (safe-plugin-id? id)
  (and (string? id)
       (<= 1 (string-length id) 64)
       (regexp-match? #px"^[a-z0-9][a-z0-9-]*$" id)))

;; JSON object: {plugin-id: {relative-path: file-content}}, keys as symbols.
(define (gallery-payload)
  (with-handlers ([exn:fail? (lambda (_) (hash))])
    (define parsed (string->jsexpr gallery-blob))
    (if (hash? parsed) parsed (hash))))

(define (payload->entries payload)
  (for/list ([id (in-hash-keys payload)])
    (define files (hash-ref payload id))
    (define manifest
      (with-handlers ([exn:fail? (lambda (_) (hash))])
        (string->jsexpr (hash-ref files 'manifest.json ""))))
    (gallery-entry (symbol->string id)
                   (or (and (hash? manifest) (hash-ref manifest 'name #f)) (symbol->string id))
                   (or (and (hash? manifest) (hash-ref manifest 'version #f)) "0.0.0")
                   (or (and (hash? manifest) (hash-ref manifest 'description #f)) "")
                   (let ([commands (and (hash? manifest) (hash-ref manifest 'commands #f))])
                     (if (list? commands)
                         (for/list ([c (in-list commands)]
                                    #:when (hash? c)
                                    #:when (string? (hash-ref c 'keyword #f)))
                           (hash-ref c 'keyword))
                         '()))
                   (let ([perms (and (hash? manifest) (hash-ref manifest 'permissions #f))])
                     (if (list? perms) (filter string? perms) '())))))

;; Sorted by name so hosts and tests see a stable order.
(define (gallery-catalog)
  (sort (payload->entries (gallery-payload)) string<? #:key gallery-entry-name))

(define (plugin-dir plugins-dir id)
  (build-path plugins-dir (string->path id)))

(define (gallery-entry-installed? plugins-dir entry)
  (file-exists? (build-path (plugin-dir plugins-dir (gallery-entry-id entry))
                            "manifest.json")))

(define/contract (gallery-install! plugins-dir id)
  (-> path? string? (or/c string? #f))
  ;; Returns #f on success or an error string; the engine surfaces it.
  (define files
    (hash-ref (gallery-payload) (string->symbol id) #f))
  (cond
    [(not (safe-plugin-id? id)) (format "invalid plugin id: ~a" id)]
    [(not files) (format "unknown gallery plugin: ~a" id)]
    [else
     (define final-dir (plugin-dir plugins-dir id))
     (cond
       [(directory-exists? final-dir)
        (format "already installed: ~a" id)]
       [else
        (define staging
          (build-path plugins-dir
                      (format ".install-~a-~a" id (current-inexact-milliseconds))))
        (with-handlers ([exn:fail?
                         (lambda (e)
                           (with-handlers ([exn:fail? (lambda (_) (void))])
                             (delete-directory/files staging))
                           (format "install failed: ~a" (exn-message e)))])
          ;; Manifest last, so an interrupted write never loads.
          (for ([name (in-hash-keys files)]
                #:unless (equal? name 'manifest.json))
            (define target (build-path staging (string->path (symbol->string name))))
            (make-directory* (path-only target))
            (display-to-file (hash-ref files name) target #:exists 'replace))
          (display-to-file (hash-ref files 'manifest.json)
                           (build-path staging "manifest.json")
                           #:exists 'replace)
          (display-to-file "" (build-path staging marker-file) #:exists 'replace)
          (rename-file-or-directory staging final-dir)
          #f)])]))

(define/contract (gallery-uninstall! plugins-dir id)
  (-> path? string? (or/c string? #f))
  (cond
    [(not (safe-plugin-id? id)) (format "invalid plugin id: ~a" id)]
    [(not (directory-exists? (plugin-dir plugins-dir id)))
     (format "not installed: ~a" id)]
    [(not (file-exists? (build-path (plugin-dir plugins-dir id) marker-file)))
     (format "refusing to remove non-gallery plugin: ~a" id)]
    [else
     (with-handlers ([exn:fail?
                      (lambda (e) (format "uninstall failed: ~a" (exn-message e)))])
       (delete-directory/files (plugin-dir plugins-dir id))
       #f)]))
