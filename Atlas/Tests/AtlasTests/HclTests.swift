import Foundation
import Testing
@testable import Atlas

struct HclTests {
    private let existing = """
    # my notes
    provider "aws" {}

    # ATLAS-MANAGED-START resource "aws_s3_bucket" "a"
    resource "aws_s3_bucket" "a" { bucket = "old" }
    # ATLAS-MANAGED-END resource "aws_s3_bucket" "a"

    locals { mine = true }

    # ATLAS-MANAGED-START resource "aws_s3_bucket" "keep"
    resource "aws_s3_bucket" "keep" {}
    # ATLAS-MANAGED-END resource "aws_s3_bucket" "keep"
    """

    @Test func mergeReplacesPreservesAndAppends() {
        let new = """
        # ATLAS-MANAGED-START resource "aws_s3_bucket" "a"
        resource "aws_s3_bucket" "a" { bucket = "new" }
        # ATLAS-MANAGED-END resource "aws_s3_bucket" "a"

        # ATLAS-MANAGED-START resource "aws_s3_bucket" "b"
        resource "aws_s3_bucket" "b" {}
        # ATLAS-MANAGED-END resource "aws_s3_bucket" "b"
        """
        let merged = HclMerge.merge(existing: existing, new: new)
        #expect(merged.contains(#"bucket = "new""#) && !merged.contains(#"bucket = "old""#))
        #expect(merged.hasPrefix("# my notes\nprovider \"aws\" {}"))
        #expect(merged.contains("locals { mine = true }"))
        #expect(merged.contains(#"resource "aws_s3_bucket" "keep" {}"#))
        #expect(HclMerge.keys(merged) == [#"resource "aws_s3_bucket" "a""#, #"resource "aws_s3_bucket" "keep""#,
                                          #"resource "aws_s3_bucket" "b""#])
    }

    @Test func endMarkerMustMatchTheKey() {
        let broken = """
        # ATLAS-MANAGED-START x
        body
        # ATLAS-MANAGED-END y
        """
        #expect(!HclMerge.hasManagedBlocks(broken))
    }

    @Test func identifiersAreValidTerraformNames() {
        #expect(HclGenerator.identifier("My Web-Server.prod") == "my_web_server_prod")
        #expect(HclGenerator.identifier("123abc") == "abc")
        #expect(HclGenerator.identifier("!!!") == "resource")
    }

    @Test func quoteEscapesInterpolation() {
        #expect(HclGenerator.quote(#"a "b" ${c}"#) == #""a \"b\" $${c}""#)
    }

    @Test func ec2TemplateRendersOptionalFields() {
        var m = Ec2InstanceHcl(resourceName: "web", amiId: "ami-1", instanceType: "t3.small")
        m.securityGroupIds = ["sg-1", "sg-2"]
        m.keyName = "deploy"
        m.tags = [HclTag(key: "Env", value: "prod")]
        let hcl = HclGenerator.ec2Instance(m)
        #expect(hcl.contains(#"resource "aws_instance" "web" {"#))
        #expect(hcl.contains("vpc_security_group_ids = [\n    \"sg-1\",\n    \"sg-2\",\n  ]"))
        #expect(hcl.contains(#"key_name = "deploy""#))
        #expect(!hcl.contains("subnet_id"))
        #expect(hcl.contains(#""Env" = "prod""#))
        #expect(HclMerge.keys(hcl) == [#"resource "aws_instance" "web""#])
    }

    @Test func s3TemplateEmitsOnlyEnabledBlocks() {
        let hcl = HclGenerator.s3Bucket(S3BucketHcl(resourceName: "logs", bucketName: "my-logs", versioning: true))
        let keys = HclMerge.keys(hcl)
        #expect(keys.contains(#"resource "aws_s3_bucket_versioning" "logs""#))
        #expect(keys.contains(#"resource "aws_s3_bucket_server_side_encryption_configuration" "logs""#))
        #expect(!keys.contains(#"resource "aws_s3_bucket_logging" "logs""#))
        #expect(hcl.contains("block_public_acls       = true"))
    }

    @Test func iamRoleAttachmentsUseSafeNames() {
        let hcl = HclGenerator.iamRole(.lambdaExecution("fn"))
        #expect(hcl.contains(#"resource "aws_iam_role_policy_attachment" "fn_arn_aws_iam__aws_policy_service-role_AWSLambdaBasicExecutionRole""#))
        #expect(hcl.contains(#"Principal = { Service = "lambda.amazonaws.com" }"#))
    }

    @Test func securityGroupRendersRules() {
        let hcl = HclGenerator.securityGroup(.webServer("web"))
        #expect(hcl.components(separatedBy: "  ingress {").count == 3)
        #expect(hcl.contains("protocol    = \"-1\""))
    }

    @Test func modulesHaveThreeFiles() {
        let ec2 = HclGenerator.ec2Module(Ec2InstanceHcl(instanceType: "t3.large", rootVolumeGb: 40))
        #expect(Set(ec2.keys) == ["main.tf", "variables.tf", "outputs.tf"])
        #expect(ec2["variables.tf"]!.contains("default     = 40"))
        #expect(HclGenerator.s3Module(S3BucketHcl(versioning: true))["variables.tf"]!.contains("default     = true"))
    }

    @Test func writeMergesIntoTheProjectFile() throws {
        let dir = TestTemp.root.appendingPathComponent("hcl-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("s3_buckets.tf")
        try HclGenerator.write(HclGenerator.s3Bucket(S3BucketHcl(resourceName: "a", bucketName: "a")), to: file)
        var text = try String(contentsOf: file, encoding: .utf8)
        text += "\n# user edit\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        try HclGenerator.write(HclGenerator.s3Bucket(S3BucketHcl(resourceName: "b", bucketName: "b")), to: file)
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("# user edit"))
        #expect(text.contains(#"bucket        = "a""#) && text.contains(#"bucket        = "b""#))

        let again = try HclGenerator.write(HclGenerator.s3Bucket(S3BucketHcl(resourceName: "b", bucketName: "b")),
                                           to: file, overwriteManaged: false)
        #expect(!again.wasWritten)
    }
}
