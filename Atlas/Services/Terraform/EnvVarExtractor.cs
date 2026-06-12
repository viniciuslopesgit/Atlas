using Atlas.Models;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform;

/// <summary>
/// Two-pass extractor/replacer for hardcoded environment variable values in Terraform HCL files.
///
/// Pass 1 — collect: scans all .tf files for <c>environment { variables = { KEY = "value" } }</c>
///          blocks, recording each occurrence.
/// Pass 2 — replace: rewrites each affected file, substituting literal values with
///          <c>var.tf_var_name</c> references, then generates <c>variables.tf</c> and
///          <c>terraform.tfvars</c>.
/// </summary>
internal static class EnvVarExtractor
{
    private sealed record Occurrence(
        string EnvKey, string Value,
        string ResourceType, string ResourceName,
        string SourceFile);

    // ── Public API ────────────────────────────────────────────────────────────

    /// <summary>
    /// Scans all <c>*.tf</c> files under <paramref name="projectPath"/>, extracts hardcoded
    /// env-var values, replaces them with <c>var.*</c> references, and writes
    /// <c>variables.tf</c> + <c>terraform.tfvars</c>.
    /// </summary>
    public static async Task<IReadOnlyList<StackEnvVar>> ExtractAndReplaceAsync(string projectPath)
    {
        var tfFiles = Directory.GetFiles(projectPath, "*.tf", SearchOption.TopDirectoryOnly)
            .Where(f => Path.GetFileName(f) is not ("variables.tf" or "terraform.tfvars"))
            .ToList();

        // Pass 1: collect all occurrences without modifying anything
        var allOccurrences = new List<Occurrence>();
        foreach (var file in tfFiles)
        {
            var content = await File.ReadAllTextAsync(file, Encoding.UTF8);
            allOccurrences.AddRange(CollectOccurrences(content, Path.GetFileName(file)));
        }

        if (allOccurrences.Count == 0) return [];

        // Build deduplication: (envKey, value) → tf_var_name
        var varNameMap = BuildVarNameMap(allOccurrences);

        // Pass 2: replace hardcoded values in each file
        foreach (var file in tfFiles)
        {
            var content = await File.ReadAllTextAsync(file, Encoding.UTF8);
            var replaced = ReplaceInContent(content, varNameMap);
            if (replaced != content)
                await File.WriteAllTextAsync(file, replaced, Encoding.UTF8);
        }

        // Build final list of unique StackEnvVar objects
        var finalVars = allOccurrences
            .GroupBy(o => (o.EnvKey, o.Value))
            .Select(g =>
            {
                var first = g.First();
                return new StackEnvVar
                {
                    TfVarName    = varNameMap[(first.EnvKey, first.Value)],
                    EnvKey       = first.EnvKey,
                    Value        = first.Value,
                    ResourceType = first.ResourceType,
                    ResourceName = first.ResourceName,
                    SourceFile   = first.SourceFile,
                };
            })
            .ToList();

        // Write variables.tf only (no sensitive values on disk)
        await WriteVariablesTfAsyncCore(projectPath, finalVars);

        return finalVars;
    }

    /// <summary>
    /// Rewrites <c>variables.tf</c> with declarations for all current vars.
    /// Does NOT write sensitive values — use <see cref="IStackEnvVarRepository"/> for that.
    /// </summary>
    public static Task WriteVariablesTfAsync(string projectPath, IEnumerable<StackEnvVar> vars) =>
        WriteVariablesTfAsyncCore(projectPath, vars);

    // ── Pass 1: collect ───────────────────────────────────────────────────────

    private static readonly Regex ResourceStartRx = new(
        @"^resource\s+""([^""]+)""\s+""([^""]+)""", RegexOptions.Compiled);

    // Matches: KEY = "value" (any characters inside quotes, excluding nested quotes)
    private static readonly Regex EnvVarRx = new(
        "^([\\w]+)\\s*=\\s*\"([^\"]*)\"\\s*$", RegexOptions.Compiled);

    private static List<Occurrence> CollectOccurrences(string content, string fileName)
    {
        var results  = new List<Occurrence>();
        var lines    = content.Split('\n');

        string? resType = null, resName = null;
        int  depth     = 0;
        bool inEnv     = false;
        bool inVars    = false;

        foreach (var rawLine in lines)
        {
            var t   = rawLine.TrimStart();
            int net = CountBraces(rawLine);

            int prevDepth = depth;
            depth += net;
            if (depth < 0) depth = 0;

            // ── Brace-close transitions ───────────────────────────────────────
            if (net < 0)
            {
                if (inVars  && depth < 3) inVars  = false;
                if (inEnv   && depth < 2) inEnv   = false;
                if (depth  == 0) { resType = resName = null; }
                continue;
            }

            // ── No brace change — look for env var at depth 3 ────────────────
            if (net == 0)
            {
                if (depth == 3 && inVars)
                {
                    var m = EnvVarRx.Match(t);
                    if (m.Success)
                    {
                        string key   = m.Groups[1].Value;
                        string value = m.Groups[2].Value;
                        // Skip values that are already variable references or empty/null
                        if (!string.IsNullOrWhiteSpace(value) && !value.StartsWith("var."))
                            results.Add(new(key, value, resType!, resName!, fileName));
                    }
                }
                continue;
            }

            // ── Brace opens ───────────────────────────────────────────────────
            switch (prevDepth)
            {
                case 0:
                    // Entering a resource block
                    var rm = ResourceStartRx.Match(t);
                    if (rm.Success) { resType = rm.Groups[1].Value; resName = rm.Groups[2].Value; }
                    break;

                case 1:
                    // Entering a sub-block inside a resource (look for "environment")
                    if (!inEnv && t.TrimEnd().TrimEnd('{').Trim() == "environment")
                        inEnv = true;
                    break;

                case 2:
                    // Entering a sub-block inside environment (look for "variables =")
                    if (inEnv && !inVars && t.StartsWith("variables") && t.Contains('='))
                        inVars = true;
                    break;
            }
        }

        return results;
    }

    // ── Deduplication ─────────────────────────────────────────────────────────

    /// <summary>
    /// Assigns a unique Terraform variable name to each (envKey, value) combination.
    /// If the same key appears with different values across resources, the variable is
    /// prefixed with the resource name to avoid collisions.
    /// </summary>
    private static Dictionary<(string envKey, string value), string> BuildVarNameMap(
        IReadOnlyList<Occurrence> occurrences)
    {
        var map = new Dictionary<(string, string), string>();

        // Group by env key
        var byKey = occurrences.GroupBy(o => o.EnvKey);

        foreach (var keyGroup in byKey)
        {
            var distinctValues = keyGroup.Select(o => o.Value).Distinct().ToList();

            if (distinctValues.Count == 1)
            {
                // Same value across all resources → single shared variable
                map[(keyGroup.Key, distinctValues[0])] = ToTfName(keyGroup.Key);
            }
            else
            {
                // Different values → prefix with resource name to disambiguate
                foreach (var occ in keyGroup)
                {
                    var key = (occ.EnvKey, occ.Value);
                    if (!map.ContainsKey(key))
                        map[key] = ToTfName($"{occ.ResourceName}_{occ.EnvKey}");
                }
            }
        }

        return map;
    }

    // ── Pass 2: replace ───────────────────────────────────────────────────────

    private static string ReplaceInContent(
        string content,
        Dictionary<(string envKey, string value), string> varNameMap)
    {
        var lines   = content.Split('\n');
        var output  = new List<string>(lines.Length);

        string? resName = null;
        int  depth     = 0;
        bool inEnv     = false;
        bool inVars    = false;

        foreach (var rawLine in lines)
        {
            var t   = rawLine.TrimStart();
            int net = CountBraces(rawLine);

            int prevDepth = depth;
            depth += net;
            if (depth < 0) depth = 0;

            if (net < 0)
            {
                if (inVars  && depth < 3) inVars  = false;
                if (inEnv   && depth < 2) inEnv   = false;
                if (depth  == 0) resName = null;
                output.Add(rawLine);
                continue;
            }

            if (net == 0)
            {
                if (depth == 3 && inVars && resName is not null)
                {
                    var m = EnvVarRx.Match(t);
                    if (m.Success)
                    {
                        string key   = m.Groups[1].Value;
                        string value = m.Groups[2].Value;
                        if (!string.IsNullOrWhiteSpace(value) && !value.StartsWith("var.") &&
                            varNameMap.TryGetValue((key, value), out var tfName))
                        {
                            // Preserve indentation, replace the RHS: KEY = "value" → KEY = var.name
                            int eqIdx = rawLine.IndexOf('=');
                            output.Add(eqIdx >= 0
                                ? rawLine[..eqIdx] + "= var." + tfName
                                : rawLine);
                            continue;
                        }
                    }
                }
                output.Add(rawLine);
                continue;
            }

            // Brace opens
            switch (prevDepth)
            {
                case 0:
                    var rm = ResourceStartRx.Match(t);
                    if (rm.Success) resName = rm.Groups[2].Value;
                    break;
                case 1:
                    if (!inEnv && t.TrimEnd().TrimEnd('{').Trim() == "environment")
                        inEnv = true;
                    break;
                case 2:
                    if (inEnv && !inVars && t.StartsWith("variables") && t.Contains('='))
                        inVars = true;
                    break;
            }

            output.Add(rawLine);
        }

        return string.Join('\n', output);
    }

    // ── File writers ──────────────────────────────────────────────────────────

    private static async Task WriteVariablesTfAsyncCore(string projectPath, IEnumerable<StackEnvVar> vars)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Generated by Atlas — do not edit manually.");
        sb.AppendLine("# Environment variables extracted from imported Terraform resources.");
        sb.AppendLine("# Provide values in terraform.tfvars (keep that file private/gitignored).");
        sb.AppendLine();

        foreach (var v in vars.OrderBy(x => x.TfVarName))
        {
            sb.AppendLine($"variable \"{v.TfVarName}\" {{");
            sb.AppendLine($"  description = \"{v.EnvKey} for {v.ResourceType}.{v.ResourceName}\"");
            sb.AppendLine( "  type        = string");
            sb.AppendLine( "  sensitive   = true");
            sb.AppendLine( "  default     = null");
            sb.AppendLine( "}");
            sb.AppendLine();
        }

        await File.WriteAllTextAsync(
            Path.Combine(projectPath, "variables.tf"), sb.ToString(), Encoding.UTF8);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string ToTfName(string name) =>
        Regex.Replace(name.ToLowerInvariant(), @"[^a-z0-9]+", "_").Trim('_');

    private static string EscapeHcl(string value) =>
        value.Replace("\\", "\\\\").Replace("\"", "\\\"");

    private static int CountBraces(string line)
    {
        int  count    = 0;
        bool inString = false;
        foreach (char c in line)
        {
            if (c == '"') inString = !inString;
            if (inString) continue;
            if      (c == '{') count++;
            else if (c == '}') count--;
        }
        return count;
    }
}
