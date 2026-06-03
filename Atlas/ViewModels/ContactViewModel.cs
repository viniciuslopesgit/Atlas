using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.Collections.ObjectModel;
using System.Diagnostics;

namespace Atlas.ViewModels;

public partial class ContactViewModel : ObservableObject
{
    // "contact.viniciuslopes@gmail.com" XOR 0x5A — not stored in plain text
    private static readonly byte[] _e =
    [
        0x39,0x35,0x34,0x2E,0x3B,0x39,0x2E,0x74,
        0x2C,0x33,0x34,0x33,0x39,0x33,0x2F,0x29,
        0x36,0x35,0x2A,0x3F,0x29,0x1A,0x3D,0x37,
        0x3B,0x33,0x36,0x74,0x39,0x35,0x37
    ];
    private static string R() => new(_e.Select(b => (char)(b ^ 0x5A)).ToArray());

    public ObservableCollection<string> FeedbackTypes { get; } =
    [
        "Bug Report",
        "Suggestion",
        "Feature Request",
        "Other"
    ];

    [ObservableProperty] private string _selectedType = "Bug Report";
    [ObservableProperty] private string _subject = string.Empty;
    [ObservableProperty] private string _description = string.Empty;
    [ObservableProperty] private string _statusMessage = string.Empty;
    [ObservableProperty] private bool _isSent;
    [ObservableProperty] private bool _hasError;

    [RelayCommand]
    private void Send()
    {
        if (string.IsNullOrWhiteSpace(Subject))
        {
            StatusMessage = "Please enter a subject.";
            HasError = true;
            return;
        }
        if (string.IsNullOrWhiteSpace(Description))
        {
            StatusMessage = "Please enter a description.";
            HasError = true;
            return;
        }

        HasError = false;

        var subject = Uri.EscapeDataString($"[Atlas {MainViewModel.AppVersion}] [{SelectedType}] {Subject}");
        var body = Uri.EscapeDataString(
            $"Type: {SelectedType}\n\nDescription:\n{Description}\n\n---\nAtlas {MainViewModel.AppVersion}");

        var mailto = $"mailto:{R()}?subject={subject}&body={body}";

        try
        {
            Process.Start(new ProcessStartInfo(mailto) { UseShellExecute = true });
            IsSent = true;
            StatusMessage = "Your email client has been opened. Thank you for the feedback!";
            Subject = string.Empty;
            Description = string.Empty;
        }
        catch
        {
            StatusMessage = "Could not open your email client. Please send your feedback manually.";
            HasError = true;
        }
    }

    [RelayCommand]
    private void Reset()
    {
        IsSent = false;
        HasError = false;
        StatusMessage = string.Empty;
        Subject = string.Empty;
        Description = string.Empty;
        SelectedType = "Bug Report";
    }
}
