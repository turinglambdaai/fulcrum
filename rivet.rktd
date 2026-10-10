#hasheq((name . "fulcrum")
        (display-name . "Fulcrum")
        (version . "0.7.0")
        (build . 7)
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
        (linux-icon . "assets/fulcrum-icon-512.png")
        ;; Native Linux installers (deb installs /opt/fulcrum with a desktop
        ;; entry, rpm builds via rpmbuild, AppImage carries its own GTK4
        ;; closure) ride along with the tar.gz. The release artifact contract
        ;; for the update feed is still the tar.gz (versioned name in
        ;; release.yml, the signed channel manifest, and the updater all pin
        ;; it); the new formats ship as GitHub release assets only.
        (linux-formats . ("deb" "rpm" "appimage"))))
