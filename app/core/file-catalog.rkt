#lang racket/base

;; Progressive local filename catalog.
;;
;; The scanner is intentionally conservative: production defaults cover the
;; three common user-facing folders, never an unbounded home/AppData/Library
;; traversal. Platform indexes continue to provide broader candidates while
;; this local catalog makes common files independently searchable.

(require racket/bool
         racket/file
         racket/list
         racket/path
         racket/string
         "file-index.rkt")

(provide (struct-out file-catalog-status)
         default-file-catalog-roots
         start-file-catalog!
         stop-file-catalog!
         file-catalog-current-status
         file-catalog-wait)

(struct file-catalog-status
  (state indexed roots-completed roots-total error)
  #:transparent)
(struct file-catalog-worker (thread cancel status) #:transparent)

(define ignored-directory-names
  '(".git" ".hg" ".svn" ".cache" ".gradle" ".idea"
    "node_modules" "__pycache__" ".venv" "venv"))

(define (ignored-directory? path)
  (define name (file-name-from-path path))
  (and name
       (member (string-foldcase (path->string name))
               ignored-directory-names)))

(define (existing-directory path)
  (and (directory-exists? path) (simple-form-path path)))

(define (xdg-user-roots home env)
  (define config-home
    (let ([raw (env "XDG_CONFIG_HOME")])
      (if (and (string? raw) (not (string=? raw "")))
          (string->path raw)
          (build-path home ".config"))))
  (define config (build-path config-home "user-dirs.dirs"))
  (with-handlers ([exn:fail:filesystem? (lambda (_) '())])
    (call-with-input-file
     config
     (lambda (in)
       (for/list ([line (in-lines in)]
                  #:do [(define match
                          (regexp-match
                           #px"^XDG_(?:DESKTOP|DOCUMENTS|DOWNLOAD)_DIR=\"([^\"]*)\"$"
                           line))]
                  #:when match
                  #:do [(define raw (cadr match))
                        (define expanded
                          (if (string-prefix? raw "$HOME/")
                              (build-path home (substring raw 6))
                              (string->path raw)))]
                  #:when (existing-directory expanded))
         (simple-form-path expanded))))))

(define (default-file-catalog-roots
         #:home [home (find-system-path 'home-dir)]
         #:os [os (system-type 'os)]
         #:env [env getenv])
  (define home-path (simple-form-path home))
  (define base
    (for/list ([name (in-list '("Desktop" "Documents" "Downloads"))]
               #:do [(define path (build-path home-path name))]
               #:when (existing-directory path))
      (simple-form-path path)))
  (define onedrive
    (and (eq? os 'windows)
         (let ([raw (or (env "OneDriveConsumer") (env "OneDrive"))])
           (and (string? raw) (not (string=? raw ""))
                (existing-directory raw)))))
  (define cloud
    (case os
      [(windows)
       (if onedrive
           (for/list ([name (in-list '("Desktop" "Documents"))]
                      #:do [(define path (build-path onedrive name))]
                      #:when (existing-directory path))
             (simple-form-path path))
           '())]
      [(macosx)
       (define icloud
         (build-path home-path "Library" "Mobile Documents"
                     "com~apple~CloudDocs"))
       (for/list ([name (in-list '("Desktop" "Documents"))]
                  #:do [(define path (build-path icloud name))]
                  #:when (existing-directory path))
         (simple-form-path path))]
      [(unix) (xdg-user-roots home-path env)]
      [else '()]))
  ;; Explicit additional Windows workspaces are indexed on demand; never
  ;; walk entire disks or UNC shares by default.  The environment variable
  ;; is read by both this catalog and the bounded PowerShell query.
  (define configured
    (if (eq? os 'windows)
        (let ([raw (env "FULCRUM_FILE_SEARCH_ROOTS")])
          (if (and (string? raw) (not (string=? raw "")))
              (for/list ([item (in-list (take (string-split raw ";")
                                               (min 8 (length (string-split raw ";")))))]
                         #:do [(define text (string-trim item))]
                         #:when (and (> (string-length text) 3)
                                     (regexp-match? #px"^[A-Za-z]:[\\\\/]" text))
                         #:do [(define directory (existing-directory text))]
                         ;; Canonicalize before rejecting drive roots, including
                         ;; D:\\Workspace\\.. and repeated trailing separators.
                         #:when (and directory
                                     (> (string-length
                                         (regexp-replace*
                                          #px"[/\\\\]+$"
                                          (path->string directory) ""))
                                        2)))
                directory)
              '()))
        '()))
  (remove-duplicates
   (append base cloud configured)
   (if (eq? os 'windows) string-ci=? string=?)
   #:key path->string))

(define (safe-directory-list directory)
  ;; #f means the directory could not be read; an empty list means it was
  ;; read successfully and is empty. Reconciliation must preserve that
  ;; distinction or a permission denial can look like mass deletion.
  (with-handlers ([exn:fail:filesystem? (lambda (_) #f)]
                  [exn:fail:contract? (lambda (_) #f)])
    (directory-list directory #:build? #t)))

(define (cancelled? cancel)
  (not (false? (sync/timeout 0 (semaphore-peek-evt cancel)))))

(define (path->hit path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define name-path (file-name-from-path path))
    (and name-path
         (cons (path->string name-path)
               (path->string (simple-form-path path))))))

(define (scan-root! index-path root generation cancel status-box
                    indexed completed total batch-size list-directory)
  (define batch '())
  (define batch-count 0)
  (define count indexed)
  (define complete? #t)
  (define (publish! state [error #f])
    (set-box! status-box
              (file-catalog-status state count completed total error)))
  (define (flush!)
    (when (pair? batch)
      (define hits (reverse batch))
      (unless (file-index-upsert-scan-hits!
               index-path (path->string root) generation hits)
        (error 'file-catalog "index batch write failed"))
      (set! count (+ count batch-count))
      (set! batch '())
      (set! batch-count 0)
      (publish! 'scanning)
      ;; Cooperatively yield between database batches so a large catalog does
      ;; not monopolize the embedded backend while the user keeps typing.
      (sleep 0)))
  (let loop ([pending (list root)])
    (cond
      [(cancelled? cancel) (values #f count)]
      [(null? pending)
       (flush!)
       (values (if complete? 'complete 'partial) count)]
      [else
       (define directory (car pending))
       (define rest (cdr pending))
       (define children (list-directory directory))
       (define next
         (if children
             (for/fold ([stack rest]) ([child (in-list children)])
               (cond
                 [(cancelled? cancel) stack]
                 [(and (directory-exists? child)
                       (not (link-exists? child))
                       (not (ignored-directory? child)))
                  (cons child stack)]
                 [(file-exists? child)
                  (define hit (path->hit child))
                  (when hit
                    (set! batch (cons hit batch))
                    (set! batch-count (add1 batch-count))
                    (when (>= batch-count batch-size) (flush!)))
                  stack]
                 [else stack]))
             (begin (set! complete? #f) rest)))
       (loop next)])))

(define (start-file-catalog! index-path roots
                             #:batch-size [batch-size 1000]
                             #:list-directory [list-directory safe-directory-list])
  (unless (and (exact-positive-integer? batch-size) (<= batch-size 10000))
    (raise-argument-error 'start-file-catalog! "integer from 1 to 10000" batch-size))
  (define normalized-roots
    (remove-duplicates
     (for/list ([root (in-list roots)]
                #:when (existing-directory root))
       (simple-form-path root))
     string=? #:key path->string))
  (define cancel (make-semaphore 0))
  (define status
    (box (file-catalog-status 'starting 0 0 (length normalized-roots) #f)))
  (define worker-thread
    (thread
     (lambda ()
       (with-handlers
           ([exn:fail?
             (lambda (exn)
               (define previous (unbox status))
               (set-box! status
                         (struct-copy file-catalog-status previous
                                      [state 'failed]
                                      [error (exn-message exn)])))])
         (define indexed 0)
         (define completed 0)
         (define partial? #f)
         (for ([root (in-list normalized-roots)] #:break (cancelled? cancel))
           (define generation
             (+ (* 1000 (inexact->exact
                         (floor (current-inexact-milliseconds))))
                (random 1000)))
           (set-box! status
                     (file-catalog-status 'scanning indexed completed
                                          (length normalized-roots) #f))
           (define-values (outcome next-indexed)
             (scan-root! index-path root generation cancel status
                         indexed completed (length normalized-roots) batch-size
                         list-directory))
           (set! indexed next-indexed)
           (case outcome
             [(complete)
              (unless (file-index-finish-scan!
                       index-path (path->string root) generation)
                (error 'file-catalog "index reconciliation failed"))
              (set! completed (add1 completed))]
             [(partial) (set! partial? #t)]
             [else (void)]))
         (set-box! status
                   (file-catalog-status
                    (cond [(cancelled? cancel) 'cancelled]
                          [partial? 'partial]
                          [else 'ready])
                    indexed completed (length normalized-roots) #f))))))
  (file-catalog-worker worker-thread cancel status))

(define (stop-file-catalog! worker)
  (unless (cancelled? (file-catalog-worker-cancel worker))
    (semaphore-post (file-catalog-worker-cancel worker)))
  (void))

(define (file-catalog-current-status worker)
  (unbox (file-catalog-worker-status worker)))

(define (file-catalog-wait worker [timeout-seconds 30])
  (and (sync/timeout timeout-seconds
                     (thread-dead-evt (file-catalog-worker-thread worker)))
       (file-catalog-current-status worker)))
