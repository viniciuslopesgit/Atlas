import Foundation
import Testing
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
