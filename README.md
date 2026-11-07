# PingInfoView

PingInfoView is a macOS utility for pinging many host names and IP addresses and watching the results in one table. It repeats on a timer you choose, counts succeeded and failed replies, and keeps the minimum, maximum, and average response time. Results can be copied or saved as text, CSV, HTML, or XML.

**Author:** Sumit Kumawat  
**Website:** [www.sumitkumawat.com](https://www.sumitkumawat.com)  
**Email:** [hello@sumitkumawat.com](mailto:hello@sumitkumawat.com)

This is a native macOS application. It is not a wrapper around the Windows PingInfoView executable.

## Install

The ready-to-use builds are in `dist/` after packaging:

- `dist/PingInfoView.app` — the application
- `dist/PingInfoView-1.3.0.dmg` — drag the app to Applications
- `dist/PingInfoView-1.3.0.pkg` — installs the app into `/Applications`
- `dist/SHA256SUMS.txt` — checksums for the disk image and package

One universal build runs natively on Apple silicon and Intel Macs with macOS 13 Ventura or later.

The build is signed ad-hoc, not with an Apple Developer ID, so the first time you open a downloaded copy macOS asks you to confirm it. Right-click the app and choose **Open**, or allow it under System Settings → Privacy & Security → **Open Anyway**. To remove that prompt, sign and notarize with a Developer ID (see Build).

## Window

The table always fits the width of the window, so there is no sideways scrolling. On a narrow window the least important columns are hidden first, and the **+n** badge in the header lists them. The column header, group headers, and the history header stay in place while you scroll.

| Shortcut | Action |
| --- | --- |
| ⌘R | Start. Clears the current results first when that option is on |
| ⌥⌘R | New Scan: clear the current results once, then start |
| ⌘. | Stop |
| ⇧⌘R | Reset counters |
| ⌘O | Load addresses |
| ⌘, | Ping Options |
| ⌘C | Copy the selected rows, or every visible row |
| ⇧⌘C | Copy host names, one per line |
| ⌥⌘C | Copy IP addresses, one per line |
| ⌘A | Select all visible hosts |
| ↑ / ↓ | Move the selection. Hold ⇧ to extend it |
| ⌘↑ / ⌘↓ | Jump to the first or last host |
| Escape | Clear the selection |

Click a row to select it. ⌘-click toggles a row, ⇧-click selects a range, and ⌘⇧-click adds a range. Type the start of a name to jump to it. Right-click to copy the selected hosts, their names, or their addresses. These shortcuts stay out of the search field and Ping Options, which keep their own Copy and Select All.

Click a column title to sort and a group header to collapse it. ← and → collapse and expand the selected host's group.

## What it does

- Ping many hosts at once, on a timer, with a limit on how many run at the same time
- ICMP ping and TCP connection checks (`host:port`)
- IPv4 ranges (`192.168.0.10-192.168.0.20`) and CIDR ranges (`192.168.0.0/24`)
- Descriptions, comments, and collapsible groups
- Succeeded, failed, and percent-failed counts, plus min / max / average latency
- Consecutive failure streaks, optional sounds, and optional local commands
- History for the selected host
- Export to text, tab-delimited text, CSV, HTML, and XML
- Load a host file, including by dragging it onto the window
- A menu-bar icon, always-on-top window, and a single-round command-line export

## Host list

Hosts can be separated by spaces, commas, or lines. Choose **IP and description** when a line has a label after the address:

```
Group: DNS
1.1.1.1 Cloudflare DNS
8.8.8.8 Google DNS

Group: Web
example.com:443 Example website
#192.168.1.14 This line is ignored
```

`#` begins a comment. `Group: Name` starts a group. A port uses TCP instead of ICMP. A sample file is in `Examples/hosts.txt`.

If a lot of hosts are up but some are reported as failed, lower **Concurrent pings** in Ping Options. Very large ranges are not expanded past the expansion limit.

## Command line

A save from the command line runs one round and does not open the window:

```bash
PingInfoView.app/Contents/MacOS/PingInfoView /loadfile hosts.txt /scomma results.csv
PingInfoView.app/Contents/MacOS/PingInfoView /shtml report.html 1.1.1.1 example.com
PingInfoView.app/Contents/MacOS/PingInfoView --help
```

`/stext`, `/stab`, `/scomma`, `/stabular`, `/shtml`, `/sverhtml`, and `/sxml` choose the output file. `/PingTimeout`, `/PingSize`, `/MaxConcurrentPings`, `/IPv6`, and `/IPHostDescFormat` match the options in the window.

## Custom menu

Create `~/Library/Application Support/PingInfoView/CustomMenu.ini`, or use **Edit Custom Menu…** in Ping Options. Placeholders such as `%IPAddress%` and `%HostName%` are inserted as quoted arguments. See `Examples/CustomMenu.ini`.

Commands you configure run on your Mac.

## Build

Xcode is not required. The Swift command-line tools are enough.

```bash
make test
./scripts/package.sh
```

`scripts/package.sh` runs the tests, builds a universal app, checks its Info.plist, and writes the disk image, installer package, and checksums into `dist/`. The name, version, bundle identifier, and author details all come from `Sources/PingInfoView/Brand.swift`.

To sign with a Developer ID and notarize, set these before running the script:

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
export NOTARY_PROFILE="pinginfoview"   # xcrun notarytool store-credentials pinginfoview
./scripts/package.sh
```
