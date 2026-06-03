using Amazon.SimpleSystemsManagement.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Ssm;

namespace Atlas.Services.AWS;

public sealed class SsmTerminalService : ISsmTerminalService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;

    public SsmTerminalService(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    public async Task OpenSessionAsync(string instanceId, string region, CancellationToken ct = default)
    {
        // ── Approach 1: aws ssm start-session (preferred) ────────────────────
        //
        // Delegates StartSession + plugin invocation to the AWS CLI.
        // The CLI has been battle-tested for this exact scenario and correctly
        // hands the console off to the plugin for interactive I/O.
        // Atlas's active credentials are injected via environment variables so
        // the correct account / assumed-role is used regardless of CLI config.
        var creds = await _session.GetCredentials().GetCredentialsAsync();
        if (SsmNativeTerminalLauncher.LaunchViaCli(instanceId, region, creds))
            return;

        // ── Approach 2: session-manager-plugin directly (fallback) ───────────
        //
        // Used when the AWS CLI is not installed.
        // We call StartSession ourselves and pass the response to the plugin.
        if (!SsmPluginLocator.IsInstalled())
            throw new InvalidOperationException(
                "Neither the AWS CLI nor the Session Manager Plugin is installed.\n\n" +
                "Install one of the following:\n" +
                "  • AWS CLI v2  (recommended):  winget install Amazon.AWSCLI\n" +
                $"  • Session Manager Plugin:     {SsmPluginLocator.InstallUrl}");

        var pluginPath = SsmPluginLocator.Find()!;
        var client     = _clients.GetSsm(_session.GetCredentials(), region);

        StartSessionResponse response;
        try
        {
            response = await client.StartSessionAsync(
                new StartSessionRequest { Target = instanceId }, ct);
        }
        catch (Amazon.SimpleSystemsManagement.AmazonSimpleSystemsManagementException ex)
            when (ex.ErrorCode is "TargetNotConnected")
        {
            throw new InvalidOperationException(
                $"Instance '{instanceId}' is not connected to SSM.\n\n" +
                "Make sure the instance:\n" +
                "  • Has the SSM Agent installed and running\n" +
                "  • Has the AmazonSSMManagedInstanceCore IAM policy\n" +
                "  • Can reach the SSM endpoints (internet or VPC endpoint)");
        }

        SsmNativeTerminalLauncher.Launch(
            pluginPath:  pluginPath,
            sessionId:   response.SessionId,
            streamUrl:   response.StreamUrl,
            tokenValue:  response.TokenValue,
            region:      region,
            instanceId:  instanceId);
    }
}
