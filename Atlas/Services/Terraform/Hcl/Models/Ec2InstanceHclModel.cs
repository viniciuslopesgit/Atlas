namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class Ec2InstanceHclModel
{
    // ── Identificador do recurso Terraform ────────────────────────────────
    public string ResourceName   { get; init; } = "main";

    // ── Campos obrigatórios ───────────────────────────────────────────────
    public string AmiId          { get; init; } = string.Empty;
    public string InstanceType   { get; init; } = "t3.micro";

    // ── Rede ─────────────────────────────────────────────────────────────
    public string? SubnetId      { get; init; }
    public bool    AssociatePublicIp { get; init; }
    public IReadOnlyList<string> SecurityGroupIds { get; init; } = [];

    // ── Acesso ───────────────────────────────────────────────────────────
    public string? KeyName       { get; init; }
    public string? IamInstanceProfile { get; init; }

    // ── Comportamento ─────────────────────────────────────────────────────
    public bool   Monitoring     { get; init; }
    public bool   DisableApiTermination { get; init; }
    public string? UserData      { get; init; }

    // ── Armazenamento ─────────────────────────────────────────────────────
    public int    RootVolumeGb   { get; init; } = 20;
    public string RootVolumeType { get; init; } = "gp3";
    public bool   DeleteOnTermination { get; init; } = true;

    // ── Tags ──────────────────────────────────────────────────────────────
    public IReadOnlyList<HclTag> Tags { get; init; } = [];

    // ── Helpers de construção a partir do modelo Atlas existente ──────────

    public static Ec2InstanceHclModel FromAtlasInstance(
        Atlas.Models.Ec2InstanceModel instance,
        string? overrideResourceName = null) =>
        new()
        {
            ResourceName  = overrideResourceName
                            ?? SanitizeIdentifier(instance.Name.Length > 0 ? instance.Name : instance.InstanceId),
            AmiId         = instance.ImageId,
            InstanceType  = instance.InstanceType,
            SubnetId      = NullIfEmpty(instance.SubnetId),
            KeyName       = NullIfEmpty(instance.KeyName),
            IamInstanceProfile = NullIfEmpty(instance.IamInstanceProfileName),
            Monitoring    = instance.MonitoringState == "enabled",
            Tags =
            [
                new("Environment", "production"),
                new("InstanceId",  instance.InstanceId),
            ],
        };

    private static string? NullIfEmpty(string s) =>
        string.IsNullOrWhiteSpace(s) ? null : s;

    private static string SanitizeIdentifier(string raw) =>
        System.Text.RegularExpressions.Regex
            .Replace(raw.ToLowerInvariant().Replace(' ', '_'), @"[^a-z0-9_]", "")
            .TrimStart('0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
            .DefaultIfEmpty('r').ToString() ?? "resource";
}
