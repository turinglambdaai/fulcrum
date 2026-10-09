#lang racket/base

;; Compose and sign the stable-channel update manifest from the final
;; per-platform release archives, then verify the signed output against the
;; public key before it is published. Run from the repository root after
;; `raco pkg link` on the Rivet checkout; see release.yml's update-manifest
;; job for the environment contract:
;;   RIVET_UPDATE_BASE_URL     downloads origin (e.g. https://.../fulcrum)
;;   RIVET_UPDATE_KEY_ID       signing key id embedded in the wrapper
;;   UPDATE_PRIVATE_DER        path to the Ed25519 private key (DER)
;;   UPDATE_PUBLIC_DER         path to the matching public key (DER)
;; The release installers must exist under release/ (fulcrum-macos.dmg,
;; fulcrum-windows-x64.msi, fulcrum-linux-x64.tar.gz); the URLs written
;; into the manifest are $BASE_URL/<name>.

(require racket/file
         racket/format
         racket/string
         rivet/distribution)

(define (rktd-field field)
  (define text (file->string "rivet.rktd"))
  (define m (regexp-match
             (pregexp (string-append "\\(" field " \\. \"?([^)\"]+)\"?\\)")) text))
  (or (and m (cadr m))
      (error 'sign-manifest "rivet.rktd is missing the ~a field" field)))

(define (env-required name)
  (define value (getenv name))
  (unless (and value (not (string=? (string-trim value) "")))
    (error 'sign-manifest "required environment variable ~a is not set" name))
  (string-trim value))

(define base-url (env-required "RIVET_UPDATE_BASE_URL"))
(define key-id (env-required "RIVET_UPDATE_KEY_ID"))
(define private-der (or (getenv "UPDATE_PRIVATE_DER") "update-private.der"))
(define public-der (or (getenv "UPDATE_PUBLIC_DER") "update-public.der"))

(define version (rktd-field "version"))
(define build (string->number (rktd-field "build")))
(define channel (rktd-field "release-channel"))
(define identifier (rktd-field "identifier"))

(define base (string-trim base-url "/"))
(define (artifact-for name platform arch installer)
  (define path (build-path "release" name))
  (unless (file-exists? path)
    (error 'sign-manifest "release installer is missing: ~a" path))
  (update-artifact platform arch
                   (string-append base "/" name)
                   (sha256-file/hex path)
                   (file-size path)
                   installer
                   '()))

(define published-at
  (let ([d (seconds->date (current-seconds) #t)])
    (format "~a-~a-~aT~a:~a:~aZ"
            (~r (date-year d) #:min-width 4 #:pad-string "0")
            (~r (date-month d) #:min-width 2 #:pad-string "0")
            (~r (date-day d) #:min-width 2 #:pad-string "0")
            (~r (date-hour d) #:min-width 2 #:pad-string "0")
            (~r (date-minute d) #:min-width 2 #:pad-string "0")
            (~r (date-second d) #:min-width 2 #:pad-string "0"))))

(define manifest
  (update-manifest identifier version build (string->symbol channel)
                   published-at
                   "0.0.0" #f #t 100
                   (list (artifact-for "fulcrum-macos.dmg" 'macos 'arm64 'dmg)
                         (artifact-for "fulcrum-windows-x64.msi" 'windows 'x64 'msi)
                         (artifact-for "fulcrum-linux-x64.tar.gz" 'linux 'x64 'targz))))

(define private-key (read-ed25519-private-key private-der))
(define public-key (read-ed25519-public-key public-der))
(unless (or (file-exists? "dist") (directory-exists? "dist"))
  (make-directory "dist"))
(define manifest-path (build-path "dist" "manifest.json"))
(call-with-output-file manifest-path #:exists 'truncate/replace
  (lambda (out) (write-signed-manifest manifest private-key key-id out)))
;; Fail the job if anything about the signed output would be rejected by a
;; client verifying with the published public key.
(call-with-input-file manifest-path
  (lambda (in) (verify-signed-manifest in public-key #:key-id key-id)))
(displayln "update manifest signed and verified")
