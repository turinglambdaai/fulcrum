#hasheq((name . "fulcrum")
        (display-name . "Fulcrum")
        (version . "0.13.3")
        (build . 19)
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
        (macos-icon . "assets/fulcrum.icns")
        ;; Rivet v0.12.0 builds a drag-to-Applications Finder DMG when a
        ;; 1320x800 backdrop PNG is staged before release packaging.
        (dmg-background . "assets/dmg-background.png")
        (windows-icon . "assets/fulcrum.ico")
        (linux-icon . "assets/fulcrum-icon-512.png")
        ;; Native Linux installers (deb installs /opt/fulcrum with a desktop
        ;; entry, rpm builds via rpmbuild, AppImage carries its own GTK4
        ;; closure) ride along with the tar.gz. The signed update feed carries
        ;; both tar.gz and AppImage: existing portable/manual installs retain
        ;; the tar.gz path, while an AppImage process selects the AppImage by
        ;; installer kind so Rivet's atomic AppImage replacement can own the
        ;; eventual in-app install. deb/rpm remain package-manager-owned.
        ;; Native Linux installers (deb/rpm/AppImage) are temporarily
        ;; disabled: the pinned rivet revision's release summary crashes on
        ;; a non-empty linux-formats list ("deb" applied as a procedure).
        ;; Restore this line once the upstream fix lands and the pin moves.
        (linux-formats . ()))
        ;; Mac installer artwork is rendered from its editable SVG in the
        ;; release workflow. Windows installer bitmaps remain undeclared
        ;; until the files exist; never configure placeholder paths.