import Foundation
import Testing
@testable import Atlas

struct SigV4Tests {
    /// AWS Signature V4 test suite: "get-vanilla".
    @Test func testGetVanilla() {
        let signer = SigV4Signer(credentials: AWSCredentials(
            accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"))
        let date = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z
        let req = signer.request(method: "GET", host: "example.amazonaws.com", encodedPath: "/",
                                 service: "service", region: "us-east-1", date: date,
                                 includeContentHashHeader: false)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                       + "SignedHeaders=host;x-amz-date, "
                       + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        #expect(req.value(forHTTPHeaderField: "x-amz-date") == "20150830T123600Z")
    }

    @Test func testQueryIsSortedAndEncoded() {
        let signer = SigV4Signer(credentials: AWSCredentials(accessKeyId: "a", secretAccessKey: "b"))
        let req = signer.request(method: "GET", host: "h.example.com", encodedPath: "/",
                                 query: [("prefix", "a b/c"), ("list-type", "2")], service: "s3", region: "us-east-1")
        #expect(req.url?.query == "list-type=2&prefix=a%20b%2Fc")
    }

    @Test func testUriKeepsSlash() {
        #expect(AWSEncoding.uri("folder/my file+1.txt", keepSlash: true) == "folder/my%20file%2B1.txt")
    }
}

struct ParsingTests {
    @Test func testEc2Xml() {
        let xml = """
        <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
          <reservationSet><item><reservationId>r-1</reservationId><ownerId>123</ownerId>
            <instancesSet><item><instanceId>i-abc</instanceId><instanceState><name>running</name></instanceState>
              <tagSet><item><key>Name</key><value>web</value></item></tagSet></item></instancesSet>
          </item></reservationSet>
        </DescribeInstancesResponse>
        """
        let root = XNode.parse(Data(xml.utf8))!
        let res = root.list("reservationSet")
        #expect(res.count == 1)
        #expect(res[0].str("ownerId") == "123")
        let inst = res[0].list("instancesSet")[0]
        #expect(inst.str("instanceState/name") == "running")
        #expect(inst.list("tagSet")[0].str("value") == "web")
    }

    @Test func testErrorParsing() {
        let xml = "<ErrorResponse><Error><Code>AccessDenied</Code><Message>Nope</Message></Error></ErrorResponse>"
        let e = AWSClient.error(from: Data(xml.utf8), status: 403)
        #expect(e.code == "AccessDenied")
        #expect(e.message == "Nope")
        let json = #"{"__type":"com.amazon#AccessDeniedException","message":"denied"}"#
        #expect(AWSClient.error(from: Data(json.utf8), status: 400).code == "AccessDeniedException")
    }

    @Test func testTrustedEntities() {
        let doc = "%7B%22Statement%22%3A%5B%7B%22Principal%22%3A%7B%22Service%22%3A%22ec2.amazonaws.com%22%7D%7D%5D%7D"
        #expect(IamService.trustedEntities(doc) == "ec2.amazonaws.com")
    }

    @Test func testDates() {
        #expect(nil != AWSDate.parse("2024-05-01T10:20:30.000Z"))
        #expect(nil != AWSDate.parse("2024-05-01T10:20:30Z"))
        #expect(nil != AWSDate.parse("2024-05-01T10:20:30+00:00"))
    }
}

struct RegionLabelTests {
    /// The New Stack sheet and the toolbar name the region the same way; an unknown code still shows.
    @Test func aRegionShowsItsCodeAndName() {
        #expect(RegionItem.label("eu-west-1") == "eu-west-1 — Europe (Ireland)")
        #expect(RegionItem.label("me-central-1") == "me-central-1")
    }
}
