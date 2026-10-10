#lang racket/base

;; Fulcrum update wiring over `rivet/distribution`.
;;
;; Trust model (inherited from Rivet): HTTPS protects transport but is not
;; the root of update trust. The channel manifest is Ed25519-signed and
;; verified against the public key embedded below before any version
;; decision. Key management lives in docs/release-runbook.md: key generation,
;; the exact replacement of `current-update-public-key-hex`, and rotation via
;; `current-update-key-id` (ship a client trusting the next key before
;; signing with it).
;;
;; The family pattern (taskly/rivet): the backend verifies and downloads the
;; signed update artifact; the native host owns installation. A check fetches
;; and verifies the signed channel manifest; the artifact download runs on a
;; background thread with progress published to a state box that the UI polls
;; through the `update-state` RPC (RVT1 events are thread-local, so a
;; background thread cannot emit them directly). The feed serves installers —
;; macos zip (portable bundle), windows msi, linux tar.gz — per
;; .github/sign-manifest.rkt; the dmg is the human installer, not a feed
;; artifact.
;;
;; Fulcrum-specific rules: the 4-hour silent-check throttle and the sticky
;; rollout bucket live in the typed settings store (keys `update-last-check`
;; and `update-rollout-bucket`, managed by the backend); downloads land under
;; <data-dir>/updates and no store file is ever touched.

(require net/base64
         net/uri-codec
         net/url
         rivet/distribution
         racket/file
         racket/path
         racket/port
         racket/string
         "core/paths.rkt"
         "core/settings.rkt")

(provide current-update-version
         current-update-settings
         default-update-base-url
         maximum-download-bytes
         update-key-id
         fulcrum-update-configured?
         platform-symbol
         architecture-symbol
         artifact-file-name
         destination-path
         copy-with-progress!
         update-state-snapshot
         reset-update-state!
         set-update-error!
         install-candidate!
         peek-candidate
         pending-artifact-size
         updates-folder-uri
         perform-check!
         start-download!
         rollout-bucket)

;; Ed25519 public key (DER SPKI), hex-encoded — committed on purpose: the
;; public half only enables verification. Rotation replaces this hex and the
;; key id below (ship clients trusting the next key before signing with it).
;; Key fingerprint: sha256(DER)[:16] = 60b7ce3b8a255465; private half lives in
;; the keys vault and the RIVET_UPDATE_PRIVATE_KEY repository secret.
(define current-update-public-key-hex
  "302a300506032b65700321004797203e4e1fce109e45d41ba755e87eb7d261c082b5bf6728ae0eaaa58e55d7")
(define update-key-id "fulcrum-2026-10")

;; The running version: the packaged app reads rivet-app-info.rktd, so the
;; backend owns the value and hands it over through this parameter. Headless
;; tests parameterize it directly.
(define current-update-version (make-parameter "0.0.0"))

;; The typed settings store, for the check throttle and the sticky rollout
;; bucket. #f (headless tests) degrades to a fresh random bucket and no
;; persisted throttle — the backend always installs a real manager.
(define current-update-settings (make-parameter #f))

;; Where the updater looks for the signed manifest. The release pipeline
;; pins artifact URLs to the concrete tag; the manifest itself is always
;; fetched from the moving "latest" location. Tests parameterize the
;; update-base-url setting at an unreachable local URL instead of touching
;; the network.
(define default-update-base-url
  "https://github.com/turinglambdaai/fulcrum/releases/latest/download")

(define maximum-download-bytes (* 512 1024 1024))

;; ---------- public key ----------

(define (hex->bytes s)
  (let ([n (string-length s)])
    (if (and (even? n) (>= n 2))
        (apply bytes (for/list ([i (in-range 0 n 2)])
                       (string->number (substring s i (+ i 2)) 16)))
        #f)))

(define (fulcrum-update-configured?)
  (and current-update-public-key-hex
       (hex->bytes current-update-public-key-hex)
       #t))

;; The manifest verifier takes a parsed key object, not raw DER — this
;; conversion is what stands between an update check and a contract
;; violation at ed25519-verify (every 0.4.x check failed exactly there).
;; Lazy on purpose: FFI at module-import time kills embedded apps at
;; startup (the landmine rivet/distribution/crypto.rkt documents), so the
;; parse happens at check time like taskly's embedded-public-key; a
;; failure there surfaces as an honest "update check failed" instead of a
;; dead app. bytes->ed25519-public-key pins the libcrypto factory
;; explicitly and exists since rivet 2e1924c — the RIVET_PIN snapshot.
(define (current-update-public-key)
  (bytes->ed25519-public-key (hex->bytes current-update-public-key-hex)))

;; ---------- platform identity ----------

;; rivet release tooling emits these exact symbols into update manifests
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; The feed serves installers, and the release pipeline pins versioned,
;; architecture-suffixed names (fulcrum-<version>-macos-arm64.zip,
;; -windows-x64.msi, -linux-x64.tar.gz) — the signed manifest carries the
;; full URL, so the on-disk name is simply the URL's last segment. Keeping
;; the release name means the "open folder / run the msi" guidance on
;; Windows and Linux points at exactly the file the manifest vouches for.
(define (artifact-file-name candidate)
  (define raw (update-artifact-url (update-candidate-artifact candidate)))
  (or (and (string? raw)
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (url-file-name (string->url raw))))
      "fulcrum-update"))

(define (url-file-name url)
  (let loop ([segments (url-path url)] [seen #f])
    (cond
      [(null? segments) seen]
      [else
       (define raw (path/param-path (car segments)))
       (loop (cdr segments)
             (if (and (string? raw) (not (string=? raw "")))
                 raw
                 seen))])))


;; ---------- shared update state (UI-visible) ----------

;; phase: idle | checking | downloading | downloaded | error
(define update-state
  (box (hasheq 'phase "idle"
               'percent 0
               'message #f
               'downloadedPath #f
               'availableVersion #f)))

(define candidate-box (box #f))
(define worker-thread-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

(define (update-state-snapshot)
  (unbox update-state))

(define (reset-update-state!)
  (set-box! candidate-box #f)
  (set-box! update-state
            (hasheq 'phase "idle"
                    'percent 0
                    'message #f
                    'downloadedPath #f
                    'availableVersion #f)))

;; Pre-spawn download failures (already running, no candidate) surface
;; through the state instead of an RPC error, so host UIs have a single
;; failure channel.
(define (set-update-error! message)
  (state-set! 'phase "error")
  (state-set! 'message message))

;; Test seam: the offline download test injects a candidate built over a
;; local HTTP artifact instead of one selected from a signed manifest.
(define (install-candidate! candidate)
  (set-box! candidate-box candidate))

(define (peek-candidate)
  (unbox candidate-box))

;; Byte size of the pending candidate's artifact, for row subtitles.
(define (pending-artifact-size)
  (define candidate (unbox candidate-box))
  (and candidate
       (update-artifact-size (update-candidate-artifact candidate))))

;; The updates directory as a file:// URI the hosts can shell-open (Finder,
;; Explorer, and xdg-open all speak it).
(define (updates-folder-uri)
  (define path (path->string (simple-form-path
                              (build-path (data-dir) "updates"))))
  (define parts (regexp-split #rx"[\\/]" path))
  (string-append
   "file:///"
   (string-join
    (for/list ([part (in-list parts)] #:unless (string=? part ""))
      (uri-path-segment-encode part))
    "/")))

;; ---------- rollout bucket ----------

;; Stable random 0..99 assigned on first check so staged rollouts are
;; sticky per installation. Persisted in the typed settings store; without
;; a store (headless tests) a fresh draw is honest enough — the release
;; channel manifest currently rolls out to 100.
(define (rollout-bucket)
  (define manager (current-update-settings))
  (if manager
      (let ([existing (settings-get manager 'update-rollout-bucket)])
        (if (exact-integer? existing)
            existing
            (let ([bucket (random 100)])
              (settings-set! manager 'update-rollout-bucket bucket)
              bucket)))
      (random 100)))

;; ---------- check ----------

;; Returns a plain hasheq describing the outcome; the backend maps it onto
;; the typed UpdateCheck record. Throttling is the backend's job (the
;; update-check RPC persists `update-last-check`).
(define (perform-check! base-url)
  (reset-update-state!)
  (state-set! 'phase "checking")
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (state-set! 'phase "error")
          (state-set! 'message (exn-message e))
          (hasheq 'status "error" 'message (exn-message e)))])
    (cond
      [(not (fulcrum-update-configured?))
       (state-set! 'phase "idle")
       (hasheq 'status "error"
               'message "updates unavailable: developer build (no update key configured)")]
      [(or (not base-url) (string=? (string-trim base-url) ""))
       (state-set! 'phase "idle")
       (hasheq 'status "error"
               'message "updates unavailable: no update base URL configured")]
      [else
       (define manifest
         (fetch-update-manifest
          (string-append (regexp-replace* #rx"/+$" base-url "") "/manifest.json")
          (current-update-public-key)
          #:key-id update-key-id
          #:maximum-bytes (* 4 1024 1024)))
       (define config
         (updater-config "site.jrtx.fulcrum"
                         (current-update-version)
                         'stable
                         (platform-symbol)
                         ;; Family architecture vocabulary (rivet's own
                         ;; release flow and taskly's updater both speak
                         ;; arm64/x64); the signed manifest must use the
                         ;; same symbols or `select-update` matches nothing.
                         (architecture-symbol)
                         (current-update-public-key)
                         update-key-id
                         (rollout-bucket)
                         maximum-download-bytes))
       (define candidate (select-update config manifest))
       (cond
         [candidate
          (set-box! candidate-box candidate)
          (define inner (update-candidate-manifest candidate))
          (state-set! 'phase "idle")
          (state-set! 'availableVersion (update-manifest-version inner))
          (hasheq 'status "available"
                  'currentVersion (current-update-version)
                  'availableVersion (update-manifest-version inner)
                  'build (update-manifest-build inner)
                  'publishedAt (update-manifest-published-at inner)
                  'installer (symbol->string
                              (update-artifact-installer
                               (update-candidate-artifact candidate)))
                  'sizeBytes (update-artifact-size
                              (update-candidate-artifact candidate)))]
         [else
          (state-set! 'phase "idle")
          (state-set! 'availableVersion #f)
          (hasheq 'status "up-to-date"
                  'currentVersion (current-update-version))])])))

;; ---------- download ----------

(define (destination-path data-dir candidate)
  (build-path data-dir "updates" (artifact-file-name candidate)))

;; Copy with progress; same redirect-following and limit enforcement as
;; rivet's download-update but publishes integer percent changes to the
;; state box while streaming. Release asset URLs redirect to the CDN, so
;; follow redirections like rivet's own downloader does (the
;; 302-into-an-empty-body trap, rivet#153). The limit is enforced during
;; the copy too: a server sending more than the signed size must not be
;; able to fill the disk before the post-download verify runs.
(define (copy-with-progress! in out total)
  (define buffer (make-bytes 65536))
  (let loop ([done 0] [last-percent -1])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) done]
      [else
       (write-bytes buffer out 0 count)
       (define next (+ done count))
       (when (> next maximum-download-bytes)
         (error 'download-update "update exceeds configured download limit"))
       (define percent
         (if (> total 0)
             (min 100 (quotient (* next 100) total))
             0))
       (when (> percent last-percent)
         (state-set! 'percent percent))
       (loop next percent)])))

(define (download-with-progress! config candidate destination)
  (define artifact (update-candidate-artifact candidate))
  (define total (update-artifact-size artifact))
  (when (> total (updater-config-maximum-download-bytes config))
    (error 'download-update "signed artifact size exceeds the download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (define in
      (get-pure-port (string->url (update-artifact-url artifact))
                     '("User-Agent: Fulcrum-Updater/1")
                     #:redirections 10))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-with-progress! in out total))))
      (lambda () (close-input-port in)))
    ;; size + SHA-256 against the signed manifest before the file is trusted
    (verify-update-artifact! candidate temporary)
    (rename-file-or-directory temporary destination #t)
    destination))

;; Runs on a backend worker thread; the host follows progress via the
;; update-state RPC. Never raises: failures surface through the phase.
(define (start-download! data-dir)
  (define worker (unbox worker-thread-box))
  (when (and worker (thread-running? worker))
    (error 'start-download! "an update download is already running"))
  (define candidate (unbox candidate-box))
  (unless candidate
    (error 'start-download! "no update is available; run a check first"))
  (state-set! 'phase "downloading")
  (state-set! 'percent 0)
  (state-set! 'message #f)
  (state-set! 'availableVersion
              (update-manifest-version (update-candidate-manifest candidate)))
  (define config
    (updater-config "site.jrtx.fulcrum"
                    (current-update-version)
                    'stable
                    (platform-symbol)
                    (architecture-symbol)
                    (current-update-public-key)
                    update-key-id
                    (rollout-bucket)
                    maximum-download-bytes))
  (define destination (destination-path data-dir candidate))
  (set-box! worker-thread-box
            (thread
             (lambda ()
               (with-handlers
                   ([exn:fail?
                     (lambda (e)
                       (state-set! 'phase "error")
                       (state-set! 'message (exn-message e)))])
                 (define path
                   (download-with-progress! config candidate destination))
                 (state-set! 'phase "downloaded")
                 (state-set! 'percent 100)
                 (state-set! 'downloadedPath (path->string path)))))))
