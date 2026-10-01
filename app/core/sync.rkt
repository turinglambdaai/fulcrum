#lang racket/base

;; Local-first sync for settings and snippets (the sync beta).
;;
;; The user points `sync-root` at any directory a file sync service
;; replicates (iCloud Drive, Dropbox, OneDrive, Syncthing, a git repo).
;; Fulcrum mirrors its settings.json and snippets.json there after every
;; write, and on startup restores the local copy from the mirror when the
;; mirror is newer or the local file is gone — that is the whole
;; wipe-and-restore story.
;;
;; Conflict policy is newest-file-wins by mtime, which is honest about
;; what a file sync service can offer: two machines edited at nearly the
;; same moment resolve to whichever write landed last. Clipboard history
;; and recents are deliberately not synced: high-churn, machine-local,
;; and the first place a privacy-minded user would look.

(require racket/file
         racket/path)

(provide sync-mirror-path
         sync-restore!
         sync-mirror!)

;; The mirror lives under one subdirectory so the sync root can be shared
;; (a dedicated directory also survives services that sync everything).
(define (sync-mirror-path sync-root local-path)
  (build-path sync-root "fulcrum" (file-name-from-path local-path)))

;; Called when a store is constructed: if the mirror is newer than the
;; local file (or the local file is missing), restore local from the
;; mirror; otherwise, if the local file is newer, prime the mirror.
;; Returns 'restored, 'primed, or 'none.
(define (sync-restore! local-path sync-root)
  (if (or (not sync-root) (string=? sync-root ""))
      'none
      (let ([mirror (sync-mirror-path sync-root local-path)])
        (with-handlers ([exn:fail? (lambda (_) 'none)])
          (define local-exists? (file-exists? local-path))
          (define mirror-exists? (file-exists? mirror))
          (cond
            [(and mirror-exists?
                  (or (not local-exists?)
                      (> (file-or-directory-modify-seconds mirror)
                         (file-or-directory-modify-seconds local-path))))
             (make-directory* (path-only local-path))
             (copy-file mirror local-path #t)
             'restored]
            [(and local-exists? (not mirror-exists?))
             (sync-mirror! local-path sync-root)
             'primed]
            [else 'none])))))

;; Copy local over the mirror after a successful local write. Best-effort:
;; a missing or read-only sync volume must not fail every save while the
;; app still works locally. The next successful write re-mirrors.
(define (sync-mirror! local-path sync-root)
  (unless (or (not sync-root) (string=? sync-root ""))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define mirror (sync-mirror-path sync-root local-path))
      (make-directory* (path-only mirror))
      (copy-file local-path mirror #t))))
