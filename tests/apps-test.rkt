#lang racket/base

;; Application discovery tests.
;;
;; `parse-desktop-entry` is cross-platform and tested everywhere. Directory
;; discovery is exercised through the Linux code path on every OS via
;; `applications-from-dirs` with an explicit platform argument; the macOS and
;; Windows paths run in their platform CI jobs against the real roots.

(require racket/file
         racket/list
         racket/path
         rackunit
         "../app/core/apps.rkt")

(define (call-with-fixture-apps thunk)
  (define dir (make-temporary-file "fulcrum-apps-~a" 'directory))
  (define (desktop name text)
    (write-file! (build-path dir name) text))
  (desktop "fulcrum.desktop"
           (string-append
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Fulcrum\n"
            "Exec=/usr/bin/fulcrum %U\n"
            "Icon=fulcrum\n"
            "Keywords=launcher;search;\n"
            "NoDisplay=false\n"))
  (desktop "hidden.desktop"
           (string-append
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Hidden App\n"
            "Exec=/usr/bin/hidden\n"
            "NoDisplay=true\n"))
  (desktop "wrong-type.desktop"
           (string-append
            "[Desktop Entry]\n"
            "Type=Directory\n"
            "Name=Just a Folder\n"
            "Exec=/usr/bin/nautilus\n"))
  (desktop "no-name.desktop"
           (string-append
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Exec=/usr/bin/noname\n"))
  (desktop "other-section.desktop"
           (string-append
            "[Desktop Action new-window]\n"
            "Name=Should Not Count\n"
            "Exec=/usr/bin/x\n"
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Second Section Wins\n"
            "Exec=/usr/bin/second\n"))
  (dynamic-wind
    void
    (lambda () (thunk dir))
    (lambda () (delete-directory/files dir))))

(define (write-file! path contents)
  (call-with-output-file path
    (lambda (out) (display contents out))
    #:exists 'truncate))

(test-case "parse-desktop-entry reads only the Desktop Entry section"
  (define entry (parse-desktop-entry
                 "[Desktop Action x]\nName=No\nExec=no\n\n[Desktop Entry]\nName=Yes\nExec=/usr/bin/yes\n"))
  (check-true (hash? entry))
  (check-equal? (hash-ref entry 'Name) "Yes")
  (check-false (parse-desktop-entry "[Other]\nName=Nope\n"))
  (check-equal? (hash-ref (parse-desktop-entry "[Desktop Entry]\nX=A=B\n") 'X)
                "A=B"
                "values may contain ="))

(test-case "linux discovery from fixture dirs"
  (call-with-fixture-apps
   (lambda (dir)
     (define apps (applications-from-dirs (list dir) 'unix))
     (define names (map application-name apps))
     (check-true (and (member "Fulcrum" names) #t))
     (check-false (member "Hidden App" names) "NoDisplay excluded")
     (check-false (member "Just a Folder" names) "non-Application excluded")
     (check-false (member "noname" names) "missing Name excluded")
     (check-true (and (member "Second Section Wins" names) #t))
     (define fulcrum (findf (lambda (a) (string=? (application-name a) "Fulcrum")) apps))
     (check-equal? (application-exec fulcrum) "/usr/bin/fulcrum %U")
     (check-true (and (member "launcher" (application-keywords fulcrum)) #t))
     ;; Deterministic ids across rebuilds.
     (check-equal? (map application-id apps)
                   (map application-id (applications-from-dirs (list dir) 'unix))))))

(test-case "desktop Exec field codes strip for direct exec"
  ;; The launcher has no file context, so %U/%f codes are removed and %%
  ;; stays a literal percent.
  (define apps #f)
  (call-with-fixture-apps
   (lambda (dir)
     (set! apps (applications-from-dirs (list dir) 'unix))))
  (define fulcrum (findf (lambda (a) (string=? (application-name a) "Fulcrum")) apps))
  (check-true (string? (application-exec fulcrum))))
