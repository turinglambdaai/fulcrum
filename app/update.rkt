#lang racket/base

;; Fulcrum update wiring over `rivet/distribution`.
;;
;; Trust model (inherited from Rivet): HTTPS protects transport but is not
;; the root of update trust. The channel manifest is Ed25519-signed and
;; verified against the public key embedded below before any version
;; decision. Developer builds carry no key, so update-check reports that
;; honestly instead of pretending to check.
;;
;; Key management lives in docs/release-runbook.md: key generation, the exact
;; replacement of `current-update-public-key-hex`, and rotation via
;; `current-update-key-id` (ship a client trusting the next key before
;; signing with it).
;;
;; v0.1 reports available versions and hands installation to the platform
;; installer surfaced by the host; in-app install/download/rollback is the
;; 0.2 updater milestone and will use download-update/execute-install-plan!.

(require rivet/distribution)

(provide fulcrum-update-check
         fulcrum-update-configured?)

;; Ed25519 public key (DER SPKI), hex-encoded — committed on purpose: the
;; public half only enables verification. Rotation replaces this hex and the
;; key id below (ship clients trusting the next key before signing with it).
;; Key fingerprint: sha256(DER)[:16] = 60b7ce3b8a255465; private half lives in
;; the keys vault and the RIVET_UPDATE_PRIVATE_KEY repository secret.
(define current-update-public-key-hex
  "302a300506032b65700321004797203e4e1fce109e45d41ba755e87eb7d261c082b5bf6728ae0eaaa58e55d7")
(define current-update-key-id "fulcrum-2026-10")

(define (hex->bytes s)
  (let ([n (string-length s)])
    (if (and (even? n) (>= n 2))
        (apply bytes (for/list ([i (in-range 0 n 2)])
                       (string->number (substring s i (+ i 2)) 16)))
        #f)))

;; The manifest verifier takes a parsed key object, not raw DER — this
;; conversion is what stands between an update check and a contract
;; violation at ed25519-verify (every 0.4.x check failed exactly there).
;; Lazy on purpose: FFI at module-import time kills embedded apps at
;; startup (the landmine rivet/distribution/crypto.rkt documents), so the
;; parse happens at check time like taskly's embedded-public-key; a
;; failure there surfaces as an honest "update check failed: ..." instead
;; of a dead app. bytes->ed25519-public-key pins the libcrypto factory
;; explicitly and exists since rivet 2e1924c — the RIVET_PIN snapshot.
(define (current-update-public-key)
  (bytes->ed25519-public-key (hex->bytes current-update-public-key-hex)))

(define (fulcrum-update-configured?)
  (and current-update-public-key-hex
       (hex->bytes current-update-public-key-hex)
       #t))

(define (fulcrum-update-check current-version base-url)
  (unless (string? current-version)
    (raise-argument-error 'fulcrum-update-check "string?" current-version))
  (unless (or (not base-url) (string? base-url))
    (raise-argument-error 'fulcrum-update-check "(or/c string? #f)" base-url))
  (cond
    [(not (fulcrum-update-configured?))
     "updates unavailable: developer build (no update key configured)"]
    [(or (not base-url) (string=? base-url ""))
     "updates unavailable: no update base URL configured"]
    [else
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (format "update check failed: ~a" (exn-message e)))])
       (define manifest
         (fetch-update-manifest
          (string-append (regexp-replace* #rx"/+$" base-url "")
                         "/manifest.json")
          (current-update-public-key)
          #:key-id current-update-key-id
          #:maximum-bytes (* 4 1024 1024)))
       (define config
         (updater-config "site.jrtx.fulcrum"
                         current-version
                         'stable
                         (case (system-type 'os)
                           [(macosx) 'macos]
                           [(windows) 'windows]
                           [else 'linux])
                         ;; Family architecture vocabulary (rivet's own
                         ;; release flow and taskly's updater both speak
                         ;; arm64/x64); the signed manifest must use the
                         ;; same symbols or `select-update` matches nothing.
                         (case (system-type 'arch)
                           [(aarch64 arm64) 'arm64]
                           [else 'x64])
                         (current-update-public-key)
                         current-update-key-id
                         (random 100)
                         (* 512 1024 1024)))
       (define candidate (select-update config manifest))
       (if candidate
           (let ([manifest (update-candidate-manifest candidate)])
             (format "update available: ~a"
                     (update-manifest-version manifest)))
           "Fulcrum is up to date"))]))
