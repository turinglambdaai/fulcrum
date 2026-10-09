## Install

All artifacts are reproducible downloads of the same build; the signed
`manifest.json` pins the three per-platform installers that the in-app
updater consumes. Verify any download against `SHA256SUMS.txt`:

```sh
sha256sum -c SHA256SUMS.txt --ignore-missing
```

### macOS — fulcrum-macos.dmg

Open the DMG and drag **Fulcrum.app** to **Applications**. First launch on a
fresh download: right-click the app and choose **Open** once (Gatekeeper
attaches to unsigned builds until Developer ID signing activates).

### Windows — fulcrum-windows-x64.msi

Run the MSI. It installs per-user, adds Start-menu and desktop shortcuts,
and registers the apps with the update channel.

### Linux — fulcrum-linux-x64.deb or fulcrum-linux-x64.tar.gz

Debian/Ubuntu (recommended — installs to `/opt/fulcrum`, adds the
`fulcrum` command, menu entry, and icons):

```sh
sudo apt install ./fulcrum-linux-x64.deb
```

Other distributions — unpack the tarball anywhere and run the binary inside:

```sh
tar -xzf fulcrum-linux-x64.tar.gz
cd fulcrum-linux-x64
./fulcrum
```

### First keystroke

Fulcrum is a launcher: it wants a global hotkey, not a dock click.

- **macOS**: set a hotkey in Fulcrum's settings; the app registers it
  system-wide.
- **Windows**: same, in settings.
- **Linux**: bind your compositor to `fulcrum --toggle`, e.g. GNOME:

  ```sh
  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Fulcrum'
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'fulcrum --toggle'
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>space'
  ```
