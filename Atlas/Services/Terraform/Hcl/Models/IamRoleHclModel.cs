namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class IamInlinePolicy
{
    public string Name     { get; init; } = string.Empty;
    public string Document { get; init; } = "{}";
}

public sealed class IamRoleHclModel
{
    public string ResourceName       { get; init; } = "main";
    public string RoleName           { get; init; } = string.Empty;
    public string Description        { get; init; } = "Managed by Atlas";
    public string PrincipalService   { get; init; } = "ec2.amazonaws.com";
    public int    MaxSessionDuration { get; init; } = 3600;
    public string? PermissionsBoundary { get; init; }
    public IReadOnlyList<string>         ManagedPolicyArns { get; init; } = [];
    public IReadOnlyList<IamInlinePolicy> InlinePolicies   { get; init; } = [];
    public IReadOnlyList<HclTag>          Tags             { get; init; } = [];

    // ── Preset: Lambda execution role ────────────────────────────────────
    public static IamRoleHclModel LambdaExecution(string resourceName) => new()
    {
        ResourceName     = resourceName,
        RoleName         = resourceName,
        Description      = "Lambda execution role",
        PrincipalService = "lambda.amazonaws.com",
        ManagedPolicyArns =
        [
            "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        ],
    };

    // ── Preset: EC2 instance profile role ────────────────────────────────
    public static IamRoleHclModel Ec2InstanceProfile(string resourceName) => new()
    {
        ResourceName     = resourceName,
        RoleName         = resourceName,
        Description      = "EC2 instance profile role",
        PrincipalService = "ec2.amazonaws.com",
        ManagedPolicyArns =
        [
            "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        ],
    };
}
