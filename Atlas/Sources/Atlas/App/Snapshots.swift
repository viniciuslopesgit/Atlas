import SwiftUI
import AppKit

/// `ATLAS_SNAPSHOT=<folder>` renders design snapshots with fixture data to PNG and quits (see scripts/snapshots.sh).
@MainActor
enum Snapshots {
    static let folder = ProcessInfo.processInfo.environment["ATLAS_SNAPSHOT"].map { URL(fileURLWithPath: $0) }

    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pages: [(String, AnyView)] = [
            ("dashboard", AnyView(DashboardBody(summary: fixture).padding(24).frame(width: 1100))),
            ("components", AnyView(components.padding(24).frame(width: 720))),
        ]
        for (name, view) in pages {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    let content = view
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, suffix == "dark" ? .dark : .light)
                        .tint(Palette.accent)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let url = folder.appendingPathComponent("\(name)-\(suffix).png")
                        try? png.write(to: url)
                        print(url.path)
                    }
                }
            }
        }
    }

    private static var components: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Instances", subtitle: "12 instances in Europe (Ireland)") { Button("Launch…") {} }
            SectionHeader("State badges")
            HStack {
                ForEach(["running", "stopped", "pending", "shutting-down", "terminated"], id: \.self) {
                    Badge(text: $0, color: Palette.ec2State($0))
                }
            }
            ErrorBanner(message: "AccessDenied: the user is not authorized to perform ec2:DescribeInstances")
            HStack(spacing: 12) {
                StatCard(title: "Critical findings", value: "3", icon: "exclamationmark.shield.fill", tint: Palette.danger)
                StatCard(title: "Checks passed", value: "14", icon: "checkmark.shield.fill", tint: Palette.success)
            }
            EmptyStateView(icon: "tray", title: "No buckets", message: "Create a bucket in the AWS console, then refresh.")
                .frame(height: 200)
        }
    }

    private static var fixture: DashboardSummary {
        var s = DashboardSummary()
        s.runningInstances = 9; s.stoppedInstances = 3; s.totalInstances = 12
        s.s3BucketCount = 27; s.activeAlarms = 2
        s.currentMonthCost = 1842.37; s.forecastedMonthCost = 2710.10; s.lastMonthCost = 2398.55
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        s.dailyCosts = (0..<22).map { i in
            DailyCost(date: cal.date(byAdding: .day, value: i, to: start)!, amount: 70 + Double((i * 37) % 31) + (i % 7 >= 5 ? -25 : 0))
        }
        s.serviceCosts = [("Amazon Elastic Compute Cloud", 912.4), ("Amazon Relational Database Service", 401.2),
                          ("Amazon Simple Storage Service", 188.9), ("AWS Lambda", 96.3), ("Amazon CloudFront", 71.8),
                          ("Amazon CloudWatch", 44.1), ("Others", 127.6)].map { ServiceCost(serviceName: $0.0, amount: $0.1) }
        return s
    }
}
