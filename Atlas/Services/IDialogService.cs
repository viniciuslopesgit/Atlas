namespace Atlas.Services;

public enum DialogKind { Default, Danger, Info }

public interface IDialogService
{
    bool Confirm(string title, string message, DialogKind kind = DialogKind.Default);
}
