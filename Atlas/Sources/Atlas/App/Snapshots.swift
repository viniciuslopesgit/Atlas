import SwiftUI
import AppKit

/// `ATLAS_SNAPSHOT=<folder>` renders design snapshots with fixture data to PNG and quits (see scripts/snapshots.sh).
@MainActor
enum Snapshots {
    static let folder = ProcessInfo.processInfo.environment["ATLAS_SNAPSHOT"].map { URL(fileURLWithPath: $0) }

    @available(macOS 13, *) // ImageRenderer
    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pages: [(String, AnyView)] = [
            ("dashboard", AnyView(DashboardBody(summary: fixture).padding(24).frame(width: 1100))),
            ("components", AnyView(components.padding(24).frame(width: 720))),
            ("iac", AnyView(iac.padding(24).frame(width: 900))),
            ("stacks", AnyView(stacks.padding(24).frame(width: 900))),
            ("diagram", AnyView(diagram.padding(24))),
        ]
        // ATLAS_SNAPSHOT_TF=<folder> also draws that Terraform folder's diagram, in the Architecture view.
        if let tf = ProcessInfo.processInfo.environment["ATLAS_SNAPSHOT_TF"] {
            pages.append(("diagram-folder", AnyView(diagram(folder: URL(fileURLWithPath: tf)).padding(24))))
        }
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
            SectionHeader("Inspector")
            VStack(alignment: .leading, spacing: 6) {
                Text("web-01").font(Typo.panelTitle)
                DetailRow("Instance ID", "i-0a1b2c3d4e5f60718", copyable: true)
                DetailRow("Availability Zone", "eu-west-1a")
            }
            EmptyStateView(icon: "tray", title: "No buckets", message: "Create a bucket in the AWS console, then refresh.")
                .frame(height: 200)
        }
    }

    private static var iac: some View {
        let output = [
            "$ terraform plan -out=atlas.tfplan",
            "aws_s3_bucket.logs: Refreshing state... [id=acme-logs]",
            "",
            "Terraform will perform the following actions:",
            "",
            "  # aws_instance.web_server will be updated in-place",
            "  ~ resource \"aws_instance\" \"web_server\" {",
            "      ~ tags = {",
            "          + \"ManagedBy\" = \"Atlas\"",
            "        }",
            "    }",
            "",
            "  # aws_security_group.legacy will be destroyed",
            "  - resource \"aws_security_group\" \"legacy\" {",
            "",
            "Plan: 0 to add, 1 to change, 1 to destroy.",
            "Warning: Argument is deprecated",
            "Finished in 6.4s",
        ].enumerated().map { IaCModel.Line(id: $0.offset, text: $0.element) }
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "acme-platform", subtitle: "~/Projects/acme-platform/infra") {
                HStack(spacing: 8) {
                    Badge(text: "Changes to apply", color: Palette.warning)
                    Badge(text: "Terraform v1.9.8", color: Palette.neutral)
                }
            }
            NoticeBanner(message: "Added 14 resource(s) to acme-platform: ec2.tf, security_groups.tf, imports.tf.")
            TerminalLines(lines: output)
                .background(Color(nsColor: .textBackgroundColor))
                .card(radius: Radius.tile)
        }
    }

    /// The diagram's blocks and links, laid out as the Diagram tab draws them (without pan and zoom).
    private static var diagram: some View {
        let hcl = """
        data "aws_availability_zones" "all" {}
        resource "aws_vpc" "main" { cidr_block = "10.0.0.0/16" }
        resource "aws_subnet" "private" {
          count = 3
          vpc_id = aws_vpc.main.id
          availability_zone = data.aws_availability_zones.all.names[count.index]
        }
        resource "aws_security_group" "nodes" { vpc_id = aws_vpc.main.id }
        resource "aws_iam_role" "cluster" { name = "cluster" }
        module "cluster" {
          source = "./cluster"
          subnets = aws_subnet.private[*].id
          role = aws_iam_role.cluster.arn
          security_group = aws_security_group.nodes.id
        }
        resource "aws_s3_bucket" "logs" { bucket = "logs" }
        resource "helm_release" "ingress" { depends_on = [module.cluster] }
        resource "aws_cloudwatch_log_group" "app" { name = module.cluster.name }
        """
        let graph = TerraformConfig.link(TerraformConfig.blocks(in: hcl, file: "main.tf"))
        let scene = DiagramScene(graph)
        let cluster = TerraformModuleSummary(TerraformConfig.link(TerraformConfig.blocks(in: """
        resource "aws_eks_cluster" "this" {}
        resource "aws_eks_node_group" "this" {}
        resource "aws_iam_role" "nodes" {}
        """, file: "eks.tf")))
        return DiagramContent(scene: scene, selection: "module.cluster", hovered: nil, matches: nil, modules: ["module.cluster": cluster])
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .card(radius: Radius.tile)
    }

    /// `ATLAS_SNAPSHOT_OPEN` opens a block (or `module:<path>`) as double-clicking it does.
    private static func diagram(folder: URL) -> some View {
        let env = ProcessInfo.processInfo.environment
        let open = env["ATLAS_SNAPSHOT_OPEN"].map { $0.hasPrefix("module:") ? TerraformDiagramView.Focus.Target.module(String($0.dropFirst(7))) : .block($0) }
        let scene = TerraformDiagramView.scene(mode: .architecture, stack: TerraformStack.load(root: folder), graph: nil, hidden: [], focus: open)!
        return DiagramContent(scene: scene, selection: env["ATLAS_SNAPSHOT_SELECT"], hovered: nil, matches: nil, modules: [:])
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .card(radius: Radius.tile)
    }

    private static var stacks: some View {
        var drifted = StackEntry(name: "production-network", projectPath: "/p", accountId: "a", region: "eu-west-1")
        drifted.driftStatus = .drifted
        var clean = StackEntry(name: "data-platform", projectPath: "/p", accountId: "a", region: "eu-west-1")
        clean.driftStatus = .clean
        var failed = StackEntry(name: "legacy-batch", projectPath: "/p", accountId: "a", region: "us-east-1")
        failed.status = .failed
        let diff = """
          # aws_security_group.web will be updated in-place
          ~ resource "aws_security_group" "web" {
              ~ ingress = [
                  - { from_port = 22, cidr_blocks = ["0.0.0.0/0"] },
                ]
            }
        """.components(separatedBy: "\n").enumerated().map { IaCModel.Line(id: $0.offset, text: $0.element) }
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Stacks", subtitle: "Terraform stacks with run history and drift checks")
            HStack(spacing: 14) {
                StatCard(title: "Ready", value: "4", icon: "checkmark.circle.fill", tint: Palette.success)
                StatCard(title: "Running", value: "1", icon: "play.circle.fill", tint: Palette.accent)
                StatCard(title: "Drifted", value: "1", icon: "arrow.triangle.branch", tint: Palette.warning)
                StatCard(title: "Failed", value: "1", icon: "xmark.octagon.fill", tint: Palette.danger)
            }
            .frame(height: 74)
            HStack(spacing: 10) {
                ForEach([drifted, clean, failed]) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).font(.body.weight(.medium))
                        StackBadges(stack: s)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: Radius.tile)
                }
            }
            Text("1 to change").font(.headline)
            TerminalLines(lines: diff).background(Color(nsColor: .textBackgroundColor)).card(radius: Radius.tile)
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
