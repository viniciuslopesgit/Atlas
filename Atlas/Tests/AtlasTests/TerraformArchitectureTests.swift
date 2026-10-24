import Foundation
import Testing
@testable import Atlas

/// A stack like the ones Atlas is used with: an existing VPC given as an input, a network module that adds subnets
/// in three zones, a cluster module whose node groups get those subnets through module outputs and inputs.
struct TerraformArchitectureTests {
    static func stack(crlf: Bool = false) throws -> URL {
        let root = TestTemp.root.appendingPathComponent("arch-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["network", "cluster"] { try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws {
            let body = crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
            try body.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try write("variables.tf", """
        variable "aws_region" { default = "eu-west-1" }
        variable "vpc_id" { default = "vpc-0abc" }
        variable "private_cidrs" {
          default = {
            a = "10.0.16.0/21"
            b = "10.0.24.0/21"
          }
        }
        """)
        try write("main.tf", """
        module "network" {
          source        = "./network"
          vpc_id        = var.vpc_id
          aws_region    = var.aws_region
          private_cidrs = var.private_cidrs
        }
        module "cluster" {
          source     = "./cluster"
          vpc_id     = var.vpc_id
          subnet_ids = module.network.private_by_az
        }
        resource "random_id" "suffix" { byte_length = 4 }
        """)
        try write("network/main.tf", """
        variable "vpc_id" {}
        variable "aws_region" {}
        variable "private_cidrs" {}
        resource "aws_subnet" "private_a" {
          vpc_id            = var.vpc_id
          cidr_block        = var.private_cidrs["a"]
          availability_zone = "${var.aws_region}a"
        }
        resource "aws_subnet" "private_b" {
          vpc_id            = var.vpc_id
          cidr_block        = var.private_cidrs["b"]
          availability_zone = "${var.aws_region}b"
        }
        resource "aws_subnet" "public_a" {
          vpc_id                  = var.vpc_id
          availability_zone       = "${var.aws_region}a"
          map_public_ip_on_launch = true
        }
        output "private_by_az" {
          value = {
            a = aws_subnet.private_a.id
            b = aws_subnet.private_b.id
          }
        }
        """)
        try write("cluster/main.tf", """
        variable "vpc_id" {}
        variable "subnet_ids" {}
        locals {
          all_subnets = [var.subnet_ids["a"], var.subnet_ids["b"]]
        }
        resource "aws_security_group" "cluster" { vpc_id = var.vpc_id }
        resource "aws_iam_role" "nodes" { name = "nodes" }
        resource "aws_iam_role_policy_attachment" "nodes_cni" {
          role       = aws_iam_role.nodes.name
          policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        }
        resource "aws_eks_cluster" "this" {
          name = "platform"
          vpc_config { security_group_ids = [aws_security_group.cluster.id] }
        }
        resource "aws_eks_node_group" "pinned" {
          cluster_name  = aws_eks_cluster.this.name
          node_role_arn = aws_iam_role.nodes.arn
          subnet_ids    = [var.subnet_ids["b"]]
        }
        resource "aws_eks_node_group" "spread" {
          cluster_name  = aws_eks_cluster.this.name
          node_role_arn = aws_iam_role.nodes.arn
          subnet_ids    = local.all_subnets
        }
        resource "aws_s3_bucket" "logs" { bucket = "logs" }
        resource "helm_release" "ingress" { name = "ingress" }
        """)
        return root
    }

    static func find(_ box: TerraformArchitecture.Box, _ id: String) -> TerraformArchitecture.Box? {
        box.id == id ? box : box.children.lazy.compactMap { find($0, id) }.first
    }

    @Test func referencesAreFollowedThroughModulesToTheSubnets() throws {
        let root = try Self.stack()
        defer { try? FileManager.default.removeItem(at: root) }
        let stack = TerraformStack.load(root: root)
        let pinned = try #require(stack.graph.node("module.cluster.aws_eks_node_group.pinned"))
        #expect(pinned.dependencies.contains("module.network.aws_subnet.private_b"))
        #expect(!pinned.dependencies.contains("module.network.aws_subnet.private_a"))
        let spread = try #require(stack.graph.node("module.cluster.aws_eks_node_group.spread"))
        #expect(spread.dependencies.contains("module.network.aws_subnet.private_a") && spread.dependencies.contains("module.network.aws_subnet.private_b"))
        #expect(stack.graph.node("module.cluster.aws_security_group.cluster")?.dependencies == ["var.vpc_id"])
        #expect(stack.modules["module.cluster.aws_eks_cluster.this"] == "cluster")
        #expect(stack.graph.node("module.cluster.aws_eks_cluster.this")?.file == "cluster/main.tf")
        // Values are followed to the defaults that set them.
        #expect(stack.values["module.network.aws_subnet.private_a"]?["availability_zone"] == "eu-west-1a")
        #expect(stack.values["module.network.aws_subnet.private_b"]?["cidr_block"] == "10.0.24.0/21")
        #expect(stack.values["var.vpc_id"]?["default"] == "vpc-0abc")
        #expect(stack.region == "eu-west-1")
    }

    @Test func filesWithWindowsLineEndingsAreRead() throws {
        let root = try Self.stack(crlf: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stack = TerraformStack.load(root: root)
        #expect(stack.graph.node("module.cluster.aws_eks_node_group.pinned")?.dependencies.contains("module.network.aws_subnet.private_b") == true)
        #expect(stack.values["module.network.aws_subnet.private_a"]?["availability_zone"] == "eu-west-1a")
    }

    @Test func eachResourceSitsWhereItLivesInAWS() throws {
        let root = try Self.stack()
        defer { try? FileManager.default.removeItem(at: root) }
        let arch = TerraformArchitecture(TerraformStack.load(root: root))
        let region = try #require(Self.find(arch.root, "region"))
        #expect(region.subtitle == "eu-west-1")
        let vpc = try #require(Self.find(arch.root, "vpc:var.vpc_id"))
        #expect(vpc.subtitle == "existing · vpc-0abc")
        #expect(vpc.cards == ["module.cluster.aws_security_group.cluster"])
        // Zones in order, the public subnet before the private one.
        let zones = try #require(Self.find(arch.root, "zones:var.vpc_id"))
        #expect(zones.isRow && zones.children.map(\.subtitle) == ["eu-west-1a", "eu-west-1b"])
        #expect(zones.children[0].children.map(\.kind) == [.publicSubnet, .privateSubnet])
        #expect(zones.children[0].children[1].subtitle == "10.0.16.0/21 · private_a")
        #expect(Self.find(arch.root, "subnet:module.network.aws_subnet.private_b")?.cards == ["module.cluster.aws_eks_node_group.pinned"])
        #expect(Self.find(arch.root, "spread:var.vpc_id:privateSubnet")?.cards == ["module.cluster.aws_eks_node_group.spread"])
        let cluster = try #require(Self.find(arch.root, "cluster:module.cluster.aws_eks_cluster.this"))
        #expect(cluster.subtitle == "platform" && cluster.cards == ["module.cluster.helm_release.ingress"])
        #expect(Self.find(vpc, cluster.id) != nil)
        #expect(Self.find(arch.root, "global")?.cards == ["module.cluster.aws_iam_role.nodes"])
        #expect(Self.find(arch.root, "services")?.cards == ["module.cluster.aws_s3_bucket.logs"])
        #expect(Self.find(arch.root, "outside")?.cards == ["random_id.suffix"])
        // The policy attachment is folded into its role.
        #expect(arch.folded["module.cluster.aws_iam_role.nodes"] == ["module.cluster.aws_iam_role_policy_attachment.nodes_cni"])
        #expect(!arch.cards.contains("module.cluster.aws_iam_role_policy_attachment.nodes_cni"))
        // Every card is drawn once.
        #expect(Set(arch.cards).count == arch.cards.count)
    }

    @Test func boxesNestAndCardsStayInsideTheirBox() throws {
        let root = try Self.stack()
        defer { try? FileManager.default.removeItem(at: root) }
        let arch = TerraformArchitecture(TerraformStack.load(root: root))
        let geometry = DiagramGeometry(architecture: arch)
        #expect(geometry.isArchitecture)
        let rects = Dictionary(geometry.boxes.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        func check(_ box: TerraformArchitecture.Box, in parent: CGRect?) {
            let rect = rects[box.id] ?? parent
            if let rect, let parent { #expect(parent.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(box.id)") }
            for card in box.cards {
                let r = geometry.rect(card)!
                if let rect { #expect(rect.contains(r), "\(card) in \(box.id)") }
            }
            box.children.forEach { check($0, in: rect) }
        }
        check(arch.root, in: nil)
        let cards = arch.cards.map { geometry.rect($0)! }
        for i in cards.indices { for j in cards.indices where i < j { #expect(!cards[i].intersects(cards[j])) } }
        // Zones side by side and as tall as each other.
        let zones = geometry.boxes.filter { $0.kind == .zone }
        #expect(zones.count == 2 && zones[0].rect.maxX < zones[1].rect.minX && zones[0].rect.height == zones[1].rect.height)
        // A box's title selects the block it stands for; a folded block is found on its card.
        let subnet = try #require(geometry.boxes.first { $0.node == "module.network.aws_subnet.private_a" })
        #expect(geometry.node(at: CGPoint(x: subnet.rect.minX + 30, y: subnet.rect.minY + 10)) == subnet.node)
        #expect(geometry.rect("module.cluster.aws_iam_role_policy_attachment.nodes_cni") == geometry.rect("module.cluster.aws_iam_role.nodes"))
    }

    @Test func dataSourcesCanBeLeftOut() throws {
        let root = try Self.stack()
        defer { try? FileManager.default.removeItem(at: root) }
        try "data \"aws_caller_identity\" \"me\" {}".write(to: root.appendingPathComponent("data.tf"), atomically: true, encoding: .utf8)
        let stack = TerraformStack.load(root: root)
        #expect(TerraformArchitecture(stack).cards.contains("data.aws_caller_identity.me"))
        #expect(!TerraformArchitecture(stack, showData: false).cards.contains("data.aws_caller_identity.me"))
    }

    @Test func modulesThatCallThemselvesAndLocalsThatLoopEnd() throws {
        let root = TestTemp.root.appendingPathComponent("arch-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        module "again" { source = "./" }
        locals {
          a = local.b
          b = local.a
        }
        resource "aws_s3_bucket" "x" { bucket = local.a }
        """.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let stack = TerraformStack.load(root: root)
        #expect(stack.graph.node("aws_s3_bucket.x") != nil)
        #expect(stack.graph.nodes.count <= TerraformStack.maxModuleDepth + 1)
    }

    @Test func arrowKeysMoveToTheNearestCardOnThatSide() {
        let centers: [String: CGPoint] = ["a": .init(x: 0, y: 0), "b": .init(x: 300, y: 10), "c": .init(x: 0, y: 200), "d": .init(x: 600, y: 0)]
        #expect(DiagramNavigation.nearest(from: "a", .right, centers: centers) == "b")
        #expect(DiagramNavigation.nearest(from: "b", .left, centers: centers) == "a")
        #expect(DiagramNavigation.nearest(from: "a", .down, centers: centers) == "c")
        #expect(DiagramNavigation.nearest(from: "a", .up, centers: centers) == nil)
        #expect(DiagramNavigation.nearest(from: nil, .right, centers: centers) == "a")
    }

    @Test func attributesAndMapEntries() {
        let block = """
        module "m" {
          source = "./m" # where it is
          ids    = {
            a = aws_subnet.a.id
            "b" = aws_subnet.b.id
          }
        }
        """
        let a = TerraformConfig.attributes(block)
        #expect(a["source"] == "\"./m\"")
        #expect(TerraformConfig.entry("a", in: a["ids"]!) == "aws_subnet.a.id")
        #expect(TerraformConfig.entry("b", in: a["ids"]!) == "aws_subnet.b.id")
        #expect(TerraformConfig.entry("c", in: a["ids"]!) == nil)
    }
}
