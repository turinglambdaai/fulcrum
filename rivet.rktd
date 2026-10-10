#hasheq((name . "fulcrum")
        (display-name . "Fulcrum")
        (version . "0.6.0")
        (build . 6)
        (identifier . "site.jrtx.fulcrum")
        (release-channel . stable)
        (url-schemes . ("fulcrum"))
        (file-associations . ())
        (macos-min-version . "14.0")
        (windows-min-version . "10.0.19041.0")
        (backend . "app/backend.rkt")
        (module . "backend")
        (entry . "start")
        (protocol . 1)
        (resources . ("shared/i18n"))
        ;; The release artifact contract is the tar.gz (versioned name in
        ;; release.yml, the signed channel manifest, and the update feed all
        ;; pin it); no native deb/rpm/AppImage on this line.
        (linux-formats . ()))
