# MultiPing for macOS

MultiPing is a lightweight macOS network monitoring utility for pinging many targets at once. It is designed for network engineers, IT administrators, and power users who need a fast visual overview of host reachability, packet loss, and latency across IPv4, IPv6, and domain-name targets.

![MultiPing overview](assets/multiping-v1.4-overview.png)

> **This is a fork, at v2.0.** It builds on
> [u5f2094ee/MultiPing-for-macOS](https://github.com/u5f2094ee/MultiPing-for-macOS)
> (v1.4) and adds latency-over-time graphs, a network scanner with MAC/vendor
> identification, a menu-bar summary, per-host port scanning and live-editable
> probe settings. The screenshot above still shows the v1.4 layout.

---

## Highlights

- **Bulk ICMP probing** with a bundled `fping` engine.
- **IPv4, IPv6, and domain-name targets** can be monitored in the same session.
- **Per-target notes** make large target lists easier to read and export.
- **List and Grid layouts** can be switched while monitoring is still running.
- **Live filtering** by target, note, status, or target type.
- **Latency statistics** for current, average, minimum, and maximum response time.
- **DSCP marking** support for QoS testing.
- **Export results** to CSV, HTML, or Excel-compatible `.xls` files.

Added by this fork:

- **Latency-over-time graphs** — per target, embedded in the list, or overlaid for several hosts at once.
- **Network scan** — discovery by Bonjour, local subnet or an explicit IP range, with **MAC address and vendor (OUI)** identification and reverse-DNS host naming. Sweep results are completed from the ARP cache, because a fast `fping` sweep loses a substantial share of replies on its own.
- **Menu-bar summary** with its own sort order, a hover list of failing hosts, and a one-minute latency graph per host.
- **Per-host tools** — HTTP/HTTPS/SSH launchers and a port scanner.
- **Live-editable probe settings**, changeable without stopping the session.

---

## Features

### Target input

Enter one target per line. Notes are optional and can be separated from the target by a comma, tab, or space.

```text
10.0.0.1
8.8.8.8 public-dns
2001:db8::1, lab-ipv6-gateway
example.com web-test
```

Supported target types:

- IPv4 addresses
- IPv6 addresses
- Domain names

MultiPing remembers the last target list, so repeated checks can be restarted quickly.

### Probe settings

The target collector supports:

- **Timeout** in milliseconds
- **Packet size** in bytes
- **Interval** in seconds
- **DSCP** value from `0` to `63`

The app validates the settings before each run. The interval is automatically adjusted so it remains longer than the timeout window. DSCP values are shown with common labels where applicable, including `CS1`, `CS3`, `AF41`, `EF`, and `CS7`.

### Monitoring layouts

MultiPing provides two result views:

#### List Layout

The List Layout uses a native macOS table and is best for detailed monitoring and troubleshooting.

Available columns include:

- Target
- Note
- Success count
- Failure count
- Failure rate
- Current latency
- Average latency
- Minimum latency
- Maximum latency

Columns can be resized and reordered, and the column order is persisted between runs.

#### Grid Layout

The Grid Layout is optimized for high-density visual monitoring. Each card shows the target, optional note, latest status or response time, success count, and failure count.

Grid results can be sorted by:

- Target
- Success count
- Failure count

### Filtering, sorting, and zooming

Both layouts include a live filter bar. Filtering matches target values, notes, status text, and target type.

The result views also support:

- Sorting by key result fields
- IPv4-aware target sorting
- Zoom in and zoom out for dense screens
- Reachable and failed counters in the status bar

### Session controls

During a monitoring session you can:

- Start pinging
- Pause
- Resume
- Stop and clear results
- Switch between List and Grid layouts
- Export the currently displayed results

### Export

Results can be exported from either layout as:

- **Excel-compatible `.xls`**
- **CSV**
- **HTML**

Exported fields include target, type, note, current latency, average latency, minimum latency, maximum latency, success count, failure count, failure rate, and status.

---

## Engine and reliability

MultiPing uses a bundled `fping` helper for bulk ICMP probing. IPv4/domain targets and IPv6 targets are processed in separate `fping` batches, improving efficiency for larger target sets.

The app intentionally does not silently fall back to the legacy system `ping` command. If the bundled engine is missing, not executable, or returns a fatal error, MultiPing stops the test and displays repair guidance instead of showing misleading results.

Additional reliability behavior:

- Automatic retry when the `fping` process times out
- Clear engine-unavailable status when probing cannot continue
- Safer shutdown when closing result windows or quitting the app
- Historical latency statistics are preserved across temporary failures during a session

---

## How to run from source

1. Clone or download this repository.
2. Open `MultiPing.xcodeproj` in Xcode.
3. Select the **MultiPing for macOS** target.
4. Build and run the app.
5. Enter targets, choose a layout, and click **Start ping**.

The current project targets **macOS 13.5 or later**. Because the project file uses modern Xcode project structure, **Xcode 16 or later is recommended** for opening and building the current source tree.

---

## Release app notes

Builds produced by `Tools/sign-and-notarize.sh` are signed with a Developer ID
certificate and notarized by Apple, with the ticket stapled, so they launch
without any Gatekeeper prompt and validate offline. If you build the app
yourself in Xcode without that certificate, the result is ad-hoc signed and
macOS *will* block it — in that case open **System Settings → Privacy &
Security** and choose **Open Anyway**.

Do not remove the bundled `fping` file from the app package. MultiPing depends on it for ICMP probing.

---

## Requirements

- macOS 13.5 or later
- Apple Silicon or Intel Mac — release builds are universal (`arm64` + `x86_64`)
- Bundled `fping` helper included in the app resources

---

## Third-party components

**fping** — bundled for ICMP probing. This product includes software developed
by Stanford University, by Roland Schemers, Jeremy Cheng, Rick Rodgers, Scott
Trihus and David Papp. Licence text ships in the app bundle and in the source
tree as `fping_LICENSE.txt`.

**MAC vendor data** — `MultiPing/oui.txt` is generated from the IEEE
Registration Authority's public registries (MA-L, MA-M, MA-S, IAB and CID) by
`Tools/refresh-oui.sh` in the companion MultiPing-iOS repository. It is not
derived from any redistribution of that data. See
[DATA-PROVENANCE.md](DATA-PROVENANCE.md) for the sources and why they may be
redistributed.

**Upstream project** — this fork is derived from
[u5f2094ee/MultiPing-for-macOS](https://github.com/u5f2094ee/MultiPing-for-macOS),
© 2025 u5f2094ee, MIT License. The notice ships in the app bundle as
`MultiPing_LICENSE.txt` and in the source tree as [LICENSE](LICENSE).

---

## Acknowledgements

Special thanks to Gemini, Codex, GPT-o3, and GPT-o4-mini-high for their support and contributions during the development of this project.
