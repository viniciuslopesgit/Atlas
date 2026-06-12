using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;

namespace Atlas.ViewModels;

public partial class StackEnvVarViewModel : ObservableObject
{
    private readonly StackEnvVar   _model;
    private readonly Func<Task>    _onSave;

    [ObservableProperty] private bool   _isValueVisible;
    [ObservableProperty] private bool   _isEditing;
    [ObservableProperty] private string _editValue = "";

    public StackEnvVarViewModel(StackEnvVar model, Func<Task> onSave)
    {
        _model  = model;
        _onSave = onSave;
    }

    // ── Display properties ────────────────────────────────────────────────────

    public string EnvKey       => _model.EnvKey;
    public string TfVarName    => _model.TfVarName;

    public string ResourceLabel =>
        $"{_model.ResourceType.Replace("aws_", "")}/{_model.ResourceName}";

    public string DisplayValue => IsValueVisible
        ? (_model.Value.Length > 64 ? _model.Value[..64] + "…" : _model.Value)
        : new string('●', Math.Min(_model.Value.Length, 24));

    // ── Commands ──────────────────────────────────────────────────────────────

    [RelayCommand]
    private void ToggleVisibility()
    {
        IsValueVisible = !IsValueVisible;
        OnPropertyChanged(nameof(DisplayValue));
    }

    [RelayCommand]
    private void StartEdit()
    {
        EditValue = _model.Value;
        IsEditing = true;
    }

    [RelayCommand]
    private async Task SaveEdit()
    {
        _model.Value = EditValue;
        IsEditing    = false;
        IsValueVisible = false;
        OnPropertyChanged(nameof(DisplayValue));
        await _onSave();
    }

    [RelayCommand]
    private void CancelEdit()
    {
        EditValue = "";
        IsEditing = false;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    internal StackEnvVar GetModel() => _model;

    /// <summary>Called by the host to push a value loaded from the secure store.</summary>
    internal void SetValue(string value)
    {
        _model.Value = value;
        OnPropertyChanged(nameof(DisplayValue));
    }
}
