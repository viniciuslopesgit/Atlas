namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class SgRule
{
    public string Description { get; init; } = string.Empty;
    public int    FromPort    { get; init; }
    public int    ToPort      { get; init; }
    public string Protocol    { get; init; } = "tcp";
    public IReadOnlyList<string> CidrBlocks { get; init; } = ["0.0.0.0/0"];
}

public sealed class SecurityGroupHclModel
{
    public string ResourceName  { get; init; } = "main";
    public string SgName        { get; init; } = string.Empty;
    public string Description   { get; init; } = "Managed by Atlas";
    public string? VpcId        { get; init; }
    public IReadOnlyList<SgRule> IngressRules { get; init; } = [];
    public IReadOnlyList<SgRule> EgressRules  { get; init; } =
    [
        new() { Description = "Allow all outbound", FromPort = 0, ToPort = 0, Protocol = "-1" },
    ];
    public IReadOnlyList<HclTag> Tags { get; init; } = [];

    // ── Preset: web server ────────────────────────────────────────────────
    public static SecurityGroupHclModel WebServer(string resourceName, string? vpcId = null) => new()
    {
        ResourceName = resourceName,
        SgName       = resourceName,
        Description  = "Web server security group",
        VpcId        = vpcId,
        IngressRules =
        [
            new() { Description = "HTTPS", FromPort = 443, ToPort = 443 },
            new() { Description = "HTTP",  FromPort = 80,  ToPort = 80  },
        ],
    };
}
