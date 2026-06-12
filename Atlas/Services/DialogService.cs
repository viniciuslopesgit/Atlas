using Atlas.Services.Terraform.Import;
using Atlas.Views;
using System.Windows;

namespace Atlas.Services;

public sealed class DialogService : IDialogService
{
    private readonly IAccountService _accounts;

    public DialogService(IAccountService accounts)
    {
        _accounts = accounts;
    }

    public bool Confirm(string title, string message, DialogKind kind = DialogKind.Default)
    {
        // Split message from instance bullet list (separated by \n\n)
        var parts = message.Split("\n\n", 2);
        var body  = parts[0];
        var list  = parts.Length > 1 ? parts[1] : string.Empty;

        var dialog = new ConfirmDialog(title, body, list, kind)
        {
            Owner = Application.Current.MainWindow
        };

        dialog.ShowDialog();
        return dialog.Confirmed;
    }

    public AddAccountResult ShowAddAccountDialog()
    {
        var dialog = new AddAccountDialog(_accounts)
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        return new AddAccountResult(
            dialog.AccountAdded,
            dialog.NextAction,
            dialog.StackName,
            dialog.ProjectPath);
    }

    public string? ShowFolderPicker(string title)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog { Title = title };
        return picker.ShowDialog() == true ? picker.FolderName : null;
    }

    public IReadOnlyList<DiscoveredResource>? ShowImportSelectionDialog(
        IReadOnlyList<DiscoveredResource> discovered)
    {
        var dialog = new ImportSelectionDialog(discovered)
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        return dialog.SelectedResources;
    }

    public CreateStackResult? ShowCreateStackDialog()
    {
        var dialog = new CreateStackDialog
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        return dialog.StackName is { Length: > 0 } && dialog.ProjectPath is { Length: > 0 }
            ? new CreateStackResult(dialog.StackName, dialog.ProjectPath)
            : null;
    }

    public bool ShowS3FileEditor(string fileKey, string content, Func<string, Task<string?>> onSave)
    {
        var dialog = new S3FileEditorDialog(fileKey, content, onSave)
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        return dialog.Saved;
    }
}
