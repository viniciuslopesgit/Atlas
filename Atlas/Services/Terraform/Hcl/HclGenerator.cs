using Atlas.Infrastructure.Logging;
using Atlas.Services.Terraform.Hcl.Models;
using Scriban;
using Scriban.Runtime;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform.Hcl;

public sealed class HclGenerator : ITerraformHclGenerator
{
    // Prefixo dos recursos embeddidos — deve corresponder a:
    //   <RootNamespace>Atlas</RootNamespace>  +  Templates\Terraform\
    private const string ResourcePrefix = "Atlas.Templates.Terraform.";
    private const string TemplateSuffix = ".tf.tpl";

    // Regex para converter PascalCase → snake_case (ex.: AmiId → ami_id)
    private static readonly Regex SnakeCaseRegex =
        new(@"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", RegexOptions.Compiled);

    // ── AvailableTemplates ────────────────────────────────────────────────

    public IReadOnlyList<string> AvailableTemplates =>
        Assembly.GetExecutingAssembly()
                .GetManifestResourceNames()
                .Where(n => n.StartsWith(ResourcePrefix, StringComparison.Ordinal)
                         && n.EndsWith(TemplateSuffix,   StringComparison.Ordinal))
                .Select(ResourceNameToTemplateName)
                .OrderBy(n => n)
                .ToList();

    // ── Método genérico ───────────────────────────────────────────────────

    public async Task<HclGenerationResult> GenerateAsync(
        HclGenerationRequest request,
        CancellationToken    ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.TemplateName))
            return HclGenerationResult.Fail("TemplateName não pode ser vazio.");

        try
        {
            // 1. Carrega e renderiza o template
            var raw      = await RenderTemplateAsync(request.TemplateName, request.Model, ct);
            var rendered = raw.TrimEnd() + Environment.NewLine;
            var keys     = HclMergeEngine.ExtractKeys(rendered);

            // 2. Sem caminho de saída → devolve apenas o conteúdo
            if (string.IsNullOrWhiteSpace(request.OutputPath))
                return HclGenerationResult.Ok(rendered, null, false, keys);

            // 3. Com caminho de saída → funde com o ficheiro existente (se houver)
            var outputPath = Path.GetFullPath(request.OutputPath);
            string final;

            if (File.Exists(outputPath))
            {
                var existing = await File.ReadAllTextAsync(outputPath, Encoding.UTF8, ct);

                if (!request.OverwriteManaged && HclMergeEngine.HasManagedBlocks(existing))
                {
                    // Modo de preservação: verifica se há blocos novos antes de fundir.
                    // BUG FIX: a chamada redundante a Merge antes desta verificação foi removida.
                    var existingKeys = HclMergeEngine.ExtractKeys(existing);
                    var newOnlyKeys  = keys.Except(existingKeys).ToList();
                    if (newOnlyKeys.Count == 0)
                    {
                        FileLogger.Info($"[HclGenerator] Nenhum bloco novo — ficheiro não alterado: {outputPath}");
                        return HclGenerationResult.Ok(existing, outputPath, false, keys);
                    }
                    final = HclMergeEngine.Merge(existing, rendered);
                }
                else
                {
                    final = HclMergeEngine.Merge(existing, rendered);
                }
            }
            else
            {
                // Ficheiro novo — cria directório se necessário
                var dir = Path.GetDirectoryName(outputPath);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);

                final = rendered;
            }

            await File.WriteAllTextAsync(outputPath, final, Encoding.UTF8, ct);
            FileLogger.Info($"[HclGenerator] Escrito: {outputPath}  ({keys.Count} blocos geridos)");
            return HclGenerationResult.Ok(final, outputPath, true, keys);
        }
        catch (OperationCanceledException)
        {
            return HclGenerationResult.Fail("Operação cancelada.");
        }
        catch (Exception ex)
        {
            FileLogger.Error($"[HclGenerator] Erro ao gerar '{request.TemplateName}'", ex);
            return HclGenerationResult.Fail(ex.Message);
        }
    }

    // ── Métodos tipados de conveniência ───────────────────────────────────

    public Task<HclGenerationResult> GenerateEc2InstanceAsync(
        Ec2InstanceHclModel model, string? outputPath = null, CancellationToken ct = default) =>
        GenerateAsync(new HclGenerationRequest
        {
            TemplateName = "ec2_instance",
            Model        = model,
            OutputPath   = outputPath,
        }, ct);

    public Task<HclGenerationResult> GenerateS3BucketAsync(
        S3BucketHclModel model, string? outputPath = null, CancellationToken ct = default) =>
        GenerateAsync(new HclGenerationRequest
        {
            TemplateName = "s3_bucket",
            Model        = model,
            OutputPath   = outputPath,
        }, ct);

    public Task<HclGenerationResult> GenerateSecurityGroupAsync(
        SecurityGroupHclModel model, string? outputPath = null, CancellationToken ct = default) =>
        GenerateAsync(new HclGenerationRequest
        {
            TemplateName = "security_group",
            Model        = model,
            OutputPath   = outputPath,
        }, ct);

    public Task<HclGenerationResult> GenerateIamRoleAsync(
        IamRoleHclModel model, string? outputPath = null, CancellationToken ct = default) =>
        GenerateAsync(new HclGenerationRequest
        {
            TemplateName = "iam_role",
            Model        = model,
            OutputPath   = outputPath,
        }, ct);

    // ── Módulos ───────────────────────────────────────────────────────────

    public async Task<IReadOnlyList<HclGenerationResult>> GenerateModuleAsync(
        string            moduleName,
        object            model,
        string            outputDir,
        CancellationToken ct = default)
    {
        var files  = new[] { "main", "variables", "outputs" };
        var results = new List<HclGenerationResult>();

        foreach (var file in files)
        {
            var templateName = $"modules/{moduleName}/{file}";

            // Pula silenciosamente se o template não existir
            if (!TemplateExists(templateName))
            {
                FileLogger.Warning($"[HclGenerator] Template de módulo não encontrado: {templateName}");
                continue;
            }

            var result = await GenerateAsync(new HclGenerationRequest
            {
                TemplateName = templateName,
                Model        = model,
                OutputPath   = Path.Combine(outputDir, $"{file}.tf"),
            }, ct);

            results.Add(result);
        }

        return results;
    }

    // ── Motor Scriban ─────────────────────────────────────────────────────

    private static async Task<string> RenderTemplateAsync(
        string templateName, object model, CancellationToken ct)
    {
        var templateSource = LoadEmbeddedTemplate(templateName);

        var template = Template.Parse(templateSource, templateName + TemplateSuffix);
        if (template.HasErrors)
        {
            var errors = string.Join("; ", template.Messages.Select(m => m.ToString()));
            throw new InvalidOperationException($"Erros na template '{templateName}': {errors}");
        }

        var scriptObj = new ScriptObject();
        scriptObj.Import(model, renamer: MemberRename);

        var context = new TemplateContext
        {
            MemberRenamer          = MemberRename,
            StrictVariables        = false,
            EnableRelaxedMemberAccess = true,
        };
        context.PushGlobal(scriptObj);

        ct.ThrowIfCancellationRequested();
        return await template.RenderAsync(context);
    }

    /// <summary>
    /// Renomeia membros .NET (PascalCase) para snake_case nos templates Scriban.
    /// Exemplo: <c>AmiId</c> → <c>ami_id</c>, <c>SecurityGroupIds</c> → <c>security_group_ids</c>.
    /// </summary>
    private static string MemberRename(MemberInfo member) =>
        SnakeCaseRegex.Replace(member.Name, "_").ToLowerInvariant();

    // ── Recursos embeddidos ───────────────────────────────────────────────

    private static string LoadEmbeddedTemplate(string templateName)
    {
        var resourceName = TemplateNameToResourceName(templateName);
        var assembly     = Assembly.GetExecutingAssembly();

        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new FileNotFoundException(
                $"Template embeddido não encontrado: '{resourceName}'. " +
                $"Templates disponíveis: {string.Join(", ", assembly.GetManifestResourceNames().Where(n => n.Contains("Templates")))}");

        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static bool TemplateExists(string templateName)
    {
        var resourceName = TemplateNameToResourceName(templateName);
        return Assembly.GetExecutingAssembly().GetManifestResourceNames().Contains(resourceName);
    }

    /// <summary>
    /// Converte nome do template para nome do recurso embeddido.
    /// <c>"modules/ec2/main"</c> → <c>"Atlas.Templates.Terraform.modules.ec2.main.tf.tpl"</c>
    /// </summary>
    private static string TemplateNameToResourceName(string templateName)
    {
        var normalized = templateName
            .Replace('/', '.')
            .Replace('\\', '.');
        return $"{ResourcePrefix}{normalized}{TemplateSuffix}";
    }

    /// <summary>
    /// Converte nome do recurso embeddido para nome do template.
    /// <c>"Atlas.Templates.Terraform.modules.ec2.main.tf.tpl"</c> → <c>"modules/ec2/main"</c>
    /// </summary>
    private static string ResourceNameToTemplateName(string resourceName)
    {
        var withoutPrefix = resourceName[ResourcePrefix.Length..];
        var withoutSuffix = withoutPrefix[..^TemplateSuffix.Length];

        // A extensão .tf faz parte do nome — remove o último segmento .tf antes de converter '.' → '/'
        // Ex.: "modules.ec2.main.tf" → remove ".tf" → "modules.ec2.main" → "modules/ec2/main"
        if (withoutSuffix.EndsWith(".tf", StringComparison.Ordinal))
            withoutSuffix = withoutSuffix[..^3];

        return withoutSuffix.Replace('.', '/');
    }
}
