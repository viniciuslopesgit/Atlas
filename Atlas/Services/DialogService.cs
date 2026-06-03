using Atlas.Views;
using System.Windows;

namespace Atlas.Services;

public sealed class DialogService : IDialogService
{
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
}
