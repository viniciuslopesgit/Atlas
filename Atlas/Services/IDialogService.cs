using Atlas.Services.Terraform.Import;

namespace Atlas.Services;

public enum DialogKind { Default, Danger, Info }

public record AddAccountResult(
    bool    Added,
    string? NextAction,
    string? StackName,
    string? ProjectPath);

public record CreateStackResult(string StackName, string ProjectPath);

public interface IDialogService
{
    bool             Confirm(string title, string message, DialogKind kind = DialogKind.Default);
    AddAccountResult ShowAddAccountDialog();
    string?          ShowFolderPicker(string title);

    /// <summary>
    /// Shows the discovered-resources checkbox screen (grouped by category).
    /// Returns the resources the user kept selected, or null when cancelled.
    /// </summary>
    IReadOnlyList<DiscoveredResource>? ShowImportSelectionDialog(
        IReadOnlyList<DiscoveredResource> discovered);

    /// <summary>
    /// Asks for a new stack name + destination folder.
    /// Returns null when cancelled.
    /// </summary>
    CreateStackResult? ShowCreateStackDialog();

    /// <summary>
    /// Opens the inline S3 text/code editor. <paramref name="onSave"/> is called with the
    /// edited content when the user clicks Save; return null on success or an error message
    /// on failure (the dialog stays open and displays the error).
    /// Returns true when the file was saved successfully, false when the user cancelled.
    /// </summary>
    bool ShowS3FileEditor(string fileKey, string content, Func<string, Task<string?>> onSave);
}
