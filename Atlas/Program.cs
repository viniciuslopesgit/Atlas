using Atlas.Infrastructure;
using Velopack;

namespace Atlas;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        VelopackApp.Build()
            // Best-effort: no UAC prompt. Works when the user already has admin rights.
            // In restricted environments the in-app "Fix Network Access" button handles it.
            .OnFirstRun(_ => FirewallHelper.TryAddOutboundRule())
            .OnAfterInstallFastCallback(_ => FirewallHelper.TryAddOutboundRule())
            .Run();

        var app = new App();
        app.InitializeComponent();
        app.Run();
    }
}
