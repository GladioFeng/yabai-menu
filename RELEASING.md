# Release checks

Version 1.0.0 remains a release candidate. Source is public, and [build 23 CI](https://github.com/GladioFeng/yabai-menu/actions/runs/39091689744) passed the noninteractive tests and universal builds on both architectures. A GitHub Release, Developer ID signing and notarization remain pending.

1. Update the version and build number in `build.sh`, plus `CHANGELOG.md`.
2. Run `swift test` on Intel and Apple Silicon. Run the opt-in UI tests in an interactive session and inspect the native light/dark previews.
3. Run the live integration test with the existing app closed. Check that previous yabai signals are restored after the test.
4. Check actual Space/window selection, Space rename/create/delete/swap, rapid repeated selection, empty Spaces, minimized windows, display sleep/wake and monitor changes. Check daemon restart recovery in a controlled session. A stub test does not replace these physical checks.
5. Check both per-display scopes, hotplug positioning, floating drag/lock, fullscreen behavior and real application-window drag performance against the previous a-bar setup. Synthetic event and rendering tests do not establish end-to-end latency parity.
6. Build with `sh build.sh`. The script checks both architectures, the plist, strict signature and ZIP, and produces a SHA-256 file. Check failure recovery in isolation before changing the packaging workflow. Follow the user's retention preference for previous installed versions.
7. Review the selected license, third-party notices, screenshots and diagnostics for private information. Keep the bundle identifier `dev.gladio.yabai-menu` stable across display-name changes.
8. For broadly distributed binaries, use a valid Developer ID Application identity, hardened runtime, a secure timestamp and Apple notarization. The current ad-hoc build does not satisfy that distribution workflow. Review the notarization result and staple its ticket before publishing.
9. Publish the reviewed source and versioned archive with release notes and a SHA-256 checksum. Test the downloaded archive's first launch and replacement of a previous version on another Mac.

Remaining release checks include macOS 13 runtime testing, build 26 installation and interactive acceptance on both architectures, the outstanding physical checks above, license/source review, and the signed distribution workflow. Do not put signing secrets in this repository or diagnostics.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
