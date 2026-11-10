# Security policy

DynamicIsland is a local menu-bar app. It uses only documented system facilities and asks for the minimum permissions
(Automation, and Screen Recording for the visualizer — only audio is read).

The only network request the app makes is an optional check of the public GitHub Releases API for a newer version
(`api.github.com`), which can be turned off in the menu (*Check for updates automatically*). Nothing else leaves the
Mac.

## Updating in place

When you confirm an update, the app downloads the release archive from this repository's GitHub release over HTTPS and
installs it only if (1) its SHA-256 equals the digest GitHub publishes for that asset, (2) the unpacked app has this
app's bundle identifier and the announced version, and (3) its code signature verifies and, if this copy is signed with a certificate, is made with the same certificate. A shell script then replaces the
app bundle after the app quits (the old copy is put back if the copy fails). Releases are self-signed, so the trust rests on
HTTPS and the repository's release, not on an Apple Developer ID; if you'd rather not rely on it, update manually from
the release page or build from source.

## Reporting a vulnerability

Please report security problems privately through GitHub: *Security → Report a vulnerability* on this repository. Don't
open a public issue for them. You'll get a reply within a few days.

## Supported versions

Only the latest release receives fixes.
