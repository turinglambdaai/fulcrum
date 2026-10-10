#lang racket/base

;; Updater tests, offline by construction: the download state machine runs
;; against a hand-rolled local HTTP feed (the backend's fetch-update-manifest
;; only speaks HTTPS, so the network half of the check is exercised in
;; production and against an unreachable port here; everything the updater
;; does with manifest/artifact bytes is tested directly). This covers the
;; 0.2 download milestone end to end — candidate injection, background
;; thread, progress percent, size + SHA-256 verification, error phases —
;; without trusting a byte from the internet.

(require crypto
         crypto/all
         rackunit
         rivet/distribution
         racket/file
         racket/path
         racket/string
         racket/tcp
         "../app/update.rkt"
         (only-in "../app/core/settings.rkt" make-settings-manager))

(use-all-factories!)

;; ---------- platform identity ---------------------------------------------

(test-case "platform symbols match rivet release manifests"
  (case (system-type 'os)
    [(macosx) (check-equal? (platform-symbol) 'macos)]
    [(windows) (check-equal? (platform-symbol) 'windows)]
    [else (check-equal? (platform-symbol) 'linux)])
  (check-not-false (memq (architecture-symbol) '(arm64 x64))))

(test-case "release identity matches the signing pipeline"
  (check-equal? update-key-id "fulcrum-2026-10")
  (check-true (fulcrum-update-configured?))
  (check-true (string? (current-update-version))))

;; ---------- artifact naming -------------------------------------------------

(define (candidate-for url sha size)
  (update-candidate
   (update-manifest "site.jrtx.fulcrum" "9.9.9" 9 'stable
                    "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                    (list (update-artifact (platform-symbol)
                                           (architecture-symbol)
                                           url sha size 'zip '())))
   (update-artifact (platform-symbol) (architecture-symbol)
                    url sha size 'zip '())))

(test-case "the downloaded file keeps the manifest's release name"
  (check-equal?
   (artifact-file-name
    (candidate-for "https://github.com/turinglambdaai/fulcrum/releases/download/v9.9.9/fulcrum-9.9.9-macos-arm64.zip"
                   (make-string 64 #\a) 10))
   "fulcrum-9.9.9-macos-arm64.zip")
  (check-equal?
   (artifact-file-name
    (candidate-for "https://dl.example/fulcrum-9.9.9-windows-x64.msi"
                   (make-string 64 #\a) 10))
   "fulcrum-9.9.9-windows-x64.msi")
  ;; both sides through build-path: string->path would normalize the
  ;; separators differently than build-path on Windows
  (check-equal?
   (destination-path (string->path "/tmp/data")
                     (candidate-for "https://dl.example/x/fulcrum-9.9.9-linux-x64.tar.gz"
                                    (make-string 64 #\a) 10))
   (build-path (string->path "/tmp/data")
               "updates" "fulcrum-9.9.9-linux-x64.tar.gz")))

(test-case "the updates folder URI is shell-openable and percent-encoded"
  (check-true (string-prefix? (updates-folder-uri) "file:///"))
  (check-false (string-contains? (updates-folder-uri) " ")))

;; ---------- progress accounting ---------------------------------------------

(test-case "download progress copies bytes and reports percent"
  (reset-update-state!)
  (define payload (make-bytes 250000 7))
  (define out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) out 250000)
  (check-equal? (bytes-length (get-output-bytes out)) 250000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 100)
  ;; percent tracks the declared total, not the end of input
  (reset-update-state!)
  (define short-out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) short-out 1000000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 25)
  (reset-update-state!))

;; ---------- rollout bucket ----------------------------------------------------

(test-case "rollout bucket is sticky and persists to the settings store"
  (define dir (make-temporary-file "fulcrum-updater-home-~a" 'directory))
  (define manager
    (make-settings-manager (build-path dir "settings.json")))
  (parameterize ([current-update-settings manager])
    (define first (rollout-bucket))
    (check-true (<= 0 first 99))
    ;; a second read returns the persisted bucket, not a fresh draw
    (check-equal? (rollout-bucket) first))
  (delete-directory/files dir))

;; ---------- offline check ------------------------------------------------------

(test-case "check against an unreachable feed reports error state"
  (parameterize ([current-update-version "0.0.0"]
                 [current-update-settings #f])
    (reset-update-state!)
    (define result
      (perform-check!
       "https://127.0.0.1:9/fulcrum/releases/latest/download"))
    (check-equal? (hash-ref result 'status) "error")
    (check-equal? (hash-ref (update-state-snapshot) 'phase) "error")
    (check-true (string? (hash-ref (update-state-snapshot) 'message)))))

;; ---------- the fake feed ------------------------------------------------------

;; A tiny HTTP/1.0 server: every connection gets one response with the
;; payload bytes. good for get-pure-port (redirects allowed, none sent).
(define (open-fake-feed! payload)
  ;; bind the first free port in a small range; tcp-listen gives no port
  ;; accessor, so the winning number is tracked here
  (define bound
    (let loop ([port 18080])
      (with-handlers ([exn:fail? (lambda (_) (loop (add1 port)))])
        (cons port (tcp-listen port 4 #f "127.0.0.1")))))
  (define port (car bound))
  (define listener (cdr bound))
  (define server-thread
    (thread
     (lambda ()
       (let accept ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (with-handlers ([exn:fail? void])
              ;; drain the request head
              (let drain ()
                (define line (read-line in 'return-linefeed))
                (unless (or (eof-object? line) (string=? line "")) (drain)))
              (fprintf out
                       "HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                       (bytes-length payload))
              (write-bytes payload out)
              (close-output-port out)
              (close-input-port in))))
         (accept)))))
  (values port
          (lambda ()
            (kill-thread server-thread)
            (tcp-close listener))))

;; Poll the state box until one of the phases shows up (the download runs
;; on a backend-style worker thread).
(define (wait-for-phase! wanted timeout-ms)
  (let loop ([deadline (+ (current-inexact-milliseconds) timeout-ms)])
    (define phase (hash-ref (update-state-snapshot) 'phase))
    (cond
      [(member phase wanted) phase]
      [(> (current-inexact-milliseconds) deadline)
       (error 'wait-for-phase! "timed out waiting for ~a, state: ~a"
              wanted (update-state-snapshot))]
      [else (sleep 0.05) (loop deadline)])))

(test-case "download state machine: happy path over a local feed"
  (define payload (make-bytes 300000 42))
  (define payload-file (make-temporary-file "fulcrum-feed-~a.bin"))
  (call-with-output-file payload-file
    #:exists 'truncate
    (lambda (out) (write-bytes payload out)))
  (define sha (sha256-file/hex payload-file))
  (define-values (port stop) (open-fake-feed! payload))
  (define data-dir (make-temporary-file "fulcrum-updates-~a" 'directory))
  (parameterize ([current-update-version "0.0.0"]
                 [current-update-settings #f])
    (reset-update-state!)
    (install-candidate!
     (candidate-for
      (format "http://127.0.0.1:~a/fulcrum-9.9.9-macos-arm64.zip" port)
      sha (bytes-length payload)))
    (check-equal? (hash-ref (update-state-snapshot) 'phase) "idle")
    (start-download! data-dir)
    (check-equal? (hash-ref (update-state-snapshot) 'phase) "downloading")
    (check-equal? (wait-for-phase! '("downloaded") 15000) "downloaded")
    (define snapshot (update-state-snapshot))
    (check-equal? (hash-ref snapshot 'percent) 100)
    (check-equal? (hash-ref snapshot 'availableVersion) "9.9.9")
    (define path (hash-ref snapshot 'downloadedPath))
    (check-true (string? path))
    (check-equal? (file-size (string->path path)) (bytes-length payload))
    ;; the artifact keeps its release name under <data-dir>/updates
    (check-true (string-suffix? path "fulcrum-9.9.9-macos-arm64.zip"))
    (check-false (file-exists? (path-add-extension (string->path path) #".partial"))))
  (stop)
  (delete-directory/files data-dir)
  (delete-file payload-file))

(test-case "a hash mismatch lands in the error phase with no trusted file"
  (define payload (make-bytes 1000 1))
  (define-values (port stop) (open-fake-feed! payload))
  (define data-dir (make-temporary-file "fulcrum-updates-~a" 'directory))
  (parameterize ([current-update-version "0.0.0"]
                 [current-update-settings #f])
    (reset-update-state!)
    (install-candidate!
     (candidate-for
      (format "http://127.0.0.1:~a/fulcrum-9.9.9-macos-arm64.zip" port)
      ;; signed sha256 deliberately wrong
      (make-string 64 #\0)
      (bytes-length payload)))
    (start-download! data-dir)
    (check-equal? (wait-for-phase! '("error") 15000) "error")
    (check-true (string-contains?
                 (or (hash-ref (update-state-snapshot) 'message "") "")
                 "SHA-256"))
    (check-false
     (file-exists?
      (build-path data-dir "updates" "fulcrum-9.9.9-macos-arm64.zip")))
    (check-false
     (file-exists?
      (build-path data-dir "updates" "fulcrum-9.9.9-macos-arm64.zip.partial"))))
  (stop)
  (delete-directory/files data-dir))

(test-case "a dead feed lands in the error phase and cleans the partial"
  (define data-dir (make-temporary-file "fulcrum-updates-~a" 'directory))
  (parameterize ([current-update-version "0.0.0"]
                 [current-update-settings #f])
    (reset-update-state!)
    (install-candidate!
     (candidate-for
      "http://127.0.0.1:9/fulcrum-9.9.9-macos-arm64.zip"
      (make-string 64 #\0) 1000))
    (start-download! data-dir)
    (check-equal? (wait-for-phase! '("error") 15000) "error")
    (check-false
     (file-exists?
      (build-path data-dir "updates" "fulcrum-9.9.9-macos-arm64.zip.partial"))))
  (delete-directory/files data-dir))

(test-case "starting a download without a candidate is refused"
  (reset-update-state!)
  (check-exn exn:fail?
             (lambda () (start-download!
                         (make-temporary-file "fulcrum-updates-~a" 'directory)))))
