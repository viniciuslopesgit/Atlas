using System.Text;
using Amazon.IdentityManagement;
using Amazon.IdentityManagement.Model;
using Amazon.S3;
using Amazon.S3.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class SecurityAuditService : ISecurityAuditService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;
    private readonly IIamService        _iam;
    private readonly IEc2Service        _ec2;

    public SecurityAuditService(
        IAwsSessionFactory session,
        AwsClientFactory   clients,
        IIamService        iam,
        IEc2Service        ec2)
    {
        _session = session;
        _clients = clients;
        _iam     = iam;
        _ec2     = ec2;
    }

    public async Task<SecurityAuditResult> RunAuditAsync(CancellationToken ct = default)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var iamClient = _clients.GetIam(_session.GetCredentials());

            var reportTask  = TryGetCredentialReportAsync(iamClient, ct);
            var policyTask  = CheckPasswordPolicyAsync(iamClient, ct);
            var summaryTask = CheckAccountSummaryAsync(iamClient, ct);
            var usersTask   = CheckInactiveUsersAsync(ct);
            var imdsTask    = CheckImdsV1Async(ct);
            var s3Task      = CheckS3PublicAccessAsync(ct);

            await Task.WhenAll(reportTask, policyTask, summaryTask, usersTask, imdsTask, s3Task);

            // Root access keys + root MFA + inactive users + key rotation from credential report
            var csv = await reportTask;
            if (csv != null)
            {
                findings.Add(CheckRootKeysFromReport(csv));
                findings.Add(CheckInactiveUsersFromReport(csv));
                findings.Add(CheckAccessKeyRotationFromReport(csv));
            }
            else
            {
                findings.Add(new SecurityFinding
                {
                    Title       = "Root access keys",
                    Description = "Could not retrieve credential report. Verify IAM permissions.",
                    Severity    = FindingSeverity.Warning
                });
                findings.AddRange(await usersTask);
            }

            findings.AddRange(await policyTask);
            findings.AddRange(await summaryTask);
            findings.AddRange(await imdsTask);
            findings.AddRange(await s3Task);
        }
        catch (OperationCanceledException) { return new SecurityAuditResult { ErrorMessage = "Cancelled" }; }
        catch (Exception ex)
        {
            FileLogger.Error("SecurityAuditService.RunAuditAsync", ex);
            return new SecurityAuditResult { ErrorMessage = ex.Message };
        }

        return new SecurityAuditResult { Findings = findings, AuditedAt = DateTime.UtcNow };
    }

    // ── Credential report ─────────────────────────────────────────────────

    private static async Task<string?> TryGetCredentialReportAsync(
        AmazonIdentityManagementServiceClient iam, CancellationToken ct)
    {
        try
        {
            await iam.GenerateCredentialReportAsync(new GenerateCredentialReportRequest(), ct);

            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
            {
                try
                {
                    var resp = await iam.GetCredentialReportAsync(new GetCredentialReportRequest(), ct);
                    return Encoding.UTF8.GetString(resp.Content.ToArray());
                }
                catch (AmazonIdentityManagementServiceException ex)
                    when (ex.ErrorCode is "ReportInProgress" or "ReportNotPresent")
                {
                    await Task.Delay(1500, ct);
                }
            }
            return null;
        }
        catch { return null; }
    }

    private static SecurityFinding CheckRootKeysFromReport(string csv)
    {
        foreach (var line in csv.Split('\n').Skip(1))
        {
            var cols = line.Trim().Split(',');
            if (cols.Length < 14) continue;
            if (!cols[0].Contains("<root_account>")) continue;

            var key1 = cols[8].Trim() == "true";
            var key2 = cols[13].Trim() == "true";

            return key1 || key2
                ? new SecurityFinding
                {
                    Title         = "Root access keys active",
                    Description   = "Active root account access keys found. These grant unrestricted access — disable them immediately.",
                    Severity      = FindingSeverity.Critical,
                    AffectedCount = (key1 ? 1 : 0) + (key2 ? 1 : 0)
                }
                : new SecurityFinding
                {
                    Title       = "Root access keys",
                    Description = "No active root account access keys detected.",
                    Severity    = FindingSeverity.Ok
                };
        }

        return new SecurityFinding
        {
            Title       = "Root access keys",
            Description = "Root account row not found in credential report.",
            Severity    = FindingSeverity.Warning
        };
    }

    private static SecurityFinding CheckInactiveUsersFromReport(string csv)
    {
        var cutoff   = DateTime.UtcNow.AddDays(-90);
        var inactive = 0;

        foreach (var line in csv.Split('\n').Skip(1))
        {
            var cols = line.Trim().Split(',');
            if (cols.Length < 5) continue;
            var user = cols[0].Trim();
            if (user.Contains("<root_account>") || string.IsNullOrEmpty(user)) continue;

            var passwordEnabled = cols[3].Trim() == "true";
            if (!passwordEnabled) continue;

            var lastUsed = cols[4].Trim();
            if (lastUsed is "no_information" or "N/A" or "not_supported")
                inactive++;
            else if (DateTime.TryParse(lastUsed, out var d) && d < cutoff)
                inactive++;
        }

        return inactive > 0
            ? new SecurityFinding
            {
                Title         = "Inactive IAM users",
                Description   = $"{inactive} user(s) with console access haven't logged in for 90+ days.",
                Severity      = FindingSeverity.Warning,
                AffectedCount = inactive
            }
            : new SecurityFinding
            {
                Title       = "IAM user activity",
                Description = "All IAM users with console access have recent activity.",
                Severity    = FindingSeverity.Ok
            };
    }

    /// <summary>
    /// Checks for active access keys that haven't been rotated in 90+ days.
    /// Uses credential report columns: access_key_1_active (8), access_key_1_last_rotated (9),
    /// access_key_2_active (13), access_key_2_last_rotated (14).
    /// </summary>
    private static SecurityFinding CheckAccessKeyRotationFromReport(string csv)
    {
        var cutoff = DateTime.UtcNow.AddDays(-90);
        var stale  = 0;

        foreach (var line in csv.Split('\n').Skip(1))
        {
            var cols = line.Trim().Split(',');
            if (cols.Length < 15) continue;
            var user = cols[0].Trim();
            if (user.Contains("<root_account>") || string.IsNullOrEmpty(user)) continue;

            if (IsStaleKey(cols[8], cols[9], cutoff))  stale++;
            if (IsStaleKey(cols[13], cols[14], cutoff)) stale++;
        }

        return stale > 0
            ? new SecurityFinding
            {
                Title         = "Access keys not rotated",
                Description   = $"{stale} active access key(s) have not been rotated in 90+ days. Rotate them to limit exposure from credential leaks.",
                Severity      = FindingSeverity.Warning,
                AffectedCount = stale
            }
            : new SecurityFinding
            {
                Title       = "Access key rotation",
                Description = "All active access keys have been rotated within the last 90 days.",
                Severity    = FindingSeverity.Ok
            };
    }

    private static bool IsStaleKey(string activeCol, string rotatedCol, DateTime cutoff)
    {
        if (activeCol.Trim() != "true") return false; // key not active
        var rotated = rotatedCol.Trim();
        if (rotated is "N/A" or "not_supported" or "") return false;
        return DateTime.TryParse(rotated, out var d) && d < cutoff;
    }

    // ── Password policy ───────────────────────────────────────────────────

    private static async Task<List<SecurityFinding>> CheckPasswordPolicyAsync(
        AmazonIdentityManagementServiceClient iam, CancellationToken ct)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var resp   = await iam.GetAccountPasswordPolicyAsync(new GetAccountPasswordPolicyRequest(), ct);
            var policy = resp.PasswordPolicy;
            var issues = new List<string>();

            if (policy.MinimumPasswordLength < 14) issues.Add($"min length is {policy.MinimumPasswordLength} (< 14)");
            if (!policy.RequireNumbers)             issues.Add("numbers not required");
            if (!policy.RequireSymbols)             issues.Add("symbols not required");
            if (!policy.RequireUppercaseCharacters) issues.Add("uppercase not required");
            if (policy.MaxPasswordAge == 0 || policy.MaxPasswordAge > 90)
                issues.Add("no 90-day rotation");
            if (policy.PasswordReusePrevention < 5)
                issues.Add("reuse prevention < 5");

            findings.Add(issues.Count > 0
                ? new SecurityFinding
                {
                    Title       = "Weak password policy",
                    Description = $"Policy issues: {string.Join(", ", issues)}.",
                    Severity    = FindingSeverity.Warning
                }
                : new SecurityFinding
                {
                    Title       = "Password policy",
                    Description = "A strong IAM password policy is configured.",
                    Severity    = FindingSeverity.Ok
                });
        }
        catch (AmazonIdentityManagementServiceException ex) when (ex.ErrorCode == "NoSuchEntity")
        {
            findings.Add(new SecurityFinding
            {
                Title       = "No password policy",
                Description = "No IAM password policy is configured. Users may set any password.",
                Severity    = FindingSeverity.Critical
            });
        }
        catch { /* no permission — silently skip */ }
        return findings;
    }

    // ── Account summary: MFA ──────────────────────────────────────────────

    private static async Task<List<SecurityFinding>> CheckAccountSummaryAsync(
        AmazonIdentityManagementServiceClient iam, CancellationToken ct)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var resp    = await iam.GetAccountSummaryAsync(new GetAccountSummaryRequest(), ct);
            var summary = resp.SummaryMap;

            var rootMfa = summary.TryGetValue("AccountMFAEnabled", out var r) ? r : 0;
            findings.Add(rootMfa == 1
                ? new SecurityFinding { Title = "Root MFA", Description = "MFA is enabled on the root account.", Severity = FindingSeverity.Ok }
                : new SecurityFinding { Title = "Root MFA disabled", Description = "MFA is NOT enabled on the root account. Enable it immediately.", Severity = FindingSeverity.Critical });

            var totalUsers = summary.TryGetValue("Users", out var u)           ? u : 0;
            var mfaInUse   = summary.TryGetValue("MFADevicesInUse", out var m) ? m : 0;

            if (totalUsers > 0)
            {
                var pct = (double)mfaInUse / totalUsers * 100;
                findings.Add(pct >= 80
                    ? new SecurityFinding
                    {
                        Title         = "MFA coverage",
                        Description   = $"{mfaInUse}/{totalUsers} users have MFA enabled ({pct:N0}%).",
                        Severity      = FindingSeverity.Ok,
                        AffectedCount = mfaInUse
                    }
                    : new SecurityFinding
                    {
                        Title         = "Low MFA coverage",
                        Description   = $"Only {mfaInUse}/{totalUsers} users have MFA ({pct:N0}%). Enable MFA for all users.",
                        Severity      = FindingSeverity.Warning,
                        AffectedCount = totalUsers - mfaInUse
                    });
            }
        }
        catch { /* no permission — silently skip */ }
        return findings;
    }

    // ── EC2 IMDSv1 check ──────────────────────────────────────────────────

    /// <summary>
    /// Flags EC2 instances where IMDSv1 is still enabled (HttpTokens != "required").
    /// IMDSv1 is exploitable via SSRF — e.g., the 2019 Capital One breach used it
    /// to steal credentials from the instance metadata endpoint.
    /// </summary>
    private async Task<List<SecurityFinding>> CheckImdsV1Async(CancellationToken ct)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var instances = await _ec2.GetInstancesAsync(ct);
            var imdsV1    = instances
                .Where(i => i.State != "terminated")
                .Where(i => i.MetadataHttpTokens != "required" && i.MetadataHttpTokens != "—")
                .ToList();

            findings.Add(imdsV1.Count > 0
                ? new SecurityFinding
                {
                    Title         = "IMDSv1 enabled on EC2",
                    Description   = $"{imdsV1.Count} running instance(s) still allow IMDSv1 (HttpTokens = optional). Set HttpTokens to 'required' to enforce IMDSv2 and prevent SSRF-based credential theft.",
                    Severity      = FindingSeverity.Warning,
                    AffectedCount = imdsV1.Count
                }
                : new SecurityFinding
                {
                    Title       = "IMDSv2 enforced",
                    Description = "All EC2 instances require IMDSv2 (HttpTokens = required).",
                    Severity    = FindingSeverity.Ok
                });
        }
        catch { /* no EC2 permission or no instances */ }
        return findings;
    }

    // ── S3 Block Public Access check ──────────────────────────────────────

    /// <summary>
    /// Checks S3 buckets for missing Block Public Access configuration.
    /// Caps at 30 buckets per audit to avoid timeouts on large accounts.
    /// </summary>
    private async Task<List<SecurityFinding>> CheckS3PublicAccessAsync(CancellationToken ct)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var s3Client = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
            var listResp = await s3Client.ListBucketsAsync(ct);
            var buckets  = listResp.Buckets.Take(30).ToList();

            if (buckets.Count == 0) return findings;

            var publicTasks = buckets.Select(b => IsPubliclyAccessibleAsync(s3Client, b.BucketName, ct));
            var results     = await Task.WhenAll(publicTasks);

            var publicBuckets = buckets
                .Zip(results)
                .Where(pair => pair.Second)
                .Select(pair => pair.First.BucketName)
                .ToList();

            var checkedCount = buckets.Count;
            var totalCount   = listResp.Buckets.Count;
            var suffix       = totalCount > 30 ? $" (checked {checkedCount} of {totalCount})" : string.Empty;

            findings.Add(publicBuckets.Count > 0
                ? new SecurityFinding
                {
                    Title         = "S3 buckets publicly accessible",
                    Description   = $"{publicBuckets.Count} bucket(s) are missing Block Public Access{suffix}: {string.Join(", ", publicBuckets.Take(5))}{(publicBuckets.Count > 5 ? "…" : "")}.",
                    Severity      = FindingSeverity.Critical,
                    AffectedCount = publicBuckets.Count
                }
                : new SecurityFinding
                {
                    Title       = "S3 Block Public Access",
                    Description = $"All checked S3 buckets have Block Public Access enabled{suffix}.",
                    Severity    = FindingSeverity.Ok
                });
        }
        catch { /* no S3 permission — silently skip */ }
        return findings;
    }

    /// <summary>
    /// Returns true if the bucket is missing any of the four Block Public Access flags.
    /// A missing GetPublicAccessBlock configuration (NoSuchPublicAccessBlockConfiguration)
    /// means the bucket has NO protections — treated as publicly accessible.
    /// </summary>
    private static async Task<bool> IsPubliclyAccessibleAsync(
        AmazonS3Client s3, string bucketName, CancellationToken ct)
    {
        try
        {
            var resp   = await s3.GetPublicAccessBlockAsync(
                new GetPublicAccessBlockRequest { BucketName = bucketName }, ct);
            var config = resp.PublicAccessBlockConfiguration;
            return !(config.BlockPublicAcls
                  && config.IgnorePublicAcls
                  && config.BlockPublicPolicy
                  && config.RestrictPublicBuckets);
        }
        catch (AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchPublicAccessBlockConfiguration")
        {
            return true; // no block config at all → potentially public
        }
        catch
        {
            return false; // permission error or bucket gone — don't flag
        }
    }

    // ── Fallback: inactive users via ListUsers ────────────────────────────

    private async Task<List<SecurityFinding>> CheckInactiveUsersAsync(CancellationToken ct)
    {
        var findings = new List<SecurityFinding>();
        try
        {
            var users    = await _iam.GetUsersAsync(ct);
            var cutoff   = DateTime.UtcNow.AddDays(-90);
            var inactive = users.Count(u => u.PasswordLastUsed == null || u.PasswordLastUsed < cutoff);

            findings.Add(inactive > 0
                ? new SecurityFinding
                {
                    Title         = "Inactive IAM users",
                    Description   = $"{inactive} user(s) have not logged in for 90+ days.",
                    Severity      = FindingSeverity.Warning,
                    AffectedCount = inactive
                }
                : new SecurityFinding
                {
                    Title       = "IAM user activity",
                    Description = "All IAM users have recent activity.",
                    Severity    = FindingSeverity.Ok
                });
        }
        catch { /* no permission — silently skip */ }
        return findings;
    }
}
