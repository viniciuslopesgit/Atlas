namespace Atlas.Models;

public class StackEnvVar
{
    public string Id           { get; set; } = Guid.NewGuid().ToString();
    public string TfVarName   { get; set; } = "";   // terraform variable name  (e.g. "openai_api_key")
    public string EnvKey      { get; set; } = "";   // original env var key     (e.g. "OPENAI_API_KEY")
    public string Value       { get; set; } = "";   // current value (source of truth; also in tfvars)
    public string ResourceType { get; set; } = "";  // e.g. "aws_lambda_function"
    public string ResourceName { get; set; } = "";  // e.g. "speechtotext"
    public string SourceFile  { get; set; } = "";   // e.g. "generated_resources.tf"
}
