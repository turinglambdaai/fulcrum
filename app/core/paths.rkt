#lang racket/base

;; Fulcrum data locations.
;;
;; Every store the backend owns (settings, clipboard history, snippets,
;; recents, plugins, logs) lives under one platform data directory so
;; uninstall/cleanup and privacy review have a single answer.
;;
;; FULCRUM_DATA_DIR overrides the location for development and tests; it is
;; honored before any platform convention so headless CI can pin a tmpdir.

(require racket/bool
         racket/file
         racket/path)

(provide data-dir
         ensure-data-dir!
         settings-path
         clipboard-path
         snippets-path
         quicklinks-path
         recents-path
         plugins-dir
         sync-root-override)

(define (env-override)
  (let ([value (getenv "FULCRUM_DATA_DIR")])
    (and (string? value) (not (string=? value "")) value)))

;; FULCRUM_SYNC_DIR points sync at a directory regardless of the stored
;; sync-root setting. It exists because the setting itself lives in the
;; file sync would restore: on a wiped machine (or in tests) the
;; environment is the only bootstrap that can precede the restore.
(define (sync-root-override)
  (let ([value (getenv "FULCRUM_SYNC_DIR")])
    (and (string? value) (not (string=? value "")) value)))

(define (platform-data-dir)
  (case (system-type 'os)
    [(macosx)
     (build-path (find-system-path 'home-dir)
                 "Library" "Application Support" "Fulcrum")]
    [(windows)
     (define appdata (or (getenv "APPDATA")
                         (path->string (find-system-path 'pref-dir))))
     (build-path appdata "Fulcrum")]
    [else
     (define xdg (or (getenv "XDG_DATA_HOME")
                     (path->string
                      (build-path (find-system-path 'home-dir)
                                  ".local" "share"))))
     (build-path xdg "fulcrum")]))

(define (data-dir)
  (define override (env-override))
  (if override
      (simple-form-path override)
      (platform-data-dir)))

(define (ensure-data-dir!)
  (define dir (data-dir))
  (unless (directory-exists? dir)
    (make-directory* dir))
  dir)

(define (settings-path)
  (build-path (data-dir) "settings.json"))

(define (clipboard-path)
  (build-path (data-dir) "clipboard.json"))

(define (snippets-path)
  (build-path (data-dir) "snippets.json"))

(define (quicklinks-path)
  (build-path (data-dir) "quicklinks.json"))

(define (recents-path)
  (build-path (data-dir) "recents.json"))

(define (plugins-dir)
  (build-path (ensure-data-dir!) "plugins"))
