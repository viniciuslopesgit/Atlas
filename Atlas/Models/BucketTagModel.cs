using CommunityToolkit.Mvvm.ComponentModel;

namespace Atlas.Models;

public partial class BucketTagModel : ObservableObject
{
    [ObservableProperty] private string _key   = string.Empty;
    [ObservableProperty] private string _value = string.Empty;
}
