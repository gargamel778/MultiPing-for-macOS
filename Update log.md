
## 2026.09.04 Version 2.0(20260904)

This is the first release of a **fork** of MultiPing for macOS. Everything below
is additional to upstream v1.4; the original application and its licence are
unchanged and credited in the app's About window.

1. Added latency-over-time graphs: per target, embedded in the List layout, and an overlay comparing several hosts at once.
2. Added Network Scan — discovery by Bonjour, local subnet (computed from the host's address and mask) or an explicit IP range, with selectable results that can be sent straight into a ping session.
3. Scan results show **MAC address and vendor (OUI)**, with reverse-DNS host naming. Sweep results are completed from the ARP cache: a fast `fping` sweep loses a significant share of replies on its own, which was leaving roughly 40% of a real network undiscovered.
4. Added a menu-bar summary with a configurable number of rows, its own sort order independent of the main window, a hover list of failing hosts, and a one-minute latency graph per host.
5. Added per-host tools: HTTP / HTTPS / SSH launchers and a port scanner.
6. Probe settings are now editable while a session is running, without stopping it.
7. Replaced the ad-hoc signature with a **Developer ID signature and Apple notarization**, stapled so it validates offline. Release builds no longer trigger a Gatekeeper warning. `Tools/sign-and-notarize.sh` performs the whole pipeline and rolls back the installed copy if verification fails.
8. Release builds are now **universal (`arm64` + `x86_64`)**. Earlier builds of this fork were arm64-only and would not launch on an Intel Mac despite the stated requirements.
9. The MAC vendor table is generated directly from the IEEE Registration Authority's public registries — MA-L, MA-M, MA-S, IAB and CID — rather than from any redistribution of them. See `DATA-PROVENANCE.md`.
10. Bundled the upstream MIT licence notice, which was previously missing from the application package, and credited the `fping` authors as that project's licence asks.
11. Fixed the vendor lookup consulting the locally-administered address bit before the vendor table, which made every Company ID registration unreachable and reported named vendors as "Locally administered".
12. Corrected `CFBundleDisplayName`, which read "Multiping" in Finder and the app switcher while every other name in the application read "MultiPing".

-----

## 2026.06.24 Version 1.4(20260624)

Upstream release. It was published without notes in this file; the summary below
is reconstructed from the repository, so it records what changed rather than
what the author intended.

1. Introduced the bundled `fping` helper as the probing engine, with `FpingEngine.swift` replacing the previous in-process ping implementation.
2. Added DSCP marking for QoS testing (`DSCPMark.swift`).
3. Added result export to CSV, HTML and Excel-compatible `.xls` (`PingResultsExporter.swift`).
4. Substantially reworked `PingManager` and the results views around the new engine.

-----

## 2025.06.02 Version 1.3(20250602)
1. Added support for the note feature — users can now add labels for each probe target, which will be displayed in the results window.
2. Fixed a critical bug: When the test targets included an IPv6 address, the overall ping process could become stuck with the status remaining “pinging” and no further ping actions being executed.
3. Improved ping test performance and efficiency.

Known Unfixed Bug: Quitting the program using the red close button causes an exception. This issue has not been resolved in the current version.
- Temporary Solution: Use Command+Q or the “Quit” option in the menu to exit the program, which will not  trigger the bug.



-----

## 2025.05.13 Version 1.2(20250513)
1. Added support for IPv6 testing functionality.
2. Added support for domain name testing functionality.
3. The test target input interface now supports mixed input of IPv4, IPv6, and domain names as test targets.
4. Bug fix: Resolved an issue where quickly clicking the "Pause" and "Resume" buttons caused the ping test to incorrectly enter the "Complete" state and become unresponsive.
5. Optimized testing logic and process.


-----

## 2025.05.06 Version 1.1(20250506)
1. Renamed the application to “MultiPing for macOS”.
2. Implemented a cap on concurrent ping tasks and introduced randomized interval jitter to mitigate false failure results when testing a large number of IP addresses.
3. Refined UI layout and improved element design for better usability and aesthetics.
4. Added support for remembering the user’s previously entered IP address list.
5. Introduced an intelligent suggestion feature that recommends an appropriate interval time based on the number of IP addresses being tested.
6. Introduced a new Grid View for displaying results. The original List View remains available.
7. Both Grid and List Views are fully responsive and adapt dynamically to window resizing.
8. Both views support zoom in/out functionality.
9. Both views feature a status bar showing overall success/failure statistics.
10. Both views support sorting by various criteria.
11. Both views support full control of test operations including Start/Stop (Clean) and Pause/Resume.
12. In Grid View, each card displays:
	- The target IP address
	- Success/failure statistics
	- Current test status


-----


## 2025.05.01 Version 1.0(20250501)
1. The initial version of Multping was launched.

