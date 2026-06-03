using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using System.Collections.ObjectModel;

namespace Atlas.ViewModels;

public partial class CommandPaletteViewModel : ObservableObject
{
    private IReadOnlyList<PaletteCommand> _allCommands = [];
    private int _cursorIndex = -1;

    [ObservableProperty] private bool _isOpen;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private PaletteCommand? _selectedCommand;

    public ObservableCollection<PaletteCommand> FilteredCommands { get; } = [];

    public void Initialize(IReadOnlyList<PaletteCommand> commands)
    {
        _allCommands = commands;
        RefreshFilter();
    }

    public void Open()
    {
        SearchText = string.Empty;
        RefreshFilter();
        IsOpen = true;
    }

    [RelayCommand]
    private void Close() => IsOpen = false;

    partial void OnSearchTextChanged(string value) => RefreshFilter();

    partial void OnSelectedCommandChanged(PaletteCommand? value)
    {
        // Keep cursor in sync when selection changes via mouse click
        if (value != null)
        {
            var idx = FilteredCommands.IndexOf(value);
            if (idx >= 0) _cursorIndex = idx;
        }
    }

    private void RefreshFilter()
    {
        FilteredCommands.Clear();
        var q = SearchText.Trim();
        IEnumerable<PaletteCommand> source = string.IsNullOrEmpty(q)
            ? _allCommands
            : _allCommands.Where(c => Matches(c, q));

        foreach (var cmd in source)
            FilteredCommands.Add(cmd);

        _cursorIndex = FilteredCommands.Count > 0 ? 0 : -1;
        SelectedCommand = _cursorIndex >= 0 ? FilteredCommands[_cursorIndex] : null;
    }

    private static bool Matches(PaletteCommand cmd, string q) =>
        cmd.Title.Contains(q, StringComparison.OrdinalIgnoreCase)    ||
        cmd.Category.Contains(q, StringComparison.OrdinalIgnoreCase) ||
        (cmd.Subtitle?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false) ||
        (cmd.Keywords?.Any(k => k.Contains(q, StringComparison.OrdinalIgnoreCase)) ?? false);

    [RelayCommand]
    private void ExecuteSelected()
    {
        if (SelectedCommand is null) return;
        var cmd = SelectedCommand;
        IsOpen = false;
        cmd.Execute();
    }

    public void MoveUp()
    {
        if (FilteredCommands.Count == 0) return;
        _cursorIndex = _cursorIndex <= 0 ? FilteredCommands.Count - 1 : _cursorIndex - 1;
        SelectedCommand = FilteredCommands[_cursorIndex];
    }

    public void MoveDown()
    {
        if (FilteredCommands.Count == 0) return;
        _cursorIndex = _cursorIndex >= FilteredCommands.Count - 1 ? 0 : _cursorIndex + 1;
        SelectedCommand = FilteredCommands[_cursorIndex];
    }
}
