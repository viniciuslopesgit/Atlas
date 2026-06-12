using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform.Hcl;

/// <summary>
/// Funde conteúdo HCL gerado num ficheiro existente preservando tudo o que está
/// fora das marcas <c># ATLAS-MANAGED-START … # ATLAS-MANAGED-END</c>.
/// <para>
/// Regras de fusão:
/// <list type="bullet">
///   <item>Bloco existente com chave igual ao bloco novo → substituído pelo novo.</item>
///   <item>Bloco existente sem correspondência no novo conteúdo → preservado intacto.</item>
///   <item>Novo bloco sem correspondência no ficheiro existente → acrescentado no fim.</item>
///   <item>Conteúdo fora de qualquer bloco gerido → sempre preservado.</item>
/// </list>
/// </para>
/// </summary>
public static class HclMergeEngine
{
    // ── Constantes públicas (usadas também nos templates) ──────────────────
    public const string MarkerStart = "# ATLAS-MANAGED-START";
    public const string MarkerEnd   = "# ATLAS-MANAGED-END";

    // Captura: (marcador início) (chave) (corpo) (marcador fim com mesma chave)
    // Usa backreference \2 para garantir que o END tem a mesma chave que o START.
    private static readonly Regex BlockRegex = new(
        @"(# ATLAS-MANAGED-START ([^\r\n]+?)\r?\n)([\s\S]*?)(# ATLAS-MANAGED-END \2)",
        RegexOptions.Compiled | RegexOptions.Multiline);

    // ── API pública ────────────────────────────────────────────────────────

    /// <summary>
    /// Funde <paramref name="newContent"/> em <paramref name="existingContent"/>.
    /// </summary>
    public static string Merge(string existingContent, string newContent)
    {
        // Extrai blocos geridos do novo conteúdo (key → bloco completo renderizado)
        var newBlocks = ExtractBlocks(newContent)
            .ToDictionary(b => b.Key, b => b.FullBlock, StringComparer.Ordinal);

        var existingBlocks = ExtractBlocks(existingContent);
        var placedKeys     = new HashSet<string>(StringComparer.Ordinal);

        var result    = new StringBuilder(existingContent.Length + newContent.Length);
        int lastIndex = 0;

        // Percorre o ficheiro existente mantendo segmentos não-geridos e
        // substituindo blocos geridos com as versões novas (quando disponíveis).
        foreach (var existing in existingBlocks.OrderBy(b => b.StartIndex))
        {
            // Conteúdo antes deste bloco
            result.Append(existingContent, lastIndex, existing.StartIndex - lastIndex);

            if (newBlocks.TryGetValue(existing.Key, out var newBlock))
            {
                result.Append(newBlock);
                placedKeys.Add(existing.Key);
            }
            else
            {
                // Bloco não regenerado → mantém o original
                result.Append(existing.FullBlock);
            }

            lastIndex = existing.EndIndex;
        }

        // Resto do ficheiro após o último bloco
        result.Append(existingContent, lastIndex, existingContent.Length - lastIndex);

        // Acrescenta blocos novos que não existiam no ficheiro
        foreach (var (_, block) in newBlocks.Where(kv => !placedKeys.Contains(kv.Key)))
        {
            // Garante uma linha em branco de separação
            var currentEnd = result.ToString().TrimEnd();
            result.Clear();
            result.Append(currentEnd);
            result.AppendLine();
            result.AppendLine();
            result.Append(block);
        }

        return result.ToString();
    }

    /// <summary>Extrai as chaves de todos os blocos ATLAS-MANAGED presentes em <paramref name="content"/>.</summary>
    public static IReadOnlyList<string> ExtractKeys(string content) =>
        ExtractBlocks(content).Select(b => b.Key).ToList();

    /// <summary>Verifica se <paramref name="content"/> contém pelo menos um bloco ATLAS-MANAGED.</summary>
    public static bool HasManagedBlocks(string content) =>
        BlockRegex.IsMatch(content);

    // ── Implementação interna ──────────────────────────────────────────────

    private sealed record ManagedBlock(
        string Key,
        string FullBlock,
        int    StartIndex,
        int    EndIndex);

    private static IReadOnlyList<ManagedBlock> ExtractBlocks(string content)
    {
        var blocks = new List<ManagedBlock>();
        foreach (Match m in BlockRegex.Matches(content))
        {
            blocks.Add(new ManagedBlock(
                Key:        m.Groups[2].Value.Trim(),
                FullBlock:  m.Value,
                StartIndex: m.Index,
                EndIndex:   m.Index + m.Length));
        }
        return blocks;
    }
}
