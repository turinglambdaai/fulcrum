#lang racket/base

;; Application discovery.
;;
;; The backend indexes applications per platform from the same places the OS
;; launcher menus use, with one injectable core so tests run on every OS from
;; fixture directories:
;;
;;   - macOS: .app bundles under the standard Applications roots; names from
;;     bundle directory name (the `.app` suffix stripped).
;;   - Linux: .desktop entries under XDG application roots; NoDisplay/Hidden
;;     and non-Application types are skipped.
;;   - Windows: Start Menu .lnk/.url/.exe shortcuts; the file name (without
;;     extension) is the display name. Resolving .lnk targets needs the COM
;;     IShellLink API and is deferred to the Windows host, which can resolve
;;     and launch natively.
;;
;; Discovery is a snapshot rebuilt at startup or via index-rebuild; it does
;; not watch the filesystem.

(require json
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/string
         "proc.rkt")

(provide (struct-out application)
         applications-from-dirs
         discover-applications
         parse-desktop-entry
         application-launch)

(struct application (id name exec icon keywords path) #:transparent)

;; ---- shared helpers -----------------------------------------------------

(define (application-id-from-path path)
  ;; Deterministic id: hash of the complete path, stable across rebuilds.
  ;; number->string accepts only bases 2/8/10/16.
  (define s (path->string (path->complete-path path)))
  (string-append "a" (number->string (equal-hash-code s) 16)))

(define (dedupe apps)
  (define seen (make-hash))
  (for/list ([app (in-list apps)]
             #:unless (hash-ref seen (application-name app) #f)
             #:when (hash-set! seen (application-name app) #t))
    app))

;; ---- macOS --------------------------------------------------------------

(define (macos-app-roots)
  (define home (find-system-path 'home-dir))
  (filter directory-exists?
          (list (build-path "/" "Applications")
                (build-path home "Applications")
                (build-path "/" "System" "Applications")
                (build-path "/" "System" "Applications" "Utilities")
                (build-path "/" "Applications" "Utilities"))))

(define (macos-bundle->application app-dir)
  ;; The bundle directory name (`.app` stripped) is what the Finder shows
  ;; and matches CFBundleName for the overwhelming majority of bundles.
  ;; Reading CFBundleName out of Info.plist would cost one plutil subprocess
  ;; per bundle per rebuild — seconds of first-launch latency on a real
  ;; machine — for a difference that only shows up in a handful of apps.
  (application (application-id-from-path app-dir)
               (path->string (path-replace-extension
                              (file-name-from-path app-dir) ""))
               (path->string app-dir)
               "app"
               '()
               (path->string app-dir)))

(define (macos-apps-from-dirs dirs)
  (define bundles
    (append*
     (for/list ([dir (in-list dirs)])
       ;; Yield every directory but do not descend into .app bundles: a
       ;; nested .app is not a user-facing application. in-directory takes
       ;; the descend? predicate positionally — there is no #:stop keyword.
       (for/list ([p (in-directory
                      dir
                      (lambda (d)
                        (not (regexp-match? #rx"[.]app$" (path->string d)))))]
                  #:when (directory-exists? p)
                  #:when (regexp-match? #rx"[.]app$" (path->string p)))
         p))))
  (dedupe (map macos-bundle->application bundles)))

;; ---- Linux --------------------------------------------------------------

(define (linux-app-roots)
  (define home (find-system-path 'home-dir))
  (define xdg-data-home
    (or (getenv "XDG_DATA_HOME")
        (path->string (build-path home ".local" "share"))))
  (define xdg-data-dirs
    (or (getenv "XDG_DATA_DIRS") "/usr/local/share:/usr/share"))
  (append
   (list (build-path xdg-data-home "applications"))
   (for/list ([d (in-list (string-split xdg-data-dirs ":"))]
              #:unless (string=? d ""))
     (build-path d "applications"))))

(define/contract (parse-desktop-entry text)
  (-> string? (or/c (hash/c symbol? string?) #f))
  ;; Parse the [Desktop Entry] section of an INI-style .desktop file into a
  ;; hash of key → value. Returns #f when the section is absent.
  (let loop ([lines (string-split text "\n")] [section #f] [fields '()])
    (cond
      [(null? lines)
       (and (eq? section 'entry) (make-immutable-hash (reverse fields)))]
      [else
       (define line (string-trim (car lines)))
       (cond
         [(string=? line "") (loop (cdr lines) section fields)]
         [(string-prefix? line "#") (loop (cdr lines) section fields)]
         [(string-prefix? line "[")
          (loop (cdr lines)
                (if (string=? line "[Desktop Entry]") 'entry 'other)
                fields)]
         [(eq? section 'entry)
          (define eq (index-of-char line #\=))
          (if (and eq (> eq 0))
              (loop (cdr lines) section
                    (cons (cons (string->symbol (string-trim (substring line 0 eq)))
                                (substring line (add1 eq)))
                          fields))
              (loop (cdr lines) section fields))]
         [else (loop (cdr lines) section fields)])])))

(define (desktop-true? value)
  (and (string? value)
       (member (string-downcase (string-trim value)) '("true" "1"))))

(define (index-of-char s ch)
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

(define (desktop-entry->application path entry)
  (define name (hash-ref entry 'Name #f))
  (define exec (hash-ref entry 'Exec #f))
  (define type (hash-ref entry 'Type #f))
  (and (string? name) (non-empty-string? name)
       (string? exec) (non-empty-string? exec)
       ;; Absent Type is accepted (common in minimal entries); anything
       ;; present must be Application.
       (or (not type) (string=? type "Application"))
       (not (desktop-true? (hash-ref entry 'NoDisplay #f)))
       (not (desktop-true? (hash-ref entry 'Hidden #f)))
       (application
        (string-append
         "d"
         (path->string (path-replace-extension (file-name-from-path path) "")))
        name
        exec
        (hash-ref entry 'Icon "app")
        (let ([kw (hash-ref entry 'Keywords #f)])
          (if (string? kw) (filter non-empty-string? (string-split kw ";")) '()))
        (path->string path))))

(define (linux-apps-from-dirs dirs)
  (define entries
    (append*
     (for/list ([dir (in-list dirs)])
       (with-handlers ([exn:fail? (lambda (_) '())])
         (for/list ([f (in-directory dir)]
                    #:when (and (file-exists? f)
                                (equal? (path-get-extension f) #".desktop")))
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (define text (file->string f))
             (and text
                  (let ([entry (parse-desktop-entry text)])
                    (and entry (desktop-entry->application f entry))))))))))
  (dedupe (filter values entries)))

;; ---- Windows ------------------------------------------------------------

(define (windows-app-roots)
  (filter directory-exists?
          (append
           (for/list ([var (in-list '("ProgramData" "APPDATA"))]
                      #:when (getenv var))
             (build-path (getenv var)
                         "Microsoft" "Windows" "Start Menu" "Programs"))
           (list (build-path (find-system-path 'home-dir)
                             "AppData" "Roaming"
                             "Microsoft" "Windows" "Start Menu" "Programs")))))

(define (windows-apps-from-dirs dirs)
  (define files
    (append*
     (for/list ([dir (in-list dirs)])
       (for/list ([f (in-directory dir)]
                  #:when (and (file-exists? f)
                              (member (path-get-extension f)
                                      (list #".lnk" #".url" #".exe"))))
         f))))
  (dedupe
   (for/list ([p (in-list files)])
     (application (application-id-from-path p)
                  (path->string (path-replace-extension (file-name-from-path p) ""))
                  (path->string p)
                  "app"
                  '()
                  (path->string p)))))

;; ---- public discovery ---------------------------------------------------

(define/contract (applications-from-dirs dirs [platform (system-type 'os)])
  (->* ((listof path?))
       ((or/c 'macosx 'windows 'unix))
       (listof application?))
  (case platform
    [(macosx) (macos-apps-from-dirs dirs)]
    [(windows) (windows-apps-from-dirs dirs)]
    [else (linux-apps-from-dirs dirs)]))

(define/contract (discover-applications)
  (-> (listof application?))
  (define roots
    (case (system-type 'os)
      [(macosx) (macos-app-roots)]
      [(windows) (windows-app-roots)]
      [else (filter directory-exists? (linux-app-roots))]))
  (applications-from-dirs roots))

;; ---- launching ----------------------------------------------------------

(define (desktop-exec->argv exec)
  ;; Replace freedesktop field codes (no file context in a launcher) and
  ;; tokenize on spaces. %% survives as a literal %. No shell is involved.
  (define no-codes
    (regexp-replace* #rx"%[a-zA-Z]"
                     (string-replace exec "%%" "\u0000")
                     ""))
  (for/list ([token (in-list (string-split (string-replace no-codes "\u0000" "%") " "))]
             #:unless (string=? token ""))
    token))

(define/contract (application-launch app [platform (system-type 'os)])
  (->* (application?) ((or/c 'macosx 'windows 'unix)) boolean?)
  (case platform
    [(macosx)
     (spawn-command "open" (list (application-path app)))]
    [(windows)
     ;; Explorer resolves .lnk/.url shortcuts exactly like the Start Menu
     ;; entry would, without the empty-title argv hack cmd start needs.
     (spawn-command "explorer.exe" (list (application-path app)))]
    [else
     (define id (application-id app))
     (if (string-prefix? id "d")
         (or (spawn-command "gtk-launch" (list (substring id 1)))
             (let ([argv (desktop-exec->argv (application-exec app))])
               (and (pair? argv)
                    (spawn-command (car argv) (cdr argv)))))
         (spawn-command "gtk-launch" (list id)))]))
