using Atlas.Infrastructure.Logging;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform;

public sealed class TerraformCliWrapper : ITerraformCliWrapper
{
    // ── Configuração ──────────────────────────────────────────────────────

    /// <inheritdoc/>
    public TimeSpan DefaultTimeout { get; set; } = TimeSpan.FromMinutes(5);

    // ── Comandos públicos ─────────────────────────────────────────────────

    /// <inheritdoc/>
    public async Task<string?> GetVersionAsync(CancellationToken ct = default)
    {
        try
        {
            var result = await RunCoreAsync(
                workingDir:  Directory.GetCurrentDirectory(),
                args:        "version -json",
                credentials: null,
                progress:    null,
                timeout:     TimeSpan.FromSeconds(10),
                ct:          ct).ConfigureAwait(false);

            if (!result.IsSuccess) return null;

            // "terraform_version": "1.7.4"
            var match = Regex.Match(result.Stdout, @"""terraform_version""\s*:\s*""([^""]+)""");
            return match.Success ? $"v{match.Groups[1].Value}" : result.Stdout.Trim();
        }
        catch
        {
            return null;
        }
    }

    /// <inheritdoc/>
    public Task<TerraformResult> InitAsync(
        string                   workingDir,
        bool                     upgrade     = false,
        TerraformAwsCredentials? credentials = null,
        IProgress<string>?       progress    = null,
        CancellationToken        ct          = default)
    {
        var args = upgrade
            ? "init -no-color -upgrade"
            : "init -no-color";

        FileLogger.Info($"[TerraformCLI] init  dir={workingDir}");
        return RunCoreAsync(workingDir, args, credentials, progress, DefaultTimeout, ct);
    }

    /// <inheritdoc/>
    public Task<TerraformResult> ValidateAsync(
        string             workingDir,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        FileLogger.Info($"[TerraformCLI] validate  dir={workingDir}");
        return RunCoreAsync(workingDir, "validate -no-color", null, progress, DefaultTimeout, ct);
    }

    /// <inheritdoc/>
    public Task<TerraformResult> PlanAsync(
        string                   workingDir,
        bool                     detailed    = false,
        string?                  planOutFile = null,
        TerraformAwsCredentials? credentials = null,
        IProgress<string>?       progress    = null,
        CancellationToken        ct          = default)
    {
        var sb = new StringBuilder("plan -no-color -detailed-exitcode");
        if (planOutFile is not null)
            sb.Append($" -out=\"{planOutFile}\"");

        FileLogger.Info($"[TerraformCLI] plan  dir={workingDir}  detailed={detailed}");
        return RunCoreAsync(workingDir, sb.ToString(), credentials, progress, DefaultTimeout, ct,
            postProcess: static result =>
            {
                // exit 0 = no changes, exit 2 = changes present (not an error for plan)
                if (result.ExitCode == 2)
                    return result with
                    {
                        Status            = TerraformResultStatus.PlanHasChanges,
                        DiagnosticMessage = "Plan concluído — há alterações pendentes.",
                    };
                if (result.ExitCode == 0 && result.IsSuccess)
                    return result with { Status = TerraformResultStatus.NoChanges };
                return result;
            });
    }

    /// <inheritdoc/>
    public Task<TerraformResult> ApplyAsync(
        string                   workingDir,
        string?                  planFile    = null,
        TerraformAwsCredentials? credentials = null,
        IProgress<string>?       progress    = null,
        CancellationToken        ct          = default)
    {
        // Sem planFile → -auto-approve obrigatório para não travar aguardando input.
        var args = planFile is null
            ? "apply -no-color -auto-approve"
            : $"apply -no-color \"{planFile}\"";

        FileLogger.Info($"[TerraformCLI] apply  dir={workingDir}  plan={planFile ?? "(none)"}");
        return RunCoreAsync(workingDir, args, credentials, progress, DefaultTimeout, ct);
    }

    /// <inheritdoc/>
    public Task<TerraformResult> ImportAsync(
        string                   workingDir,
        string                   resourceAddress,
        string                   resourceId,
        TerraformAwsCredentials? credentials = null,
        IProgress<string>?       progress    = null,
        CancellationToken        ct          = default)
    {
        if (string.IsNullOrWhiteSpace(resourceAddress))
            throw new ArgumentException("resourceAddress não pode ser vazio.", nameof(resourceAddress));
        if (string.IsNullOrWhiteSpace(resourceId))
            throw new ArgumentException("resourceId não pode ser vazio.", nameof(resourceId));

        var args = $"import -no-color \"{resourceAddress}\" \"{resourceId}\"";
        FileLogger.Info($"[TerraformCLI] import  dir={workingDir}  addr={resourceAddress}  id={resourceId}");
        return RunCoreAsync(workingDir, args, credentials, progress, DefaultTimeout, ct);
    }

    /// <inheritdoc/>
    public Task<TerraformResult> OutputAsync(
        string             workingDir,
        bool               json     = false,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        var args = json ? "output -no-color -json" : "output -no-color";
        FileLogger.Info($"[TerraformCLI] output  dir={workingDir}  json={json}");
        return RunCoreAsync(workingDir, args, null, progress, DefaultTimeout, ct);
    }

    // ── Núcleo: execução do processo ──────────────────────────────────────

    private static async Task<TerraformResult> RunCoreAsync(
        string                              workingDir,
        string                              args,
        TerraformAwsCredentials?            credentials,
        IProgress<string>?                  progress,
        TimeSpan                            timeout,
        CancellationToken                   ct,
        Func<TerraformResult, TerraformResult>? postProcess = null)
    {
        var sw = Stopwatch.StartNew();

        // CTS combinado: respeita ct do chamador + timeout local
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts  = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);

        var stdoutSb = new StringBuilder();
        var stderrSb = new StringBuilder();

        ProcessStartInfo psi;
        try
        {
            psi = BuildProcessStartInfo(workingDir, args, credentials);
        }
        catch (Exception ex)
        {
            FileLogger.Error("[TerraformCLI] Falha ao montar ProcessStartInfo", ex);
            return TerraformResult.NotFound();
        }

        Process? process = null;
        try
        {
            process = Process.Start(psi);
        }
        catch (Win32Exception ex) when (IsNotFoundError(ex))
        {
            FileLogger.Warning($"[TerraformCLI] terraform não encontrado no PATH: {ex.Message}");
            return TerraformResult.NotFound();
        }
        catch (FileNotFoundException ex)
        {
            FileLogger.Warning($"[TerraformCLI] terraform não encontrado: {ex.Message}");
            return TerraformResult.NotFound();
        }
        catch (Exception ex)
        {
            FileLogger.Error("[TerraformCLI] Erro ao iniciar processo", ex);
            return BuildFailed(ex.Message, string.Empty, string.Empty, sw.Elapsed, []);
        }

        if (process is null)
        {
            FileLogger.Error("[TerraformCLI] Process.Start retornou null", null);
            return BuildFailed("Falha ao iniciar o processo terraform.", string.Empty, string.Empty, sw.Elapsed, []);
        }

        using (process)
        {
            // Captura assíncrona de stdout e stderr
            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data is null) return;
                stdoutSb.AppendLine(e.Data);
                progress?.Report(e.Data);
            };
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data is null) return;
                stderrSb.AppendLine(e.Data);
                // Erros do terraform também são reportados como progress para o usuário ver em tempo real
                progress?.Report(e.Data);
            };

            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                await process.WaitForExitAsync(linkedCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch { /* ignora */ }

                sw.Stop();
                if (timeoutCts.IsCancellationRequested && !ct.IsCancellationRequested)
                {
                    FileLogger.Warning($"[TerraformCLI] Timeout após {sw.Elapsed.TotalSeconds:0}s  args={args}");
                    return TerraformResult.Timeout(sw.Elapsed);
                }

                FileLogger.Info($"[TerraformCLI] Cancelado pelo usuário  args={args}");
                return TerraformResult.Cancelled();
            }

            sw.Stop();

            var stdout   = stdoutSb.ToString();
            var stderr   = stderrSb.ToString();
            var exitCode = process.ExitCode;

            FileLogger.Info($"[TerraformCLI] exit={exitCode}  duration={sw.Elapsed.TotalSeconds:0.0}s  args={args}");

            var errors  = ParseTerraformErrors(stdout, stderr);
            var result  = BuildResult(exitCode, stdout, stderr, errors, sw.Elapsed);

            return postProcess is not null ? postProcess(result) : result;
        }
    }

    // ── Helpers de construção ─────────────────────────────────────────────

    private static ProcessStartInfo BuildProcessStartInfo(
        string                   workingDir,
        string                   args,
        TerraformAwsCredentials? credentials)
    {
        var psi = new ProcessStartInfo("terraform", args)
        {
            WorkingDirectory       = workingDir,
            RedirectStandardOutput = true,
            RedirectStandardError  = true,
            UseShellExecute        = false,
            CreateNoWindow         = true,
        };

        // Evita prompts interativos e adapta output para automação
        psi.Environment["TF_IN_AUTOMATION"] = "1";
        psi.Environment["TF_INPUT"]         = "false";

        // Injeta credenciais AWS como env vars temporárias do processo filho.
        // O processo pai (Atlas) NÃO tem seus env vars alterados.
        if (credentials is not null)
        {
            psi.Environment["AWS_ACCESS_KEY_ID"]     = credentials.AccessKeyId;
            psi.Environment["AWS_SECRET_ACCESS_KEY"] = credentials.SecretAccessKey;
            psi.Environment["AWS_DEFAULT_REGION"]    = credentials.Region;

            if (credentials.SessionToken is not null)
                psi.Environment["AWS_SESSION_TOKEN"] = credentials.SessionToken;
        }

        return psi;
    }

    private static TerraformResult BuildResult(
        int                  exitCode,
        string               stdout,
        string               stderr,
        IReadOnlyList<string> errors,
        TimeSpan             elapsed)
    {
        if (exitCode == 0)
            return new TerraformResult
            {
                Status    = TerraformResultStatus.Success,
                ExitCode  = exitCode,
                Stdout    = stdout,
                Stderr    = stderr,
                Duration  = elapsed,
                ParsedErrors = errors,
                DiagnosticMessage = string.Empty,
            };

        var diagnostic = BuildDiagnosticMessage(exitCode, stdout, stderr, errors);
        return new TerraformResult
        {
            Status            = TerraformResultStatus.Failed,
            ExitCode          = exitCode,
            Stdout            = stdout,
            Stderr            = stderr,
            Duration          = elapsed,
            ParsedErrors      = errors,
            DiagnosticMessage = diagnostic,
        };
    }

    private static TerraformResult BuildFailed(
        string               diagnostic,
        string               stdout,
        string               stderr,
        TimeSpan             elapsed,
        IReadOnlyList<string> errors) =>
        new()
        {
            Status            = TerraformResultStatus.Failed,
            ExitCode          = -1,
            Stdout            = stdout,
            Stderr            = stderr,
            Duration          = elapsed,
            ParsedErrors      = errors,
            DiagnosticMessage = diagnostic,
        };

    // ── Parsing de erros do Terraform ─────────────────────────────────────

    /// <summary>
    /// Extrai blocos de erro do output do Terraform.
    /// Suporta o formato legado (TF 0.x) e o formato de diagnóstico (TF 1.x com ╷/╵).
    /// </summary>
    private static IReadOnlyList<string> ParseTerraformErrors(string stdout, string stderr)
    {
        var errors = new List<string>();
        var combined = stdout + "\n" + stderr;

        // Terraform 1.x: blocos delimitados por ╷ ... ╵
        // ╷
        // │ Error: <título>
        // │
        // │ <detalhe>
        // ╵
        var tfBlocks = Regex.Matches(combined, @"╷(.*?)╵", RegexOptions.Singleline);
        if (tfBlocks.Count > 0)
        {
            foreach (Match m in tfBlocks)
            {
                var block = m.Groups[1].Value
                    .Replace("│ ", string.Empty)
                    .Replace("│", string.Empty)
                    .Trim();
                if (block.Contains("Error:", StringComparison.OrdinalIgnoreCase))
                    errors.Add(block);
            }
            return errors;
        }

        // Formato legado: linhas que começam com "Error:"
        foreach (var line in combined.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("Error:", StringComparison.OrdinalIgnoreCase))
                errors.Add(trimmed);
        }

        return errors;
    }

    /// <summary>
    /// Mapeia padrões de erro conhecidos do Terraform para mensagens amigáveis ao usuário.
    /// </summary>
    private static string BuildDiagnosticMessage(
        int                  exitCode,
        string               stdout,
        string               stderr,
        IReadOnlyList<string> parsedErrors)
    {
        var combined = (stdout + " " + stderr).ToLowerInvariant();

        // Erros de autenticação AWS
        if (ContainsAny(combined,
            "nocredentialproviders", "invalidclienttokenid", "authfailure",
            "aws_access_key_id", "no credential", "token has expired",
            "expiredtokenexception", "invaliduserexception"))
            return "Credenciais AWS inválidas ou expiradas. Verifique o Access Key e Secret Key configurados.";

        // State lock
        if (combined.Contains("error acquiring the state lock") ||
            combined.Contains("state lock") ||
            combined.Contains("lockid"))
            return "O state do Terraform está bloqueado por outro processo. Use 'terraform force-unlock' se necessário.";

        // Backend não inicializado
        if (combined.Contains("has not been initialized") ||
            combined.Contains("backend initialization"))
            return "Backend não inicializado. Execute 'terraform init' antes de prosseguir.";

        // Arquivos .tf ausentes / diretório errado
        if (combined.Contains("no terraform files") ||
            combined.Contains("no configuration files"))
            return "Nenhum arquivo .tf encontrado no diretório. Verifique o caminho do projeto.";

        // Plugin/provider não encontrado
        if (combined.Contains("could not find plugin") ||
            combined.Contains("provider registry") ||
            combined.Contains("failed to query available provider packages"))
            return "Provider não encontrado. Execute 'terraform init' para baixar os providers necessários.";

        // Permissão negada
        if (combined.Contains("accessdenied") ||
            combined.Contains("unauthorized") ||
            combined.Contains("forbidden"))
            return "Permissão negada. O usuário AWS não possui as permissões necessárias para esta operação.";

        // State inconsistente
        if (combined.Contains("inconsistent result after apply"))
            return "Inconsistência no state detectada após o apply. Verifique os recursos manualmente.";

        // Erro de HCL / sintaxe
        if (combined.Contains("argument or block definition required") ||
            combined.Contains("invalid expression") ||
            combined.Contains("syntax error"))
            return "Erro de sintaxe no código Terraform. Execute 'terraform validate' para detalhes.";

        // Primeiro erro parseado
        if (parsedErrors.Count > 0)
            return parsedErrors[0].Length > 200
                ? parsedErrors[0][..200] + "…"
                : parsedErrors[0];

        return $"terraform exited with code {exitCode}. Verifique o output para detalhes.";
    }

    private static bool IsNotFoundError(Win32Exception ex) =>
        ex.NativeErrorCode is 2      // ERROR_FILE_NOT_FOUND
                           or 3      // ERROR_PATH_NOT_FOUND
                           or 0x7F   // ERROR_PROC_NOT_FOUND
                           or 0x2E4; // ERROR_EXE_CANNOT_RUN

    private static bool ContainsAny(string text, params string[] keywords)
    {
        foreach (var k in keywords)
            if (text.Contains(k, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
}
