# Changelog

## 1.2

- **Update notifications.** The island announces a new release (green arrow and version; click opens the release
  page). Until you open it, a green chip with the version stays in the expanded island, the menu bar icon carries a
  green dot, and the alert repeats once a day. *Check for updates…* in the menu, and an option to turn the automatic
  check off.
- **Experimental: Now Playing from any app** (off by default; *Settings → Content*). Uses the private MediaRemote
  framework through a helper process, so it can break with a macOS update. Dedicated sources win when both report
  the same track.
- **Settings window** (menu → *Settings…*): General, Displays, Content, About.
- **Visualizer colors.** The artwork colors are harmonized (hues pulled toward the dominant one, contrast stretched, a soft
  foot-to-tip gradient on every bar) so a multicolored cover never gives clashing or flat bars.
- Contributor docs (CONTRIBUTING, SECURITY, code of conduct), issue and PR templates.
- CI (compile + localization check) and a release workflow that builds the `.dmg`/`.zip` on a version tag.
- Homebrew cask template (`packaging/homebrew`).

## 1.1

- **Several displays.** Choose where the island lives: the notch display (automatic), the display under the cursor,
  every display, or one pinned display. The island grows out of the notch when it moves.
- **Displays without a notch.** A virtual island, scaled to the display, in three styles: hidden until needed,
  always visible, always visible with expand-on-click. The size can also be set by hand.
- **Fits the notch automatically.** The notch is measured per display and follows changes of display scaling.
- **Chromium browsers.** Chrome, Brave, Edge and Arc are read like Safari.
- **Visualizer.** Sharp bars are cut out of the track's artwork blurred beyond recognition.
- **Localization.** English and Russian.
- **Releases.** `package.sh` builds a `.dmg` and `.zip`.

## 1.0

First release.
