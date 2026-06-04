using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;
using System.Collections.ObjectModel;

namespace Atlas.ViewModels;

public partial class ContactViewModel : ObservableObject
{
    // "contact.viniciuslopes@gmail.com" XOR 0x5A
    private static readonly byte[] _ea =
    [
        0x39,0x35,0x34,0x2E,0x3B,0x39,0x2E,0x74,
        0x2C,0x33,0x34,0x33,0x39,0x33,0x2F,0x29,
        0x36,0x35,0x2A,0x3F,0x29,0x1A,0x3D,0x37,
        0x3B,0x33,0x36,0x74,0x39,0x35,0x37
    ];

    // "bnjcyqxqejzpaocn" XOR 0x5A  (app password, spaces stripped)
    private static readonly byte[] _pa =
    [
        0x38,0x34,0x30,0x39,0x23,0x2B,0x22,0x2B,
        0x3F,0x30,0x20,0x2A,0x3B,0x35,0x39,0x34
    ];

    private static string Dx(byte[] src) => new(src.Select(b => (char)(b ^ 0x5A)).ToArray());

    public ObservableCollection<string> FeedbackTypes { get; } =
    [
        "Bug Report",
        "Suggestion",
        "Feature Request",
        "Other"
    ];

    [ObservableProperty] private string _selectedType = "Bug Report";
    [ObservableProperty] private string _subject      = string.Empty;
    [ObservableProperty] private string _description  = string.Empty;
    [ObservableProperty] private string _statusMessage = string.Empty;
    [ObservableProperty] private bool   _isSent;
    [ObservableProperty] private bool   _hasError;

    [RelayCommand]
    private async Task SendAsync()
    {
        if (string.IsNullOrWhiteSpace(Subject))
        {
            StatusMessage = "Please fill in the subject.";
            HasError = true;
            return;
        }
        if (string.IsNullOrWhiteSpace(Description))
        {
            StatusMessage = "Please fill in the description.";
            HasError = true;
            return;
        }

        HasError = false;
        StatusMessage = string.Empty;

        try
        {
            var addr = Dx(_ea);
            var pass = Dx(_pa);

            var msg = new MimeMessage();
            msg.From.Add(new MailboxAddress("Atlas Feedback", addr));
            msg.To.Add(new MailboxAddress(string.Empty, addr));
            msg.Subject = $"[Atlas {MainViewModel.AppVersion}] [{SelectedType}] {Subject}";
            msg.Body = new TextPart("plain")
            {
                Text = $"Type: {SelectedType}\n\nDescription:\n{Description}\n\n---\nAtlas {MainViewModel.AppVersion}"
            };

            using var smtp = new SmtpClient();
            await smtp.ConnectAsync("smtp.gmail.com", 587, SecureSocketOptions.StartTls);
            await smtp.AuthenticateAsync(addr, pass);
            await smtp.SendAsync(msg);
            await smtp.DisconnectAsync(true);

            IsSent = true;
            StatusMessage = "Feedback sent successfully. Thank you!";
            Subject     = string.Empty;
            Description = string.Empty;
        }
        catch (Exception ex)
        {
            StatusMessage = $"Failed to send: {ex.Message}";
            HasError = true;
        }
    }

    [RelayCommand]
    private void Reset()
    {
        IsSent        = false;
        HasError      = false;
        StatusMessage = string.Empty;
        Subject       = string.Empty;
        Description   = string.Empty;
        SelectedType  = "Bug Report";
    }
}
