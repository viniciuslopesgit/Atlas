import Foundation
import Testing
import SwiftUI
import AppKit
@testable import Atlas

struct TerraformGraphTests {
    static let hcl = """
    variable "region" { default = "eu-west-1" }
    locals {
      name = "app-${var.region}"
      tags = { Name = local.name }
    }
    data "aws_availability_zones" "all" {}
    resource "aws_vpc" "main" {
      cidr_block = "10.0.0.0/16"
      tags = local.tags
    }
    resource "aws_subnet" "private" {
      count  = 2
      vpc_id = aws_vpc.main.id
      # aws_s3_bucket.logs is only mentioned in a comment
      availability_zone = data.aws_availability_zones.all.names[count.index]
    }
    resource "aws_s3_bucket" "logs" {
      bucket = "logs"
      policy = <<-JSON
        { "Resource": "aws_vpc.main" }
      JSON
    }
    module "cluster" {
      source  = "./cluster"
      subnets = aws_subnet.private[*].id
    }
    output "cluster" { value = module.cluster.name }
    """

    static var graph: TerraformGraph { TerraformConfig.link(TerraformConfig.blocks(in: hcl, file: "main.tf")) }

    @Test func readsEveryKindOfBlock() {
        let g = Self.graph
        #expect(Set(g.nodes.map(\.id)) == ["var.region", "local.name", "local.tags", "data.aws_availability_zones.all",
                                          "aws_vpc.main", "aws_subnet.private", "aws_s3_bucket.logs", "module.cluster",
                                          "output.cluster"])
        #expect(g.node("aws_subnet.private")?.repeated == "count")
        #expect(g.node("module.cluster")?.moduleSource == "./cluster")
        #expect(g.node("aws_vpc.main")?.line == 7)
        #expect(g.node("aws_vpc.main")?.file == "main.tf")
        #expect(g.node("data.aws_availability_zones.all")?.kind == .data)
    }

    @Test func linksReferencesButNotCommentsOrHeredocs() {
        let g = Self.graph
        #expect(g.node("aws_subnet.private")?.dependencies.sorted() == ["aws_vpc.main", "data.aws_availability_zones.all"])
        #expect(g.node("aws_s3_bucket.logs")?.dependencies == [])
        #expect(g.node("local.tags")?.dependencies == ["local.name"])
        #expect(g.node("local.name")?.dependencies == ["var.region"])
        #expect(g.node("output.cluster")?.dependencies == ["module.cluster"])
        #expect(g.dependents(of: "aws_vpc.main") == ["aws_subnet.private"])
        #expect(g.edges.contains(.init(from: "aws_subnet.private", to: "module.cluster")))
    }

    @Test func referencesInsideStringsOnlyCountInInterpolations() {
        let text = """
        resource "aws_iam_policy" "p" {
          name   = "aws_vpc.main ${var.region} \\"${local.name}\\" aws_s3_bucket.logs"
          policy = <<EOF
        { "a": "aws_vpc.other", "b": "${aws_s3_bucket.logs.arn}", "c": "%{ if var.on }x%{ endif }" }
        EOF
          tags = { for k, v in local.tags : k => "${v}" }
        }
        """
        #expect(TerraformConfig.references(in: TerraformConfig.expressions(text))
                == ["var.region", "local.name", "aws_s3_bucket.logs", "var.on", "local.tags"])
    }

    @Test func filesSavedOnWindowsAreRead() {
        // CR LF is one Character in Swift: before the fix such a file was one line and had no blocks.
        let windows = Self.hcl.replacingOccurrences(of: "\n", with: "\r\n")
        let g = TerraformConfig.link(TerraformConfig.blocks(in: windows, file: "main.tf"))
        #expect(g.nodes.map(\.id) == Self.graph.nodes.map(\.id))
        #expect(g.node("aws_subnet.private")?.dependencies == Self.graph.node("aws_subnet.private")?.dependencies)
        #expect(g.node("aws_vpc.main")?.line == 7)
    }

    @Test func theNetworkStaysVisibleAndFirst() {
        let hcl = """
        variable "vpc_id" { default = "vpc-1" }
        resource "aws_iam_role" "r" {}
        resource "aws_security_group" "sg" { vpc_id = var.vpc_id }
        resource "aws_instance" "i" {
          vpc_security_group_ids = [aws_security_group.sg.id]
          iam_instance_profile   = aws_iam_role.r.name
        }
        """
        let g = TerraformConfig.link(TerraformConfig.blocks(in: hcl, file: "main.tf")).hiding([.variable])
        #expect(g.node("var.vpc_id")?.isNetworkRoot == true)
        #expect(g.node("var.vpc_id")?.defaultValue == "vpc-1")
        let slots = TerraformGraphLayout.slots(g)
        #expect(slots["var.vpc_id"]?.column == 0)
        #expect(slots.filter { $0.value.column == 0 }.min { $0.value.row < $1.value.row }?.key == "var.vpc_id")
        // A block that uses nothing waits for the column before its first user.
        #expect(slots["aws_iam_role.r"]?.column == slots["aws_instance.i"]!.column - 1)
    }

    @Test func hidingKeepsLinksThroughHiddenBlocks() {
        let shown = Self.graph.hiding([.variable, .local, .output])
        #expect(shown.count(.local) == 0 && shown.count(.variable) == 0 && shown.count(.output) == 0)
        #expect(shown.node("aws_vpc.main")?.dependencies == [])
        // Hiding data sources: the subnet loses the link, nothing dangles.
        let noData = Self.graph.hiding([.data])
        #expect(noData.node("aws_subnet.private")?.dependencies == ["aws_vpc.main"])
        #expect(noData.edges.allSatisfy { noData.node($0.from) != nil && noData.node($0.to) != nil })
    }

    @Test func hiddenLocalsCollapseIntoTheirInputs() {
        let g = Self.graph.hiding([.local])
        #expect(g.node("aws_vpc.main")?.dependencies == ["var.region"])
    }

    @Test func layoutPointsEveryEdgeRight() {
        let g = Self.graph
        let slots = TerraformGraphLayout.slots(g)
        #expect(slots.count == g.nodes.count)
        for e in g.edges { #expect(slots[e.from]!.column < slots[e.to]!.column) }
        let last = slots.values.map(\.column).max()
        #expect(slots["output.cluster"]?.column == last)
        // No two blocks share a place.
        let places = slots.values.map { "\($0.column):\($0.row)" }
        #expect(Set(places).count == places.count)
    }

    @Test func layoutSurvivesCycles() {
        let a = TerraformGraph.Node(id: "aws_vpc.a", kind: .resource, type: "aws_vpc", name: "a", file: "f", line: 1, source: "",
                                    dependencies: ["aws_vpc.b"])
        let b = TerraformGraph.Node(id: "aws_vpc.b", kind: .resource, type: "aws_vpc", name: "b", file: "f", line: 2, source: "",
                                    dependencies: ["aws_vpc.a"])
        #expect(TerraformGraphLayout.slots(TerraformGraph(nodes: [a, b])).count == 2)
    }

    @Test func readsTheTopLevelTfFilesOfAFolder() throws {
        let folder = TestTemp.root.appendingPathComponent("graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cluster"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.hcl.write(to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "resource \"aws_eks_cluster\" \"x\" {}".write(to: folder.appendingPathComponent("cluster/eks.tf"), atomically: true, encoding: .utf8)
        try "not terraform".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let g = TerraformConfig.graph(folder: folder)
        #expect(g.nodes.count == 9)
        #expect(g.node("aws_eks_cluster.x") == nil)
        let inner = TerraformConfig.graph(folder: folder.appendingPathComponent("cluster"))
        #expect(inner.nodes.map(\.id) == ["aws_eks_cluster.x"])
    }

    @Test func nodesGetAServiceAndSymbol() {
        let g = Self.graph
        #expect(TerraformNodeStyle.of(g.node("aws_vpc.main")!).label == "VPC")
        #expect(TerraformNodeStyle.of(g.node("aws_s3_bucket.logs")!).label == "S3")
        #expect(TerraformNodeStyle.of(g.node("module.cluster")!).label == "Module")
        let sg = TerraformGraph.Node(id: "aws_security_group.x", kind: .resource, type: "aws_security_group", name: "x", file: "", line: 1, source: "")
        #expect(TerraformNodeStyle.of(sg).label == "Security group")
        let other = TerraformGraph.Node(id: "cloudflare_record.x", kind: .resource, type: "cloudflare_record", name: "x", file: "", line: 1, source: "")
        #expect(TerraformNodeStyle.of(other).label == "CLOUDFLARE")
    }

    @MainActor @Test func diagramIsATabOfTheStack() {
        #expect(StackTab.allCases.map(\.rawValue).contains("Diagram"))
    }
}

/// The diagram's layout, camera and keyboard, without a window.
struct TerraformDiagramTests {
    static func node(_ id: String, _ deps: [String] = [], kind: TerraformGraph.Kind = .resource) -> TerraformGraph.Node {
        let parts = id.split(separator: ".").map(String.init)
        return TerraformGraph.Node(id: id, kind: kind, type: parts.first ?? "", name: parts.last ?? "", file: "main.tf", line: 1,
                                   source: "", dependencies: deps)
    }

    /// a → b → c, and a → c directly: the direct link crosses b's column.
    static let chain = TerraformGraph(nodes: [Self.node("aws_vpc.a"), Self.node("aws_subnet.b", ["aws_vpc.a"]),
                                              Self.node("aws_instance.c", ["aws_subnet.b", "aws_vpc.a"])])

    @Test func longLinksGetAStopInEachColumnTheyCross() {
        let layout = TerraformGraphLayout.layout(Self.chain)
        #expect(layout.slots.count == 3)
        let stops = layout.waypoints[.init(from: "aws_vpc.a", to: "aws_instance.c")]
        #expect(stops?.map(\.column) == [1])
        // The stop has a place of its own, not the block's.
        #expect(stops?.first != layout.slots["aws_subnet.b"])
        #expect(layout.waypoints[.init(from: "aws_vpc.a", to: "aws_subnet.b")] == nil)
        // The diagram is big enough for the stop.
        let geometry = DiagramGeometry(layout)
        let lowest = (Array(layout.slots.values) + (stops ?? [])).map(\.row).max()!
        #expect(geometry.size.height >= DiagramGeometry.point(.init(column: 0, row: lowest)).y + DiagramGeometry.nodeSize.height / 2)
    }

    @Test func clicksFindTheBlockUnderThePointer() {
        let geometry = DiagramGeometry(TerraformGraphLayout.layout(Self.chain))
        let center = geometry.centers["aws_subnet.b"]!
        #expect(geometry.node(at: center) == "aws_subnet.b")
        #expect(geometry.node(at: CGPoint(x: center.x + DiagramGeometry.nodeSize.width / 2 - 1, y: center.y)) == "aws_subnet.b")
        #expect(geometry.node(at: CGPoint(x: center.x + DiagramGeometry.nodeSize.width / 2 + 10, y: center.y)) == nil)
        #expect(geometry.node(at: .zero) == nil)
    }

    @Test func zoomKeepsThePointUnderThePointer() {
        var camera = DiagramCamera(zoom: 1, pan: CGSize(width: 30, height: -20))
        let pointer = CGPoint(x: 400, y: 250)
        let under = camera.content(pointer)
        camera.zoom(to: 1.6, around: pointer)
        #expect(camera.zoom == 1.6)
        #expect(abs(camera.screen(under).x - pointer.x) < 0.001 && abs(camera.screen(under).y - pointer.y) < 0.001)
        camera.zoom(to: 50, around: pointer)
        #expect(camera.zoom == DiagramCamera.zoomRange.upperBound)
        camera.zoom(to: 0.001, around: pointer)
        #expect(camera.zoom == DiagramCamera.zoomRange.lowerBound)
    }

    @Test func fitShowsEverythingInTheFreeAreaWithoutEnlarging() {
        var camera = DiagramCamera()
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        camera.fit(CGSize(width: 1600, height: 600), in: area)
        #expect(camera.zoom == 0.5)
        #expect(camera.shows(CGRect(x: 0, y: 0, width: 1600, height: 600), in: area.insetBy(dx: -0.5, dy: -0.5)))
        camera.fit(CGSize(width: 200, height: 100), in: area)
        #expect(camera.zoom == 1)
        #expect(camera.screen(CGPoint(x: 100, y: 50)) == CGPoint(x: 400, y: 300))
        // Nothing to fit in: the camera stays as it is.
        let before = camera
        camera.fit(CGSize(width: 200, height: 100), in: .zero)
        #expect(camera == before)
    }

    @Test func centeringAndMovingAndWhatIsInView() {
        var camera = DiagramCamera(zoom: 2, pan: .zero)
        let area = CGRect(x: 0, y: 0, width: 600, height: 400)
        camera.center(CGPoint(x: 500, y: 500), in: area)
        #expect(camera.screen(CGPoint(x: 500, y: 500)) == CGPoint(x: 300, y: 200))
        camera.move(by: CGSize(width: 10, height: -5))
        #expect(camera.screen(CGPoint(x: 500, y: 500)) == CGPoint(x: 310, y: 195))
        let visible = camera.visible(in: area.size)
        #expect(visible.width == 300 && visible.height == 200)
        #expect(camera.shows(CGRect(x: 490, y: 490, width: 20, height: 20), in: area))
        #expect(!camera.shows(CGRect(x: 0, y: 0, width: 20, height: 20), in: area))
    }

    @Test func arrowKeysFollowTheLinks() {
        let graph = TerraformGraph(nodes: [Self.node("aws_vpc.a"), Self.node("aws_vpc.z"), Self.node("aws_subnet.b", ["aws_vpc.a"]),
                                           Self.node("aws_instance.c", ["aws_subnet.b"])])
        let slots = TerraformGraphLayout.slots(graph)
        typealias Nav = DiagramNavigation
        #expect(Nav.next(from: nil, .right, in: graph, slots: slots) == "aws_vpc.a" || Nav.next(from: nil, .right, in: graph, slots: slots) == "aws_vpc.z")
        #expect(Nav.next(from: "aws_vpc.a", .right, in: graph, slots: slots) == "aws_subnet.b")
        #expect(Nav.next(from: "aws_subnet.b", .right, in: graph, slots: slots) == "aws_instance.c")
        #expect(Nav.next(from: "aws_instance.c", .left, in: graph, slots: slots) == "aws_subnet.b")
        #expect(Nav.next(from: "aws_subnet.b", .left, in: graph, slots: slots) == "aws_vpc.a")
        #expect(Nav.next(from: "aws_instance.c", .right, in: graph, slots: slots) == nil)
        // Up and down stay in the column.
        let top = ["aws_vpc.a", "aws_vpc.z"].min { slots[$0]!.row < slots[$1]!.row }!
        let bottom = top == "aws_vpc.a" ? "aws_vpc.z" : "aws_vpc.a"
        #expect(Nav.next(from: top, .down, in: graph, slots: slots) == bottom)
        #expect(Nav.next(from: bottom, .up, in: graph, slots: slots) == top)
        #expect(Nav.next(from: top, .up, in: graph, slots: slots) == nil)
        // A block with nothing linked on the right moves to the nearest block there.
        #expect(Nav.next(from: "aws_vpc.z", .right, in: graph, slots: slots) == "aws_subnet.b")
    }

    @Test func modulesSayWhatTheyHold() {
        let inner = TerraformGraph(nodes: [Self.node("aws_eks_cluster.a"), Self.node("aws_eks_node_group.b"), Self.node("aws_iam_role.c"),
                                           Self.node("data.aws_region.r", kind: .data), Self.node("module.x", kind: .module)])
        let summary = TerraformModuleSummary(inner)
        #expect(summary.resources == 3 && summary.dataSources == 1 && summary.modules == 1)
        #expect(summary.services == ["EKS", "IAM"])
        #expect(summary.text == "3 resources, 1 module")
        #expect(TerraformModuleSummary(TerraformGraph(nodes: [Self.node("aws_vpc.a")])).text == "1 resource")
        #expect(TerraformDiagramView.counts(inner) == "3 resources, 1 module, 1 data source")
        #expect(TerraformDiagramView.counts(TerraformGraph(nodes: [])) == "No blocks")
    }

    @Test func servicesHaveAFamily() {
        #expect(TerraformNodeStyle.of(Self.node("aws_vpc.a")).category == .network)
        #expect(TerraformNodeStyle.of(Self.node("aws_iam_role.a")).category == .security)
        #expect(TerraformNodeStyle.of(Self.node("aws_s3_bucket.a")).category == .storage)
        #expect(TerraformNodeStyle.of(Self.node("aws_eks_cluster.a")).category == .compute)
        #expect(TerraformNodeStyle.of(Self.node("module.a", kind: .module)).category == .module)
        #expect(TerraformNodeStyle.of(Self.node("cloudflare_record.a")).category == .other)
    }

    @Test func minimapKeepsTheDiagramsShape() {
        let size = DiagramMinimap.size(for: CGSize(width: 3600, height: 900))
        let inner = CGSize(width: size.width - DiagramMinimap.padding * 2, height: size.height - DiagramMinimap.padding * 2)
        #expect(inner.width <= 180.001 && inner.height <= 110.001)
        #expect(abs(inner.width / inner.height - 4) < 0.01)
    }

    /// Regression: a diagram larger than the view (any real stack in the Architecture view) made the view as large and
    /// centred it, so the diagram, the zoom controls and the inspector were drawn out of sight and the tab looked blank
    /// and frozen. The stage keeps the size it is given and starts the diagram at its top-left corner.
    @Test @MainActor func aDiagramLargerThanTheViewKeepsTheViewsSize() throws {
        let diagram = Color(red: 1, green: 0, blue: 0).frame(width: 40, height: 40).frame(width: 3000, height: 2000, alignment: .topLeading)
        let stage = ImageRenderer(content: DiagramStage { diagram }.background(Color.white))
        stage.proposedSize = ProposedViewSize(width: 300, height: 200)
        let image = try #require(stage.cgImage)
        #expect(image.width == 300 && image.height == 200)
        // The diagram's top-left corner is the view's.
        let corner = try Self.pixel(image, x: 5, y: 5), outside = try Self.pixel(image, x: 100, y: 100)
        #expect(corner[0] > 200 && corner[1] < 60 && corner[2] < 60, "\(corner)")
        #expect(outside[0] > 200 && outside[1] > 200 && outside[2] > 200, "\(outside)")
        // The way it was laid out before: the view grows to the diagram's size.
        let before = ImageRenderer(content: ZStack(alignment: .topLeading) { diagram }.frame(maxWidth: .infinity, maxHeight: .infinity))
        before.proposedSize = ProposedViewSize(width: 300, height: 200)
        #expect(try #require(before.cgImage).width == 3000)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(data.prefix(3))
    }

    /// Double-clicks and scrolling are read from AppKit's events, at the point of the diagram under them.
    @Test @MainActor func eventsAreReadWhereTheyLandOnTheDiagram() {
        let window = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let anchor = DiagramAnchor.Flipped(frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        window.addSubview(anchor)
        let pointer = DiagramPointer()
        #expect(pointer.location(CGPoint(x: 15, y: 115)) == nil)
        pointer.view = anchor
        // Window points have their origin at the bottom; the diagram's at its top-left corner.
        #expect(pointer.location(CGPoint(x: 15, y: 115)) == CGPoint(x: 5, y: 5))
        #expect(pointer.location(CGPoint(x: 209, y: 21)) == CGPoint(x: 199, y: 99))
        #expect(pointer.location(CGPoint(x: 5, y: 5)) == nil && pointer.location(CGPoint(x: 300, y: 50)) == nil)
        #expect(anchor.hitTest(CGPoint(x: 15, y: 25)) == nil)
    }
}
