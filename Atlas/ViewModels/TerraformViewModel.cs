using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.Terraform;
using Atlas.Services.Terraform.Import;
using Atlas.Infrastructure.Logging;
using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Windows;

namespace Atlas.ViewModels;

public partial class TerraformViewModel : AsyncViewModel
{
    private readonly ITerraformProjectManager _manager;
    private readonly ITerraformCliWrapper     _cli;
    private readonly IAccountService          _accounts;
    private readonly ITerraformService        _terraformService;

    // BUG FIX: substituir concatenação O(n²) de TerminalOutput por StringBuilder.
    // Cada "TerminalOutput += line" criava uma nova string com toda a história anterior.
    private readonly StringBuilder _terminalBuffer = new();

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
    /// <summary>Duração do último comando concluído (ex.: "2.1s"). Vazio durante a execução.</summary>
    [ObservableProperty] private string  _commandDuration    = string.Empty;

    // ── Import settings ───────────────────────────────────────────────────
    [ObservableProperty] private bool   _importEc2          = true;
    [ObservableProperty] private bool   _importS3           = true;
    [ObservableProperty] private bool   _importIam          = true;
    [ObservableProperty] private bool   _importNetwork      = true;
    [ObservableProperty] private string _importTagKey       = string.Empty;
    [ObservableProperty] private string _importTagValue     = string.Empty;
    [ObservableProperty] private bool   _importIncludeTerminated  = false;
    [ObservableProperty] private bool   _importIncludeAwsManaged  = false;

    // ── Import result ─────────────────────────────────────────────────────
    [ObservableProperty] private int    _importResourcesFound;
    [ObservableProperty] private string _importFilesWritten = string.Empty;

    public static string[] BackendTypes { get; } = ["local", "s3", "azurerm", "gcs", "remote"];

    public TerraformViewModel(
        ITerraformProjectManager manager,
        ITerraformCliWrapper     cli,
        IAccountService          accounts,
        ITerraformService        terraformService)
    {
        _manager          = manager;
        _cli              = cli;
        _accounts         = accounts;
        _terraformService = terraformService;
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

    // ── Limpar terminal ───────────────────────────────────────────────────

    [RelayCommand]
    private void ClearTerminal()
    {
        _terminalBuffer.Clear();
        TerminalOutput       = null;
        CommandResultMessage = null;
        CommandResultSuccess = false;
        CommandDuration      = string.Empty;
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

    // ── Import / Sync ─────────────────────────────────────────────────────

    [RelayCommand]
    private Task RunImport() =>
        RunServiceOperationAsync("import from AWS", async (prog, ct) =>
        {
            var options = new ImportOptions
            {
                ResourceTypes              = BuildResourceTypes(),
                TagFilters                 = BuildTagFilters(),
                IncludeTerminated          = ImportIncludeTerminated,
                IncludeAwsManagedResources = ImportIncludeAwsManaged,
            };
            return await _terraformService.ImportExistingResourcesAsync(
                options, generateHcl: true, progress: prog, ct: ct);
        });

    [RelayCommand]
    private Task RunSync() =>
        RunServiceOperationAsync("sync with AWS", (prog, ct) =>
            _terraformService.SyncWithAwsAsync(prog, ct));

    // ── Núcleo: operações de serviço (import / sync) ──────────────────────

    private async Task RunServiceOperationAsync(
        string label,
        Func<IProgress<string>, CancellationToken, Task<TerraformOperationResult>> execute)
    {
        if (IsCommandRunning) return;

        IsCommandRunning     = true;
        ActiveCommandLabel   = label;
        CommandDuration      = string.Empty;
        CommandResultMessage = null;

        // BUG FIX: usar StringBuilder para evitar alocações O(n²).
        _terminalBuffer.Clear();
        TerminalOutput = string.Empty;

        ImportResourcesFound = 0;
        ImportFilesWritten   = string.Empty;

        var ct = BeginLoad();

        var progress = new Progress<string>(line =>
        {
            Application.Current.Dispatcher.Invoke(() =>
            {
                _terminalBuffer.AppendLine(line);
                TerminalOutput = _terminalBuffer.ToString();
            });
        });

        try
        {
            var result = await execute(progress, ct).ConfigureAwait(false);

            // BUG FIX: todas as propriedades de UI num único Dispatcher.Invoke — thread safety.
            Application.Current.Dispatcher.Invoke(() =>
            {
                ImportResourcesFound = result.ResourcesFound;
                ImportFilesWritten   = result.WrittenFiles.Count > 0
                    ? string.Join(", ", result.WrittenFiles.Select(Path.GetFileName))
                    : string.Empty;

                if (!string.IsNullOrWhiteSpace(result.Output))
                {
                    _terminalBuffer.AppendLine(result.Output);
                    TerminalOutput = _terminalBuffer.ToString();
                }

                CommandResultSuccess = result.Success;
                CommandResultMessage = result.Success
                    ? BuildImportSuccessMessage(result)
                    : result.ErrorMessage;
                CommandDuration = FormatDuration(result.Duration);

                RefreshProjects();
            });
        }
        catch (OperationCanceledException)
        {
            // BUG FIX: HandleError retorna sem chamar EndLoad para OCE → IsLoading ficava stuck.
            // Aqui tratamos o cancel explicitamente antes do finally chamar EndLoad.
            Application.Current.Dispatcher.Invoke(() =>
            {
                CommandResultSuccess = false;
                CommandResultMessage = "Operação cancelada.";
                CommandDuration      = string.Empty;
            });
        }
        catch (Exception ex)
        {
            FileLogger.Error($"TerraformViewModel.{label}", ex);
            Application.Current.Dispatcher.Invoke(() =>
            {
                CommandResultSuccess = false;
                CommandResultMessage = ex.Message;
                CommandDuration      = string.Empty;
            });
        }
        finally
        {
            // BUG FIX: EndLoad sempre chamado (evita IsLoading stuck em qualquer caminho de erro).
            EndLoad(false);
            IsCommandRunning   = false;
            ActiveCommandLabel = string.Empty;
        }
    }

    private IReadOnlyList<AwsResourceType> BuildResourceTypes()
    {
        var types = new List<AwsResourceType>();
        if (ImportEc2)     types.Add(AwsResourceType.Ec2Instance);
        if (ImportS3)      types.Add(AwsResourceType.S3Bucket);
        if (ImportIam)   { types.Add(AwsResourceType.IamRole); types.Add(AwsResourceType.IamUser); }
        if (ImportNetwork) { types.Add(AwsResourceType.Vpc); types.Add(AwsResourceType.Subnet); types.Add(AwsResourceType.SecurityGroup); }
        return types.Count > 0 ? types : Enum.GetValues<AwsResourceType>().ToList();
    }

    private IReadOnlyList<TagFilter> BuildTagFilters()
    {
        if (!string.IsNullOrWhiteSpace(ImportTagKey))
            return [new TagFilter(
                ImportTagKey.Trim(),
                string.IsNullOrWhiteSpace(ImportTagValue) ? null : ImportTagValue.Trim())];
        return [];
    }

    private static string BuildImportSuccessMessage(TerraformOperationResult result) =>
        result.ResourcesFound > 0
            ? $"Import concluído — {result.ResourcesFound} recurso(s), {result.WrittenFiles.Count} ficheiro(s) gerado(s)."
            : "Import concluído — nenhum recurso encontrado.";

    // ── Núcleo de execução de comando CLI com streaming ───────────────────

    private async Task RunCommandAsync(
        TerraformProjectConfig project,
        string                 label,
        Func<string, TerraformAwsCredentials?, IProgress<string>, CancellationToken, Task<TerraformResult>> execute)
    {
        if (IsCommandRunning) return;

        IsCommandRunning     = true;
        ActiveCommandLabel   = label;
        CommandDuration      = string.Empty;
        CommandResultMessage = null;

        // BUG FIX: usar StringBuilder para evitar alocações O(n²).
        _terminalBuffer.Clear();
        TerminalOutput = string.Empty;

        var ct = BeginLoad();

        var progress = new Progress<string>(line =>
        {
            Application.Current.Dispatcher.Invoke(() =>
            {
                _terminalBuffer.AppendLine(line);
                TerminalOutput = _terminalBuffer.ToString();
            });
        });

        try
        {
            var credentials = BuildCredentials();
            var result = await execute(project.RootPath, credentials, progress, ct)
                              .ConfigureAwait(false);

            // BUG FIX: atribuições de propriedades UI no Dispatcher — thread safety.
            Application.Current.Dispatcher.Invoke(() =>
            {
                CommandResultSuccess = result.IsSuccess;
                CommandResultMessage = result.IsSuccess
                    ? BuildSuccessMessage(result)
                    : result.DiagnosticMessage;
                CommandDuration = FormatDuration(result.Duration);

                // Garante que stderr completo está visível
                if (!string.IsNullOrWhiteSpace(result.Stderr))
                {
                    _terminalBuffer.AppendLine($"\n─── stderr ───\n{result.Stderr}");
                    TerminalOutput = _terminalBuffer.ToString();
                }

                RefreshProjects();
            });
        }
        catch (OperationCanceledException)
        {
            // BUG FIX: HandleError retorna sem chamar EndLoad para OCE.
            Application.Current.Dispatcher.Invoke(() =>
            {
                CommandResultSuccess = false;
                CommandResultMessage = "Operação cancelada.";
                CommandDuration      = string.Empty;
            });
        }
        catch (Exception ex)
        {
            FileLogger.Error($"TerraformViewModel.{label}", ex);
            Application.Current.Dispatcher.Invoke(() =>
            {
                CommandResultSuccess = false;
                CommandResultMessage = ex.Message;
                CommandDuration      = string.Empty;
            });
        }
        finally
        {
            // BUG FIX: EndLoad garantido em todos os caminhos.
            EndLoad(false);
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

    private static string FormatDuration(TimeSpan d) =>
        d == TimeSpan.Zero ? string.Empty :
        d.TotalSeconds >= 1 ? $"{d.TotalSeconds:0.0}s" : $"{d.TotalMilliseconds:0}ms";

    public void SetNewRootPath(string path) => NewRootPath = path;

    private void RefreshProjects()
    {
        Projects.Clear();
        foreach (var p in _manager.GetProjects())
            Projects.Add(p);
    }
}
