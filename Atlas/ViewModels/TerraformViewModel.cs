using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.Terraform;
using System.Collections.ObjectModel;
using System.Windows;

namespace Atlas.ViewModels;

public partial class TerraformViewModel : AsyncViewModel
{
    private readonly ITerraformProjectManager _manager;
    private readonly ITerraformCliWrapper     _cli;
    private readonly IAccountService          _accounts;

    public ObservableCollection<TerraformProjectConfig> Projects { get; } = [];

    // ── Versão do terraform ───────────────────────────────────────────────
    [ObservableProperty] private string? _terraformVersion;

    // ── Add Project form ──────────────────────────────────────────────────
    [ObservableProperty] private string _newName        = string.Empty;
    [ObservableProperty] private string _newRootPath    = string.Empty;
    [ObservableProperty] private string _newWorkspace   = "default";
    [ObservableProperty] private string _newBackendType = "local";
    [ObservableProperty] private bool   _newAutoCommit;
    [ObservableProperty] private string? _addMessage;
    [ObservableProperty] private bool    _addSuccess;

    // ── Output do terminal ────────────────────────────────────────────────
    [ObservableProperty] private string? _terminalOutput;
    [ObservableProperty] private bool    _isCommandRunning;
    [ObservableProperty] private string? _commandResultMessage;
    [ObservableProperty] private bool    _commandResultSuccess;
    [ObservableProperty] private string  _activeCommandLabel = string.Empty;

    public static string[] BackendTypes { get; } = ["local", "s3", "azurerm", "gcs", "remote"];

    public TerraformViewModel(
        ITerraformProjectManager manager,
        ITerraformCliWrapper     cli,
        IAccountService          accounts)
    {
        _manager  = manager;
        _cli      = cli;
        _accounts = accounts;
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        RefreshProjects();
        if (TerraformVersion is null || force)
            TerraformVersion = await _cli.GetVersionAsync().ConfigureAwait(false) ?? "terraform não encontrado";
    }

    // ── Add / Remove project ──────────────────────────────────────────────

    [RelayCommand]
    private async Task AddProject()
    {
        AddMessage = null;
        AddSuccess = false;

        if (string.IsNullOrWhiteSpace(NewName))
        {
            AddMessage = "Project name is required.";
            return;
        }

        AddMessage = "Validating path…";
        var valid = await _manager.ValidateProjectAsync(NewRootPath).ConfigureAwait(false);
        if (!valid)
        {
            AddMessage = "Path does not exist or contains no .tf files.";
            return;
        }

        var config = new TerraformProjectConfig
        {
            Name              = NewName.Trim(),
            RootPath          = NewRootPath.Trim(),
            DefaultWorkspace  = string.IsNullOrWhiteSpace(NewWorkspace) ? "default" : NewWorkspace.Trim(),
            BackendType       = NewBackendType,
            AutoCommitEnabled = NewAutoCommit,
        };

        _manager.SaveProject(config);
        RefreshProjects();

        AddMessage     = $"Project \"{config.Name}\" added.";
        AddSuccess     = true;
        NewName        = string.Empty;
        NewRootPath    = string.Empty;
        NewWorkspace   = "default";
        NewBackendType = "local";
        NewAutoCommit  = false;
    }

    [RelayCommand]
    private void RemoveProject(TerraformProjectConfig project)
    {
        _manager.DeleteProject(project.Id);
        Projects.Remove(project);
    }

    // ── Comandos Terraform (um por vez) ──────────────────────────────────

    [RelayCommand]
    private Task RunInit(TerraformProjectConfig project) =>
        RunCommandAsync(project, "terraform init", async (dir, creds, prog, ct) =>
        {
            var result = await _cli.InitAsync(dir, upgrade: false, credentials: creds, progress: prog, ct: ct)
                                   .ConfigureAwait(false);
            if (result.IsSuccess)
            {
                project.IsInitialized = true;
                _manager.SaveProject(project);
            }
            return result;
        });

    [RelayCommand]
    private Task RunValidate(TerraformProjectConfig project) =>
        RunCommandAsync(project, "terraform validate", (dir, _, prog, ct) =>
            _cli.ValidateAsync(dir, prog, ct));

    [RelayCommand]
    private Task RunPlan(TerraformProjectConfig project) =>
        RunCommandAsync(project, "terraform plan", (dir, creds, prog, ct) =>
            _cli.PlanAsync(dir, detailed: false, credentials: creds, progress: prog, ct: ct));

    [RelayCommand]
    private Task RunApply(TerraformProjectConfig project) =>
        RunCommandAsync(project, "terraform apply", (dir, creds, prog, ct) =>
            _cli.ApplyAsync(dir, credentials: creds, progress: prog, ct: ct));

    [RelayCommand]
    private Task RunOutput(TerraformProjectConfig project) =>
        RunCommandAsync(project, "terraform output", (dir, _, prog, ct) =>
            _cli.OutputAsync(dir, json: false, progress: prog, ct: ct));

    // ── Núcleo de execução de comando com streaming ───────────────────────

    private async Task RunCommandAsync(
        TerraformProjectConfig project,
        string                 label,
        Func<string, TerraformAwsCredentials?, IProgress<string>, CancellationToken, Task<TerraformResult>> execute)
    {
        if (IsCommandRunning) return;

        IsCommandRunning     = true;
        ActiveCommandLabel   = label;
        TerminalOutput       = string.Empty;
        CommandResultMessage = null;

        var ct = BeginLoad();

        var progress = new Progress<string>(line =>
        {
            // Atualiza o terminal em tempo real na UI thread
            Application.Current.Dispatcher.Invoke(() =>
                TerminalOutput += line + "\n");
        });

        try
        {
            var credentials = BuildCredentials();
            var result = await execute(project.RootPath, credentials, progress, ct)
                              .ConfigureAwait(false);

            CommandResultSuccess = result.IsSuccess;
            CommandResultMessage = result.IsSuccess
                ? BuildSuccessMessage(result)
                : result.DiagnosticMessage;

            // Garante que o output completo esteja visível (inclui stderr)
            if (!string.IsNullOrWhiteSpace(result.Stderr))
            {
                Application.Current.Dispatcher.Invoke(() =>
                    TerminalOutput += $"\n─── stderr ───\n{result.Stderr}");
            }

            RefreshProjects();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError($"TerraformViewModel.{label}", ex);
            CommandResultMessage = ex.Message;
            CommandResultSuccess = false;
        }
        finally
        {
            IsCommandRunning   = false;
            ActiveCommandLabel = string.Empty;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /// <summary>Constrói credenciais a partir da conta AWS ativa (nunca salva em disco).</summary>
    private TerraformAwsCredentials? BuildCredentials()
    {
        var account = _accounts.ActiveAccount;
        if (account is null) return null;

        return new TerraformAwsCredentials(
            AccessKeyId:     account.AccessKeyId,
            SecretAccessKey: _accounts.GetActiveSecretKey(),
            Region:          _accounts.ActiveRegion);
    }

    private static string BuildSuccessMessage(TerraformResult result) => result.Status switch
    {
        TerraformResultStatus.PlanHasChanges => "Plan concluído — há alterações pendentes.",
        TerraformResultStatus.NoChanges      => "Plan concluído — nenhuma alteração.",
        _                                    => "Comando concluído com sucesso.",
    };

    public void SetNewRootPath(string path) => NewRootPath = path;

    private void RefreshProjects()
    {
        Projects.Clear();
        foreach (var p in _manager.GetProjects())
            Projects.Add(p);
    }
}
