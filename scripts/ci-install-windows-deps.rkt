#lang racket/base
;; Windows GitHub-hosted runners sometimes fail while Racket enumerates
;; certificates in the Windows ROOT store (X509*->C receives #f).
;; Configure a trusted Mozilla PEM bundle in the SAME process that downloads
;; packages. TLS certificate and hostname verification remain enabled.
(require openssl
         pkg
         racket/file)

(define bundle (getenv "FULCRUM_CI_CA_BUNDLE"))
(unless (and bundle
             (file-exists? bundle)
             (regexp-match? #rx#"-----BEGIN CERTIFICATE-----"
                            (file->bytes bundle)))
  (error 'ci-install-windows-deps
         "trusted Mozilla PEM CA bundle is missing or invalid"))
(ssl-default-verify-sources (list bundle))

(define rivet-pin (getenv "RIVET_PIN"))
(unless (and rivet-pin (not (equal? rivet-pin "")))
  (error 'ci-install-windows-deps "RIVET_PIN must be set"))

;; Preserve the previous db-lib availability check before installing Rivet.
(with-handlers ([exn:fail?
                 (lambda (_)
                   (pkg-install-command #:auto #t #:no-docs #t "db-lib"))])
  (dynamic-require 'db #f))

(pkg-install-command
 #:auto #t
 #:no-docs #t
 (format "https://github.com/turlamai/rivet.git#~a" rivet-pin))
