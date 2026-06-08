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

    public bool ShowAddAccountDialog()
    {
        var dialog = new AddAccountDialog(_accounts)
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        return dialog.AccountAdded;
    }

    public string? ShowFolderPicker(string title)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog { Title = title };
        return picker.ShowDialog() == true ? picker.FolderName : null;
    }
}
