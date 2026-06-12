namespace Atlas.Services.Terraform.Hcl.Models;

/// <summary>Par chave-valor usado nas secções <c>tags = { ... }</c> do HCL gerado.</summary>
public sealed record HclTag(string Key, string Value);
