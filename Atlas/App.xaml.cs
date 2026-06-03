using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using System.Windows;
using System.Windows.Threading;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Database;
using Atlas.Infrastructure.Logging;
using Atlas.Infrastructure.Security;
using Atlas.Services;
using Atlas.Services.AWS;
using Atlas.ViewModels;

namespace Atlas;

public partial class App : Application
{
    private readonly IHost _host;

    public App()
    {
        // Catch any unhandled exception anywhere in the app
        DispatcherUnhandledException += (_, e) =>
        {
            FileLogger.Error("Unhandled UI exception", e.Exception);
            e.Handled = true; // prevent crash; remove this line if you want the OS crash dialog
        };

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            FileLogger.Error("AppDomain unhandled exception", e.ExceptionObject as Exception);

        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            FileLogger.Error("Unobserved Task exception", e.Exception);
            e.SetObserved();
        };

        _host = Host.CreateDefaultBuilder()
            .ConfigureServices(ConfigureServices)
            .Build();

        FileLogger.Info("Application starting");
    }

    private static void ConfigureServices(IServiceCollection services)
    {
        // ── Infrastructure ────────────────────────────────────────
        services.AddSingleton<DatabaseContext>();
        services.AddSingleton<IAccountRepository, AccountRepository>();
        services.AddSingleton<ICredentialProtector, DpapiCredentialProtector>();
        services.AddSingleton<AwsClientFactory>();

        // ── Domain Services ───────────────────────────────────────
        services.AddSingleton<IAccountService, AccountService>();
        services.AddSingleton<IThemeService, ThemeService>();
        services.AddSingleton<IAwsSessionFactory, AwsSessionFactory>();
        services.AddSingleton<IDialogService, DialogService>();

        // ── AWS Services ──────────────────────────────────────────
        services.AddTransient<IEc2Service, Ec2Service>();
        services.AddTransient<IS3Service, S3Service>();
        services.AddTransient<IDashboardService, DashboardService>();
        services.AddTransient<ISearchService, SearchService>();
        services.AddTransient<IIamService, IamService>();
        services.AddTransient<ISecurityAuditService, SecurityAuditService>();
        services.AddSingleton<IBudgetService, BudgetService>();
        services.AddTransient<IBillingService, BillingService>();
        services.AddTransient<ISsmTerminalService, SsmTerminalService>();
        services.AddTransient<ICloudWatchService, CloudWatchService>();
        services.AddTransient<IGuardDutyService, GuardDutyService>();

        // ── License ───────────────────────────────────────────────
        services.AddSingleton<ILicenseService, LicenseService>();
        services.AddSingleton<IUpgradeService, UpgradeService>();

        // ── Updates ───────────────────────────────────────────────
        services.AddSingleton<IUpdateService, UpdateService>();

        // ── ViewModels ────────────────────────────────────────────
        services.AddSingleton<CommandPaletteViewModel>();
        services.AddSingleton<DashboardViewModel>();
        services.AddSingleton<Ec2ViewModel>();
        services.AddSingleton<S3ViewModel>();
        services.AddSingleton<IamViewModel>();
        services.AddSingleton<BillingViewModel>();
        services.AddSingleton<CloudWatchViewModel>();
        services.AddSingleton<GuardDutyViewModel>();
        services.AddSingleton<SettingsViewModel>();
        services.AddSingleton<ContactViewModel>();
        services.AddSingleton<MainViewModel>();

        // ── Views ─────────────────────────────────────────────────
        services.AddTransient<LicenseViewModel>();
        services.AddTransient<MainWindow>();
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        try
        {
            await _host.StartAsync();
            _host.Services.GetRequiredService<IThemeService>().Apply(AppTheme.Dark);
            // Invalidate cached AWS clients when account or region changes
            var clientFactory  = _host.Services.GetRequiredService<AwsClientFactory>();
            var accountService = _host.Services.GetRequiredService<IAccountService>();
            accountService.ActiveAccountChanged += (_, _) => clientFactory.InvalidateAll();
            accountService.ActiveRegionChanged  += (_, _) => clientFactory.InvalidateAll();

            // Re-validate the stored license against LemonSqueezy on launch so that
            // keys disabled/refunded server-side stop working. Network errors are
            // tolerated (offline grace) — RefreshAsync only revokes on an explicit
            // valid=false from the server. The MainWindow itself shows an in-window
            // activation overlay when no valid license is present.
            var licenseService = _host.Services.GetRequiredService<ILicenseService>();
            if (licenseService.CurrentLicense is { IsValid: true })
            {
                try { await licenseService.RefreshAsync(); }
                catch (Exception ex) { FileLogger.Warning($"Startup license revalidation failed: {ex.Message}"); }
            }

            var mainWindow = _host.Services.GetRequiredService<MainWindow>();
            mainWindow.Show();
            FileLogger.Info("Main window shown");
        }
        catch (Exception ex)
        {
            FileLogger.Error("Fatal error during startup", ex);
            MessageBox.Show($"Failed to start Atlas.\nSee Atlas-errors.txt for details.\n\n{ex.Message}",
                "Startup Error", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
        base.OnStartup(e);
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        FileLogger.Info("Application exiting");
        await _host.StopAsync(TimeSpan.FromSeconds(5));
        _host.Dispose();
        base.OnExit(e);
    }
}
