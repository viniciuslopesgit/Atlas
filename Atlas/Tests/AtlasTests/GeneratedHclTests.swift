import Foundation
import Testing
@testable import Atlas

struct GeneratedHclTests {
    @Test func tagsAllAndNamePrefixAreRemoved() {
        let input = """
        resource "aws_iam_role" "app" {
          name        = "app"
          name_prefix = null
          tags_all = {
            Env = "prod"
          }
          tags_all = {}
        }
        """
        let (out, s) = GeneratedHclFixer.fix(input)
        #expect(!out.contains("tags_all") && !out.contains("name_prefix"))
        #expect(s.tagsAll == 2 && s.iam == 1 && s.total == 3)
        #expect(out.contains(#"name        = "app""#))
    }

    @Test func zipLambdaGetsPlaceholderAndLifecycle() {
        let input = """
        resource "aws_lambda_function" "fn" {
          function_name = "fn"
          publish       = false
          s3_bucket     = null
          filename      = null
        }
        """
        let (out, s) = GeneratedHclFixer.fix(input)
        #expect(out.contains(#"  filename = "lambda_placeholder.zip""#))
        #expect(out.contains("ignore_changes = [filename, source_code_hash, last_modified, publish]"))
        #expect(!out.contains("publish       = false") && !out.contains("s3_bucket"))
        #expect(s.lambda == 1)
    }

    @Test func imageLambdaIsLeftAlone() {
        let input = """
        resource "aws_lambda_function" "img" {
          image_uri = "123.dkr.ecr.us-east-1.amazonaws.com/x:latest"
        }
        """
        #expect(GeneratedHclFixer.fix(input).0 == input)
    }

    @Test func subnetVpcAcmDynamoAndApiGatewayRules() {
        let input = """
        resource "aws_subnet" "a" {
          availability_zone    = "us-east-1a"
          availability_zone_id = "use1-az1"
        }
        resource "aws_vpc" "v" {
          ipv6_netmask_length = 0
          ipv6_ipam_pool_id   = null
        }
        resource "aws_acm_certificate" "c" {
          validation_method = "NONE"
        }
        resource "aws_dynamodb_table" "t" {
          point_in_time_recovery {
            enabled                 = false
            recovery_period_in_days = 0
          }
        }
        resource "aws_api_gateway_rest_api" "r" {
          endpoint_configuration {
            types            = ["REGIONAL"]
            vpc_endpoint_ids = []
          }
        }
        """
        let (out, s) = GeneratedHclFixer.fix(input)
        #expect(out.contains("availability_zone    =") && !out.contains("availability_zone_id"))
        #expect(!out.contains("ipv6_"))
        #expect(!out.contains("validation_method"))
        #expect(!out.contains("point_in_time_recovery") && !out.contains("endpoint_configuration"))
        #expect(s == .init(subnet: 1, vpc: 1, dynamoDb: 1, acm: 1, apiGateway: 1))
    }

    @Test func routeListBecomesBlocksWithDestinationsOnly() {
        let input = """
        resource "aws_route_table" "rt" {
          vpc_id = "vpc-1"
          route = [{
            cidr_block = "0.0.0.0/0"
            gateway_id = "igw-1"
            nat_gateway_id = ""
          }, {
            cidr_block = ""
            gateway_id = "local"
          }]
        }
        """
        let (out, s) = GeneratedHclFixer.fix(input)
        #expect(out.contains("  route {\n    cidr_block = \"0.0.0.0/0\"\n    gateway_id = \"igw-1\"\n  }"))
        #expect(!out.contains("nat_gateway_id") && !out.contains("\"local\"") && !out.contains("route = ["))
        #expect(s.routeTable == 1)
    }

    @Test func splitterGroupsByServiceWithComments() throws {
        let dir = TestTemp.root.appendingPathComponent("split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gen = dir.appendingPathComponent("generated_resources.tf")
        try """
        # __generated__ by Terraform
        resource "aws_instance" "web" {
          tags = { Name = "web" }
        }

        # __generated__ by Terraform from "my-bucket"
        resource "aws_s3_bucket" "b" {
          bucket = "my-bucket"
        }

        resource "aws_lambda_function" "fn" {}
        resource "aws_api_gateway_rest_api" "api" {
        }
        """.write(to: gen, atomically: true, encoding: .utf8)
        try "# existing\n".write(to: dir.appendingPathComponent("s3.tf"), atomically: true, encoding: .utf8)

        let written = try GeneratedHclSplitter.split(file: gen)
        #expect(written.map(\.file) == ["apigateway.tf", "ec2.tf", "lambda.tf", "s3.tf"])
        let s3 = try String(contentsOf: dir.appendingPathComponent("s3.tf"), encoding: .utf8)
        #expect(s3.hasPrefix("# existing\n\n# __generated__ by Terraform from \"my-bucket\"\nresource \"aws_s3_bucket\""))
        #expect(!FileManager.default.fileExists(atPath: gen.path))
        #expect(GeneratedHclSplitter.fileName(for: "aws_security_group_rule") == "security_groups.tf")
        #expect(GeneratedHclSplitter.fileName(for: "aws_rds_cluster") == "rds.tf")
    }

    @Test func envVarsBecomeSensitiveVariables() throws {
        let dir = TestTemp.root.appendingPathComponent("env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        resource "aws_lambda_function" "a" {
          environment {
            variables = {
              OPENAI_API_KEY = "sk-1"
              STAGE = "prod"
            }
          }
        }
        resource "aws_lambda_function" "b" {
          environment {
            variables = {
              OPENAI_API_KEY = "sk-1"
              STAGE = "dev"
              ALREADY = "var.x"
            }
          }
        }
        """.write(to: dir.appendingPathComponent("lambda.tf"), atomically: true, encoding: .utf8)

        let vars = try EnvVarExtractor.extractAndReplace(in: dir)
        #expect(Set(vars.map(\.tfVarName)) == ["openai_api_key", "a_stage", "b_stage"])
        let tf = try String(contentsOf: dir.appendingPathComponent("lambda.tf"), encoding: .utf8)
        #expect(tf.contains("OPENAI_API_KEY = var.openai_api_key") && tf.contains("STAGE = var.b_stage"))
        #expect(!tf.contains("sk-1") && tf.contains(#"ALREADY = "var.x""#))
        let decl = try String(contentsOf: dir.appendingPathComponent(EnvVarExtractor.variablesFile), encoding: .utf8)
        #expect(decl.contains(#"variable "openai_api_key" {"#) && decl.contains("sensitive   = true"))
        #expect(!decl.contains("sk-1"))
    }

    @Test func envVarValuesAreNotEncoded() throws {
        let v = StackEnvVar(tfVarName: "k", envKey: "K", value: "secret", resourceType: "t", resourceName: "n", sourceFile: "f")
        let json = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        #expect(!json.contains("secret"))
    }
}
