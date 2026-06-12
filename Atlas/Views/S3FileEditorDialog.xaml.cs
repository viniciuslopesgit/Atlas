using Microsoft.Web.WebView2.Core;
using System.Text.Json;
using System.Windows;

namespace Atlas.Views;

public partial class S3FileEditorDialog : Window
{
    // True after a successful save — read by DialogService after ShowDialog() returns.
    public bool Saved { get; private set; }

    private readonly string _fileKey;
    private readonly string _initialContent;
    private readonly string _language;
    private readonly Func<string, Task<string?>> _onSave;

    // Latest editor content — updated on every Monaco change message (debounced 400 ms).
    private string _cachedContent;
    private bool   _isSaving;

    public S3FileEditorDialog(string fileKey, string content, Func<string, Task<string?>> onSave)
    {
        InitializeComponent();

        _fileKey        = fileKey;
        _initialContent = content;
        _cachedContent  = content;
        _language       = GetMonacoLanguage(fileKey);
        _onSave         = onSave;

        var fileName = System.IO.Path.GetFileName(fileKey);
        var folder   = fileKey.Contains('/')
            ? fileKey[..fileKey.LastIndexOf('/')]
            : string.Empty;

        FileNameText.Text = fileName;
        FilePathText.Text = string.IsNullOrEmpty(folder) ? string.Empty : $"  {folder}";
        LanguageText.Text = _language;

        Loaded += OnLoaded;
    }

    // ── Window chrome ─────────────────────────────────────────────────

    private void Window_StateChanged(object sender, EventArgs e)
    {
        if (MaxRestoreButton.Template.FindName("Icon", MaxRestoreButton)
            is System.Windows.Controls.TextBlock icon)
            icon.Text = WindowState == WindowState.Maximized ? "❐" : "□";

        MaxRestoreButton.ToolTip = WindowState == WindowState.Maximized ? "Restore" : "Maximize";

        var m = WindowState == WindowState.Maximized ? new Thickness(6) : new Thickness(0);
        ((System.Windows.Controls.Grid)Content).Margin = m;
    }

    private void Minimize_Click(object sender, RoutedEventArgs e)
        => WindowState = WindowState.Minimized;

    private void MaxRestore_Click(object sender, RoutedEventArgs e)
        => WindowState = WindowState == WindowState.Maximized
           ? WindowState.Normal
           : WindowState.Maximized;

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    // ── WebView2 init ─────────────────────────────────────────────────

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await EditorWebView.EnsureCoreWebView2Async();
            EditorWebView.DefaultBackgroundColor = System.Drawing.Color.FromArgb(0x1e, 0x1e, 0x1e);
            EditorWebView.CoreWebView2.WebMessageReceived += OnWebMessage;
            EditorWebView.NavigateToString(BuildMonacoHtml());
        }
        catch (Exception ex)
        {
            SetStatus($"Editor failed to load: {ex.Message}", error: true);
        }
    }

    private string BuildMonacoHtml()
    {
        var lang    = JsonSerializer.Serialize(_language);
        var content = JsonSerializer.Serialize(_initialContent);
        var cdn     = "https://cdn.jsdelivr.net/npm/monaco-editor@0.50.0/min/vs";

        return $$$"""
            <!DOCTYPE html>
            <html><head><meta charset="UTF-8">
            <style>
              * { margin:0; padding:0; box-sizing:border-box; }
              html, body, #editor { width:100%; height:100%; background:#1e1e1e; overflow:hidden; }
            </style>
            </head>
            <body>
              <div id="editor"></div>
              <script src="{{{cdn}}}/loader.min.js"></script>
              <script>
                require.config({ paths: { vs: '{{{cdn}}}' } });
                require(['vs/editor/editor.main'], function() {
                  window._editor = monaco.editor.create(document.getElementById('editor'), {
                    value:    {{{content}}},
                    language: {{{lang}}},
                    theme: 'vs-dark',
                    fontSize: 13,
                    fontFamily: "'Consolas','Courier New',monospace",
                    lineHeight: 20,
                    minimap: { enabled: false },
                    scrollBeyondLastLine: false,
                    automaticLayout: true,
                    lineNumbers: 'on',
                    glyphMargin: false,
                    folding: true,
                    wordWrap: 'off',
                    renderLineHighlight: 'line',
                    tabSize: 2,
                    insertSpaces: true,
                    scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10 }
                  });

                  window.chrome.webview.postMessage({
                    type: 'ready',
                    lines: window._editor.getModel().getLineCount()
                  });

                  var _debounce = null;
                  window._editor.onDidChangeModelContent(function() {
                    clearTimeout(_debounce);
                    _debounce = setTimeout(function() {
                      window.chrome.webview.postMessage({
                        type:    'change',
                        content: window._editor.getValue(),
                        lines:   window._editor.getModel().getLineCount()
                      });
                    }, 400);
                  });

                  window._editor.onDidChangeCursorPosition(function(ev) {
                    window.chrome.webview.postMessage({
                      type: 'cursor',
                      line: ev.position.lineNumber,
                      col:  ev.position.column
                    });
                  });

                  window._editor.addCommand(
                    monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
                    function() {
                      window.chrome.webview.postMessage({ type: 'save' });
                    }
                  );
                });
              </script>
            </body></html>
            """;
    }

    // ── WebView2 ↔ WPF messages ───────────────────────────────────────

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string? type    = null;
        string? content = null;
        int     lines   = -1;
        int     line    = -1;
        int     col     = -1;

        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement;
            type = root.GetProperty("type").GetString();

            if (root.TryGetProperty("content", out var cEl)) content = cEl.GetString();
            if (root.TryGetProperty("lines",   out var lEl)) lines   = lEl.GetInt32();
            if (root.TryGetProperty("line",    out var liEl)) line    = liEl.GetInt32();
            if (root.TryGetProperty("col",     out var coEl)) col     = coEl.GetInt32();
        }
        catch { return; }

        // Update the content cache before switching to the UI thread.
        if (content is not null)
            _cachedContent = content;

        Dispatcher.Invoke(() =>
        {
            switch (type)
            {
                case "ready":
                    SaveButton.IsEnabled = true;
                    SetStatus(string.Empty);
                    if (lines >= 0) LineCountText.Text = $"{lines:N0} lines";
                    break;

                case "change":
                    ModifiedIndicator.Text = "● Modified";
                    if (lines >= 0) LineCountText.Text = $"{lines:N0} lines";
                    break;

                case "cursor":
                    if (line >= 0 && col >= 0)
                        CursorPositionText.Text = $"Ln {line}, Col {col}";
                    break;

                case "save":
                    _ = PerformSaveAsync(closeOnSuccess: false);
                    break;
            }
        });
    }

    // ── Save logic ────────────────────────────────────────────────────

    private async void Save_Click(object sender, RoutedEventArgs e)
        => await PerformSaveAsync(closeOnSuccess: true);

    private async Task PerformSaveAsync(bool closeOnSuccess)
    {
        if (_isSaving) return;
        _isSaving = true;

        SaveButton.IsEnabled = false;
        SetStatus("Saving…");

        // Flush latest content from Monaco, bypassing the debounce window.
        var contentToSave = _cachedContent;
        try
        {
            var raw     = await EditorWebView.ExecuteScriptAsync(
                              "window._editor ? window._editor.getValue() : null");
            var flushed = JsonSerializer.Deserialize<string>(raw);
            if (flushed is not null) contentToSave = flushed;
        }
        catch { /* fall back to _cachedContent */ }

        try
        {
            var error = await _onSave(contentToSave);

            if (error == null)
            {
                Saved = true;
                if (closeOnSuccess)
                {
                    Close();
                }
                else
                {
                    _cachedContent         = contentToSave;
                    ModifiedIndicator.Text = string.Empty;
                    SetStatus("✓ Saved");
                    SaveButton.IsEnabled   = true;
                    _isSaving              = false;
                }
            }
            else
            {
                SetStatus($"Could not save: {error}", error: true);
                SaveButton.IsEnabled = true;
                _isSaving = false;
            }
        }
        catch (Exception ex)
        {
            SetStatus($"Could not save: {ex.Message}", error: true);
            SaveButton.IsEnabled = true;
            _isSaving = false;
        }
    }

    private void SetStatus(string message, bool error = false)
    {
        if (!string.IsNullOrEmpty(message))
        {
            CursorPositionText.Text      = message;
            CursorPositionText.Foreground = error
                ? System.Windows.Media.Brushes.OrangeRed
                : System.Windows.Media.Brushes.White;
        }
        else
        {
            CursorPositionText.Text      = string.Empty;
            CursorPositionText.Foreground = System.Windows.Media.Brushes.White;
        }
    }

    // ── Language detection ────────────────────────────────────────────

    private static string GetMonacoLanguage(string key)
    {
        var name = System.IO.Path.GetFileName(key);
        var ext  = System.IO.Path.GetExtension(key).ToLowerInvariant();

        return ext switch
        {
            ".json"                        => "json",
            ".yaml" or ".yml"              => "yaml",
            ".xml"                         => "xml",
            ".html" or ".htm"              => "html",
            ".css"                         => "css",
            ".js" or ".jsx" or ".mjs"      => "javascript",
            ".ts" or ".tsx"                => "typescript",
            ".md" or ".markdown"           => "markdown",
            ".sh" or ".bash" or ".zsh"     => "shell",
            ".py"                          => "python",
            ".rb"                          => "ruby",
            ".php"                         => "php",
            ".go"                          => "go",
            ".java"                        => "java",
            ".cs"                          => "csharp",
            ".cpp" or ".cc" or ".cxx"      => "cpp",
            ".c" or ".h" or ".hpp"         => "cpp",
            ".rs"                          => "rust",
            ".sql"                         => "sql",
            ".tf" or ".tfvars" or ".hcl"   => "hcl",
            ".toml"                        => "toml",
            ".ini" or ".conf" or ".config" => "ini",
            ".env"                         => "ini",
            ".dockerfile"                  => "dockerfile",
            ".log"                         => "plaintext",
            _ when name.Equals("Dockerfile", StringComparison.OrdinalIgnoreCase) => "dockerfile",
            _ when name.Equals("Makefile",   StringComparison.OrdinalIgnoreCase) => "makefile",
            _ when name.StartsWith('.')    => "ini",
            _                              => "plaintext"
        };
    }
}
