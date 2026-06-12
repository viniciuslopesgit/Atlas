using Atlas.Services.Terraform.Import;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;

namespace Atlas.Views;

/// <summary>
/// Checkbox screen shown after AWS discovery: lists every resource found,
/// grouped by category, so the user can choose exactly what gets imported.
/// <see cref="SelectedResources"/> is null when the user cancels.
/// </summary>
public partial class ImportSelectionDialog : Window
{
    public IReadOnlyList<DiscoveredResource>? SelectedResources { get; private set; }

    public ObservableCollection<ImportCategoryVm> Categories { get; } = [];

    public ImportSelectionDialog(IReadOnlyList<DiscoveredResource> discovered)
    {
        InitializeComponent();
        DataContext = this;

        foreach (var (category, types) in CategoryMap)
        {
            var items = discovered
                .Where(r => types.Contains(r.ResourceType))
                .OrderBy(r => types.IndexOf(r.ResourceType))
                .ThenBy(r => r.ResourceName, StringComparer.OrdinalIgnoreCase)
                .Select(r => new ImportResourceItemVm(r))
                .ToList();

            if (items.Count == 0) continue;

            var cat = new ImportCategoryVm(category, items, RefreshTotals);
            Categories.Add(cat);
        }

        RefreshTotals();
    }

    // ── Category layout (order and membership fixed by product spec) ─────────

    private static readonly List<(string Name, List<AwsResourceType> Types)> CategoryMap =
    [
        ("Compute",        [AwsResourceType.Ec2Instance, AwsResourceType.AutoScalingGroup,
                            AwsResourceType.LaunchTemplate]),
        ("Networking",     [AwsResourceType.Vpc, AwsResourceType.Subnet, AwsResourceType.SecurityGroup,
                            AwsResourceType.RouteTable, AwsResourceType.InternetGateway,
                            AwsResourceType.NatGateway, AwsResourceType.LoadBalancer,
                            AwsResourceType.TargetGroup]),
        ("Storage",        [AwsResourceType.S3Bucket]),
        ("Database",       [AwsResourceType.RdsInstance, AwsResourceType.RdsCluster,
                            AwsResourceType.DynamoDbTable, AwsResourceType.ElastiCacheCluster]),
        ("Serverless",     [AwsResourceType.LambdaFunction, AwsResourceType.ApiGatewayRestApi]),
        ("Containers",     [AwsResourceType.EcsCluster, AwsResourceType.EcsService,
                            AwsResourceType.EcrRepository, AwsResourceType.EksCluster]),
        ("Messaging",      [AwsResourceType.SqsQueue, AwsResourceType.SnsTopic]),
        ("IAM",            [AwsResourceType.IamRole, AwsResourceType.IamUser,
                            AwsResourceType.IamGroup, AwsResourceType.IamPolicy]),
        ("Security",       [AwsResourceType.KmsKey, AwsResourceType.SecretsManagerSecret,
                            AwsResourceType.AcmCertificate]),
        ("DNS/Monitoring", [AwsResourceType.Route53HostedZone, AwsResourceType.CloudWatchLogGroup,
                            AwsResourceType.CloudWatchAlarm]),
    ];

    internal static string TypeLabel(AwsResourceType type) => type switch
    {
        AwsResourceType.Ec2Instance          => "EC2",
        AwsResourceType.AutoScalingGroup     => "Auto Scaling Group",
        AwsResourceType.LaunchTemplate       => "Launch Template",
        AwsResourceType.Vpc                  => "VPC",
        AwsResourceType.Subnet               => "Subnet",
        AwsResourceType.SecurityGroup        => "Security Group",
        AwsResourceType.RouteTable           => "Route Table",
        AwsResourceType.InternetGateway      => "IGW",
        AwsResourceType.NatGateway           => "NAT Gateway",
        AwsResourceType.LoadBalancer         => "Load Balancer",
        AwsResourceType.TargetGroup          => "Target Group",
        AwsResourceType.S3Bucket             => "S3 Bucket",
        AwsResourceType.RdsInstance          => "RDS Instance",
        AwsResourceType.RdsCluster           => "RDS Cluster",
        AwsResourceType.DynamoDbTable        => "DynamoDB",
        AwsResourceType.ElastiCacheCluster   => "ElastiCache",
        AwsResourceType.LambdaFunction       => "Lambda",
        AwsResourceType.ApiGatewayRestApi    => "API Gateway",
        AwsResourceType.EcsCluster           => "ECS Cluster",
        AwsResourceType.EcsService           => "ECS Service",
        AwsResourceType.EcrRepository        => "ECR",
        AwsResourceType.EksCluster           => "EKS",
        AwsResourceType.SqsQueue             => "SQS",
        AwsResourceType.SnsTopic             => "SNS",
        AwsResourceType.IamRole              => "Role",
        AwsResourceType.IamUser              => "User",
        AwsResourceType.IamGroup             => "Group",
        AwsResourceType.IamPolicy            => "Policy",
        AwsResourceType.KmsKey               => "KMS",
        AwsResourceType.SecretsManagerSecret => "Secrets Manager",
        AwsResourceType.AcmCertificate       => "ACM Certificate",
        AwsResourceType.Route53HostedZone    => "Route53",
        AwsResourceType.CloudWatchLogGroup   => "CloudWatch Log Group",
        AwsResourceType.CloudWatchAlarm      => "CloudWatch Alarm",
        _                                    => type.ToString(),
    };

    // ── Totals / footer state ─────────────────────────────────────────────────

    private void RefreshTotals()
    {
        int total    = Categories.Sum(c => c.Items.Count);
        int selected = Categories.Sum(c => c.Items.Count(i => i.IsSelected));

        SummaryText.Text       = $"{selected} of {total} resource(s) selected";
        BtnImport.IsEnabled    = selected > 0;
        BtnImportText.Text     = selected > 0
            ? $"Import {selected} resource(s)"
            : "Import";
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        foreach (var c in Categories) c.SetAll(true);
        RefreshTotals();
    }

    private void DeselectAll_Click(object sender, RoutedEventArgs e)
    {
        foreach (var c in Categories) c.SetAll(false);
        RefreshTotals();
    }

    private void ExpandAll_Click(object sender, RoutedEventArgs e)
    {
        foreach (var c in Categories) c.IsExpanded = true;
    }

    private void CollapseAll_Click(object sender, RoutedEventArgs e)
    {
        foreach (var c in Categories) c.IsExpanded = false;
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        SelectedResources = Categories
            .SelectMany(c => c.Items)
            .Where(i => i.IsSelected)
            .Select(i => i.Resource)
            .ToList();
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    private void DragHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }
}

// ─── Category-level VM ───────────────────────────────────────────────────────

public partial class ImportCategoryVm : ObservableObject
{
    private readonly Action _totalsChanged;
    private bool _suppressPropagation;

    [ObservableProperty] private bool?  _isChecked = true;
    [ObservableProperty] private string _countLabel = string.Empty;
    [ObservableProperty] private bool   _isExpanded;

    public string Name { get; }
    public IReadOnlyList<ImportResourceItemVm> Items { get; }

    [RelayCommand]
    private void ToggleExpand() => IsExpanded = !IsExpanded;

    public ImportCategoryVm(string name, List<ImportResourceItemVm> items, Action totalsChanged)
    {
        Name           = name;
        Items          = items;
        _totalsChanged = totalsChanged;

        foreach (var i in items)
            i.SelectionChanged = OnItemSelectionChanged;

        RefreshState();
    }

    /// <summary>User clicked the category checkbox — propagate to all children.</summary>
    partial void OnIsCheckedChanged(bool? value)
    {
        if (_suppressPropagation || value is not bool b) return;

        _suppressPropagation = true;
        foreach (var i in Items) i.IsSelected = b;
        _suppressPropagation = false;

        RefreshState();
        _totalsChanged();
    }

    public void SetAll(bool selected)
    {
        _suppressPropagation = true;
        foreach (var i in Items) i.IsSelected = selected;
        IsChecked = selected;
        _suppressPropagation = false;
        RefreshState();
    }

    private void OnItemSelectionChanged()
    {
        if (_suppressPropagation) return;

        _suppressPropagation = true;
        RefreshState();
        _suppressPropagation = false;
        _totalsChanged();
    }

    private void RefreshState()
    {
        int sel = Items.Count(i => i.IsSelected);
        var newState = sel == 0 ? false : sel == Items.Count ? (bool?)true : null;

        bool wasSuppressed = _suppressPropagation;
        _suppressPropagation = true;
        IsChecked = newState;
        _suppressPropagation = wasSuppressed;

        CountLabel = $"{sel}/{Items.Count}";
    }
}

// ─── Resource-level VM ───────────────────────────────────────────────────────

public partial class ImportResourceItemVm : ObservableObject
{
    [ObservableProperty] private bool _isSelected = true;

    public DiscoveredResource Resource { get; }

    public Action? SelectionChanged { get; set; }

    public ImportResourceItemVm(DiscoveredResource resource)
    {
        Resource = resource;
    }

    public string TypeLabel    => ImportSelectionDialog.TypeLabel(Resource.ResourceType);
    public string DisplayName  => string.IsNullOrWhiteSpace(Resource.ResourceName)
                                    ? Resource.AwsId
                                    : Resource.ResourceName;
    public string AwsIdLabel   => Resource.AwsId;
    public bool   ShowAwsId    => !string.IsNullOrWhiteSpace(Resource.ResourceName)
                                    && Resource.ResourceName != Resource.AwsId;

    partial void OnIsSelectedChanged(bool value) => SelectionChanged?.Invoke();
}
