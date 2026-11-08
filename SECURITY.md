# Security policy

DynamicIsland is a local menu-bar app. It uses only documented system facilities and asks for the minimum permissions
(Automation, and Screen Recording for the visualizer — only audio is read).

The only network request the app makes is an optional check of the public GitHub Releases API for a newer version
(`api.github.com`), which can be turned off in the menu (*Check for updates automatically*). Nothing else leaves the
Mac.

## Reporting a vulnerability

Please report security problems privately through GitHub: *Security → Report a vulnerability* on this repository. Don't
open a public issue for them. You'll get a reply within a few days.

## Supported versions

Only the latest release receives fixes.
