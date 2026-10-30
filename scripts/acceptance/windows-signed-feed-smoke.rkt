#lang racket/base

;; Real public-release Ed25519 manifest → Windows MSI download regression.
;; This intentionally does NOT call crypto/all use-all-factories!: installed
;; Fulcrum's backend must verify using its ordinary crypto factory setup.
;; Pin the known v0.13.3 → v0.14.0 feed to avoid dependence on "latest".
(require racket/file
         racket/path
         racket/string
         "../../app/update.rkt")

(define base-url
  "https://github.com/turinglambdaai/fulcrum/releases/download/v0.14.0")
(define tmp (make-temporary-file "fulcrum-signed-win-update-~a" 'directory))
(define previous-data-dir (getenv "FULCRUM_DATA_DIR"))
(define (require! condition fmt . args)
  (unless condition (apply error 'windows-signed-feed-smoke fmt args)))
(define (wait-for-download!)
  (let loop ([deadline (+ (current-inexact-milliseconds) (* 10 60 1000))])
    (define snapshot (update-state-snapshot))
    (define phase (hash-ref snapshot 'phase "idle"))
    (cond
      [(string=? phase "downloaded") snapshot]
      [(string=? phase "error")
       (error 'windows-signed-feed-smoke
              "authenticated MSI download failed: ~a"
              (hash-ref snapshot 'message #f))]
      [(> (current-inexact-milliseconds) deadline)
       (error 'windows-signed-feed-smoke
              "authenticated MSI download timed out in phase ~a" phase)]
      [else (sleep 0.25) (loop deadline)])))

(dynamic-wind
  (lambda () (putenv "FULCRUM_DATA_DIR" (path->string tmp)))
  (lambda ()
    (parameterize ([current-update-version "0.13.3"]
                   [current-update-settings #f])
      (define result (perform-check! base-url))
      (require! (equal? (hash-ref result 'status #f) "available")
                "expected signed update: ~a" result)
      (require! (equal? (hash-ref result 'availableVersion #f) "0.14.0")
                "unexpected signed update version: ~a" result)
      (require! (equal? (hash-ref result 'installer #f) "msi")
                "installed Windows update must select MSI, got: ~a" result)
      (displayln "PASS: real signed v0.14.0 Windows manifest verified and MSI selected")
      (start-download! tmp)
      (let* ([snapshot (wait-for-download!)]
             [downloaded (hash-ref snapshot 'downloadedPath #f)]
             [ticket (verified-install-metadata)])
        (require! (and (string? downloaded)
                       (file-exists? downloaded)
                       (string-suffix? (string-downcase downloaded) ".msi"))
                  "verified signed MSI path missing: ~a" snapshot)
        (require! (and (hash? ticket)
                       (equal? (hash-ref ticket 'installer #f) "msi")
                       (string? (hash-ref ticket 'sha256 #f)))
                  "downloaded MSI has no trusted native-install ticket: ~a" ticket)
        (displayln "PASS: official MSI bytes verified against signed feed, native handoff ticket available"))))
  (lambda ()
    (putenv "FULCRUM_DATA_DIR" (or previous-data-dir ""))
    (delete-directory/files tmp)))
