import Foundation

struct Ec2Service {
    let client: AWSClient

    private static func d(_ v: String) -> String { v.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : v }

    private static func tags(_ node: XNode) -> [String: String] {
        var map: [String: String] = [:]
        for t in node.list("tagSet") { map[t.str("key")] = t.str("value") }
        return map
    }

    func instances() async throws -> [Ec2Instance] {
        let region = client.region
        var result: [Ec2Instance] = []

        try await client.queryPaged(.ec2, "DescribeInstances", tokenParam: "NextToken",
                                    tokenPath: { $0.str("nextToken") }) { xml in
            for reservation in xml.list("reservationSet") {
                let ownerId = reservation.str("ownerId")
                for i in reservation.list("instancesSet") {
                    result.append(Self.parseInstance(i, ownerId: ownerId,
                                                     reservationId: reservation.str("reservationId"),
                                                     region: region))
                }
            }
        }
        return result
    }

    private static func parseInstance(_ i: XNode, ownerId: String, reservationId: String, region: String) -> Ec2Instance {
        let tags = tags(i)
        let iamArn = i.str("iamInstanceProfile/arn")
        let iamName = iamArn.split(separator: "/").last.map(String.init) ?? ""
        let ipv6 = i.list("networkInterfaceSet")
            .flatMap { $0.list("ipv6AddressesSet") }
            .map { $0.str("ipv6Address") }
            .first ?? ""
        let cores = i.int("cpuOptions/coreCount") ?? 0
        let threads = i.int("cpuOptions/threadsPerCore") ?? 1
        let lifecycle = i.str("instanceLifecycle")
        let partition = i.int("placement/partitionNumber") ?? 0

        var m = Ec2Instance()
        m.instanceId = i.str("instanceId")
        m.name = tags["Name"] ?? "(no name)"
        m.instanceType = i.str("instanceType")
        m.state = i.str("instanceState/name")
        m.publicIpAddress = d(i.str("ipAddress"))
        m.privateIpAddress = d(i.str("privateIpAddress"))
        m.region = region
        m.launchTime = i.date("launchTime")
        m.tags = tags

        m.ipv6Address = d(ipv6)
        m.publicDnsName = d(i.str("dnsName"))
        m.privateDnsName = d(i.str("privateDnsName"))
        m.vpcId = d(i.str("vpcId"))
        m.subnetId = d(i.str("subnetId"))
        m.iamInstanceProfileName = d(iamName)
        m.iamInstanceProfileArn = iamArn
        m.metadataHttpTokens = d(i.str("metadataOptions/httpTokens"))
        m.instanceArn = "arn:aws:ec2:\(region):\(ownerId):instance/\(m.instanceId)"
        m.autoScalingGroupName = d(tags["aws:autoscaling:groupName"] ?? "")
        m.ownerId = d(ownerId)
        m.reservationId = d(reservationId)

        m.imageId = d(i.str("imageId"))
        m.monitoringState = d(i.str("monitoring/state"))
        let platform = i.str("platformDetails")
        m.platformDetails = d(platform.isEmpty ? i.str("platform") : platform)
        m.keyName = d(i.str("keyName"))
        m.virtualizationType = d(i.str("virtualizationType"))
        m.lifecycle = lifecycle.isEmpty ? "normal" : lifecycle
        m.usageOperation = d(i.str("usageOperation"))
        m.bootMode = d(i.str("bootMode"))
        m.currentInstanceBootMode = d(i.str("currentInstanceBootMode"))
        m.amiLaunchIndex = i.int("amiLaunchIndex") ?? 0
        m.stateTransitionReason = d(i.str("reason"))
        m.stateReasonMessage = d(i.str("stateReason/message"))
        m.hibernationEnabled = i.bool("hibernationOptions/configured")

        m.availabilityZone = d(i.str("placement/availabilityZone"))
        m.placementGroup = d(i.str("placement/groupName"))
        m.placementGroupId = d(i.str("placement/groupId"))
        m.tenancy = d(i.str("placement/tenancy"))
        m.hostId = d(i.str("placement/hostId"))
        m.affinity = d(i.str("placement/affinity"))
        m.partitionNumber = partition == 0 ? nil : partition
        m.vCpuCount = cores * threads

        m.capacityReservationId = d(i.str("capacityReservationId"))
        m.capacityReservationPreference = d(i.str("capacityReservationSpecification/capacityReservationPreference"))
        return m
    }

    // MARK: State changes

    private func instanceParams(_ ids: [String]) -> [String: String] {
        var p: [String: String] = [:]
        for (n, id) in ids.enumerated() { p["InstanceId.\(n + 1)"] = id }
        return p
    }

    func start(_ ids: [String]) async throws { _ = try await client.query(.ec2, "StartInstances", instanceParams(ids)) }
    func stop(_ ids: [String]) async throws { _ = try await client.query(.ec2, "StopInstances", instanceParams(ids)) }
    func reboot(_ ids: [String]) async throws { _ = try await client.query(.ec2, "RebootInstances", instanceParams(ids)) }
    func terminate(_ ids: [String]) async throws { _ = try await client.query(.ec2, "TerminateInstances", instanceParams(ids)) }

    // MARK: Discovery for the launch wizard

    private func vpcFilter(_ vpcId: String?) -> [String: String] {
        guard let vpcId, !vpcId.isEmpty else { return [:] }
        return ["Filter.1.Name": "vpc-id", "Filter.1.Value.1": vpcId]
    }

    func vpcs() async throws -> [VpcInfo] {
        let xml = try await client.query(.ec2, "DescribeVpcs")
        return xml.list("vpcSet").map { v in
            VpcInfo(vpcId: v.str("vpcId"), cidrBlock: v.str("cidrBlock"), isDefault: v.bool("isDefault"),
                    name: Self.tags(v)["Name"] ?? "")
        }
        .sorted { ($0.isDefault ? 0 : 1, $0.vpcId) < ($1.isDefault ? 0 : 1, $1.vpcId) }
    }

    func subnets(vpcId: String?) async throws -> [SubnetInfo] {
        let xml = try await client.query(.ec2, "DescribeSubnets", vpcFilter(vpcId))
        return xml.list("subnetSet").map { s in
            SubnetInfo(subnetId: s.str("subnetId"), vpcId: s.str("vpcId"),
                       availabilityZone: s.str("availabilityZone"), cidrBlock: s.str("cidrBlock"),
                       isDefault: s.bool("defaultForAz"), name: Self.tags(s)["Name"] ?? "")
        }
        .sorted { $0.availabilityZone < $1.availabilityZone }
    }

    func keyPairs() async throws -> [KeyPairSummary] {
        let xml = try await client.query(.ec2, "DescribeKeyPairs")
        return xml.list("keySet").map { k in
            let type = k.str("keyType")
            return KeyPairSummary(keyPairId: k.str("keyPairId"), keyName: k.str("keyName"),
                                  keyType: type.isEmpty ? "rsa" : type)
        }
        .sorted { $0.keyName < $1.keyName }
    }

    func securityGroups(vpcId: String?) async throws -> [SecurityGroupSummary] {
        let xml = try await client.query(.ec2, "DescribeSecurityGroups", vpcFilter(vpcId))
        return xml.list("securityGroupInfo").map { sg in
            SecurityGroupSummary(groupId: sg.str("groupId"), groupName: sg.str("groupName"), vpcId: sg.str("vpcId"))
        }
        .sorted { $0.groupName < $1.groupName }
    }

    /// Returns the private key material (PEM) of the new key pair.
    func createKeyPair(name: String, type: String) async throws -> String {
        let xml = try await client.query(.ec2, "CreateKeyPair", ["KeyName": name, "KeyType": type.lowercased()])
        return xml.str("keyMaterial")
    }

    /// Launches instances and returns their IDs.
    func launch(_ o: LaunchInstanceOptions) async throws -> [String] {
        var sgIds: [String] = []
        if o.createNewSecurityGroup {
            let stamp = Int(Date().timeIntervalSince1970)
            let sgName = o.newSecurityGroupName.isEmpty ? "launch-wizard-\(stamp)" : o.newSecurityGroupName
            var p = ["GroupName": sgName, "GroupDescription": "Created by Atlas launch wizard"]
            if !o.vpcId.isEmpty { p["VpcId"] = o.vpcId }
            let sgId = try await client.query(.ec2, "CreateSecurityGroup", p).str("groupId")
            sgIds.append(sgId)

            var rules: [(Int, String)] = []
            if o.allowSsh { rules.append((22, "SSH")) }
            if o.allowHttps { rules.append((443, "HTTPS")) }
            if o.allowHttp { rules.append((80, "HTTP")) }
            if !rules.isEmpty {
                var ip: [String: String] = ["GroupId": sgId]
                for (n, rule) in rules.enumerated() {
                    let k = "IpPermissions.\(n + 1)"
                    ip["\(k).IpProtocol"] = "tcp"
                    ip["\(k).FromPort"] = "\(rule.0)"
                    ip["\(k).ToPort"] = "\(rule.0)"
                    ip["\(k).IpRanges.1.CidrIp"] = "0.0.0.0/0"
                    ip["\(k).IpRanges.1.Description"] = rule.1
                }
                _ = try await client.query(.ec2, "AuthorizeSecurityGroupIngress", ip)
            }
        } else if !o.existingSecurityGroupId.trimmingCharacters(in: .whitespaces).isEmpty {
            sgIds.append(o.existingSecurityGroupId.trimmingCharacters(in: .whitespaces))
        }

        var p: [String: String] = [
            "ImageId": o.amiId.trimmingCharacters(in: .whitespaces),
            "InstanceType": o.instanceType,
            "MinCount": "\(o.count)",
            "MaxCount": "\(o.count)",
            "NetworkInterface.1.DeviceIndex": "0",
            "NetworkInterface.1.AssociatePublicIpAddress": o.autoAssignPublicIp ? "true" : "false",
            "BlockDeviceMapping.1.DeviceName": "/dev/xvda",
            "BlockDeviceMapping.1.Ebs.VolumeSize": "\(o.rootVolumeSize)",
            "BlockDeviceMapping.1.Ebs.VolumeType": o.rootVolumeType,
            "BlockDeviceMapping.1.Ebs.DeleteOnTermination": "true",
            "InstanceInitiatedShutdownBehavior": o.shutdownBehavior,
            "Monitoring.Enabled": o.detailedMonitoring ? "true" : "false",
            "MetadataOptions.HttpTokens": o.imdsv2Required ? "required" : "optional",
            "MetadataOptions.HttpEndpoint": "enabled",
        ]
        if !o.subnetId.isEmpty { p["NetworkInterface.1.SubnetId"] = o.subnetId }
        for (n, sg) in sgIds.enumerated() { p["NetworkInterface.1.SecurityGroupId.\(n + 1)"] = sg }
        if !o.keyPairName.isEmpty { p["KeyName"] = o.keyPairName }
        if !o.userData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p["UserData"] = Data(o.userData.utf8).base64EncodedString()
        }
        let profile = o.iamInstanceProfile.trimmingCharacters(in: .whitespaces)
        if !profile.isEmpty {
            p[profile.lowercased().hasPrefix("arn:") ? "IamInstanceProfile.Arn" : "IamInstanceProfile.Name"] = profile
        }
        if !o.name.isEmpty {
            p["TagSpecification.1.ResourceType"] = "instance"
            p["TagSpecification.1.Tag.1.Key"] = "Name"
            p["TagSpecification.1.Tag.1.Value"] = o.name
        }

        let xml = try await client.query(.ec2, "RunInstances", p)
        let ids = xml.list("instancesSet").map { $0.str("instanceId") }

        if o.terminationProtection {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        _ = try await client.query(.ec2, "ModifyInstanceAttribute",
                                                   ["InstanceId": id, "DisableApiTermination.Value": "true"])
                    }
                }
                try await group.waitForAll()
            }
        }
        return ids
    }

    // MARK: Metrics

    func metrics(instanceId: String) async throws -> Ec2InstanceMetrics {
        let cw = CloudWatchService(client: client)
        let end = Date()
        let start = end.addingTimeInterval(-3600)
        async let cpu = cw.ec2Metric(instanceId, "CPUUtilization", "Average", start, end)
        async let netIn = cw.ec2Metric(instanceId, "NetworkIn", "Sum", start, end)
        async let netOut = cw.ec2Metric(instanceId, "NetworkOut", "Sum", start, end)
        async let disk = cw.ec2Metric(instanceId, "DiskWriteBytes", "Sum", start, end)
        return try await Ec2InstanceMetrics(cpu: cpu, networkIn: netIn, networkOut: netOut, diskWrite: disk)
    }
}
