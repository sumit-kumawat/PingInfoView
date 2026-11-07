import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(Brand.appName) Help")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(helpBody)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Brand.appName) \(Brand.version)")
                            .font(.callout.weight(.semibold))
                        Text("Author: \(Brand.author)")
                        Link(Brand.website, destination: Brand.websiteURL)
                        Link(Brand.email, destination: Brand.mailtoURL)
                    }
                    .font(.callout)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 460, idealWidth: 620, maxWidth: 900, minHeight: 380, idealHeight: 560, maxHeight: 900)
    }
}

private let helpBody = """
PingInfoView watches many hosts in one table. Add names or addresses, press Start, and the table shows which hosts answer, how often they fail, and how long each reply takes.

Hosts
• Separate hosts with spaces, commas, or new lines. An entry can be an IP address, an FQDN such as server.example.com, or a simple name such as router.
• A trailing slash or a web address is accepted: https://example.com/status and router/ both become hosts. 10.0.0.0/24 is still a range.
• 192.168.0.10-192.168.0.20, 192.168.0.10-20, and 192.168.0.0/24 expand to ranges. Ranges stop at the expansion limit.
• 192.168.1.10:443 or example.com:80 checks that a TCP connection opens. No application data is sent.
• In “IP and description” format, put a label after the address: 192.168.1.10 Main Server
• A line that starts with # is a comment.
• Group: Office starts a group. Click a group header to collapse or expand it.
• Drop text files on the window, or choose File → Load Addresses.

Table
Columns fit the width of the window. When it is too narrow, the least important columns are hidden first; the “+n” badge in the header lists them. Click a column title to sort.

Selecting hosts
• Click a row to select it. ⌘-click adds or removes a row. ⇧-click selects everything in between. ⌘⇧-click adds a range without clearing what you already selected.
• ↑ and ↓ move the selection. Hold ⇧ to extend it. ⌘↑ and ⌘↓ jump to the first or last host, and Page Up, Page Down, Home, and End move by a page or to the ends.
• ⌘A selects every visible host. Escape clears the selection, and clears the filter when nothing is selected.
• Type the first letters of a host name or address to jump to it. Pause, then type a letter to move to the next match.
• ← collapses the selected host's group and → expands it.
• ⌘C copies the selected rows (or every visible row when nothing is selected). ⇧⌘C copies host names, one per line. ⌥⌘C copies IP addresses.
• Right-click a selected row to copy, enable, or ping every selected host. Right-click any other row to act on that host alone.

Scan
The header has three icons: New Scan, Rescan, and Stop. New Scan (⌥⌘R) clears succeeded, failed, and history once, then starts. Rescan (⌘R) starts again and keeps the counts you already have. Later rounds in a scan keep the new counts. Turn on “Clear existing results once when a scan starts” in Ping Options to make Rescan clear once too. Reset Counters clears the numbers and leaves the scan stopped.

Results
The table keeps succeeded and failed counts, the failure percentage, the last reply, and the minimum, maximum, and average of successful replies. The failure streak stays visible after a host recovers, and the longest streak keeps the time it was reached.

A failure beep starts once the streak reaches the alert threshold and repeats while the host stays down. The failure command runs once per streak. The recovery beep and command run only if that streak reached the threshold.

History
The lower pane lists pings for the selected host: every ping, only failures, or one line per status change. With several hosts selected, it follows the row you moved to last. Copy in the history title bar puts those lines on the clipboard. Drag the divider to resize the pane. History is capped so long sessions don't grow without limit.

Export
Export and Copy use the selected rows, or every visible row when nothing is selected. Auto export and the log file accept {date} and {time} in the path.

Command line
One round can be saved without opening the window:

PingInfoView.app/Contents/MacOS/PingInfoView /loadfile hosts.txt /scomma results.csv
PingInfoView.app/Contents/MacOS/PingInfoView /shtml report.html 1.1.1.1 example.com

Commands you enter, including custom menu commands, run on this Mac. Host values are inserted as quoted arguments.
"""
