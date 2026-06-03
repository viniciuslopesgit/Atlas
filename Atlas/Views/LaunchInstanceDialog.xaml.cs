using Atlas.Models;
using Atlas.Services.AWS;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class LaunchInstanceDialog : Window
{
    public bool                  Confirmed { get; private set; }
    public LaunchInstanceOptions? Result   { get; private set; }

    private readonly IEc2Service _ec2;
    private readonly string      _newSgName;
    private bool                 _advancedOpen;

    // ── AMI families ──────────────────────────────────────────────
    // X86Id can be null for Arm-only images (e.g. macOS Tahoe)
    private record AmiVariant(
        string Name, string? X86Id, string? Arm64Id, string Description, string FreeTierLabel = "");

    /// <param name="IsMac">true = macOS; changes arch labels to Mac/Mac-Arm</param>
    private record AmiFamily(string Label, AmiVariant[] Variants, bool IsMac = false);

    private static readonly AmiFamily[] Families =
    [
        // ── 0. Amazon Linux ──────────────────────────────────────
        new("Amazon Linux",
        [
            new("Amazon Linux 2023 kernel-6.1 AMI",
                "ami-06422669907866d20", "ami-0427b892a7d590eeb",
                "AL2023 (kernel-6.1 LTS) — stable long-term support kernel. Recommended for production workloads. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Amazon Linux 2023 kernel-6.18 AMI",
                "ami-05af3290611073bb6", "ami-0971901d4b990baf0",
                "AL2023 (kernel-6.18) — latest kernel with newest driver support and performance improvements. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Amazon Linux 2 AMI (HVM)",
                "ami-0c101f26f147fa7fd", "ami-0843d7d2eb07c2b26",
                "Amazon Linux 2 — previous generation, LTS until Jun 2026. Includes the extras library for additional packages."),
            new("Deep Learning Base AMI with Single CUDA (Amazon Linux 2023)",
                "ami-0b08f85d6a10b9f58", "ami-0169f68d678456dd1",
                "Pre-installed CUDA toolkit and deep learning frameworks. Suitable for GPU-based ML training and inference workloads."),
            new("Deep Learning OSS Nvidia Driver AMI — PyTorch 2.11 (Amazon Linux 2023)",
                "ami-0b1dcb59cb23da5f1", "ami-07681dfa4351765ba",
                "Open-source Nvidia drivers with PyTorch 2.11 pre-installed. Optimized for PyTorch-based training on GPU instances."),
            new("Deep Learning AMI Neuron (Amazon Linux 2023)",
                "ami-0d87f7d57653552ce", null,
                "AWS Neuron SDK pre-installed for AWS Trainium and Inferentia accelerators. x86_64 only."),
        ]),

        // ── 1. Ubuntu ────────────────────────────────────────────
        new("Ubuntu",
        [
            new("Ubuntu Server 26.04 LTS (HVM), SSD Volume Type",
                "ami-0de864d6a3bd20ea8", "ami-0a0f534ab418ceb0f",
                "Ubuntu 26.04 LTS — Canonical's newest LTS release. 5 years standard support. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Ubuntu Server 24.04 LTS (HVM), SSD Volume Type",
                "ami-0354b051078d198b4", "ami-062db60591ca5a606",
                "Ubuntu 24.04 LTS (Noble Numbat) — widely adopted LTS, 5 years standard support. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Ubuntu Server 22.04 LTS (HVM) with SQL Server 2022 Standard",
                "ami-0e33f7b2184b95274", null,
                "Ubuntu 22.04 LTS with Microsoft SQL Server 2022 Standard pre-installed. x86_64 only. SQL Server license costs apply."),
            new("Ubuntu Pro — Server Pro 26.04 LTS (HVM), SSD Volume Type",
                "ami-055cbcb7eb49776c6", "ami-0faacc95885dcaf62",
                "Ubuntu Pro 26.04 LTS — includes expanded security maintenance (ESM) and compliance tooling. Ubuntu Pro subscription required."),
            new("Ubuntu Pro — Server Pro 24.04 LTS (HVM), SSD Volume Type",
                "ami-091e431be59eb503a", "ami-0db371fe0183db93a",
                "Ubuntu Pro 24.04 LTS — expanded security maintenance, FIPS compliance, and live kernel patching. Ubuntu Pro subscription required."),
            new("Deep Learning Base AMI with Single CUDA (Ubuntu 24.04)",
                "ami-0105a47d2d71f8d44", "ami-082f46554902bcdb7",
                "Pre-installed CUDA toolkit and deep learning frameworks on Ubuntu 24.04. GPU and Arm GPU instances."),
            new("Deep Learning OSS Nvidia Driver AMI — PyTorch 2.11 (Ubuntu 24.04)",
                "ami-0e50ee2e458b74614", "ami-096822a965738a91c",
                "Open-source Nvidia drivers with PyTorch 2.11 pre-installed on Ubuntu 24.04. Optimized for GPU training."),
            new("Deep Learning AMI Neuron (Ubuntu 24.04)",
                "ami-0900661b5cb0567c4", null,
                "AWS Neuron SDK pre-installed for Trainium and Inferentia accelerators on Ubuntu 24.04. x86_64 only."),
        ]),

        // ── 2. Windows (all x86_64 only) ─────────────────────────
        new("Windows",
        [
            // ── Base editions ─────────────────────────────────
            new("Microsoft Windows Server 2025 Base",
                "ami-0bc74d0ac37f50b4b", null,
                "Windows Server 2025 Datacenter edition. Latest LTSC release with enhanced security and hybrid cloud features. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2025 Core Base",
                "ami-020ec4df919773053", null,
                "Windows Server 2025 Datacenter Core edition. Minimal footprint, no GUI — ideal for automation and containers. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2022 Base",
                "ami-0f625b90f35024136", null,
                "Windows Server 2022 Datacenter edition. LTSC, supported through 2031. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2022 Core Base",
                "ami-09555ecea4c190cb2", null,
                "Windows Server 2022 Datacenter Core edition. No GUI — lower resource usage. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2019 Base",
                "ami-0916cc207a981cb4c", null,
                "Windows Server 2019 Datacenter edition. LTSC, supported through 2029. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2019 Core Base",
                "ami-0e6c27a0b569e10e9", null,
                "Windows Server 2019 Datacenter Core edition. No GUI — lower resource usage. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2016 Base",
                "ami-037ea2c0f61437143", null,
                "Windows Server 2016 Datacenter edition. LTSC, supported through 2027. [English]",
                "Free tier eligible"),
            new("Microsoft Windows Server 2016 Core Base",
                "ami-0c81155c2eb72bf67", null,
                "Windows Server 2016 Datacenter Core edition. No GUI. [English]",
                "Free tier eligible"),
            // ── SQL Server 2025 ───────────────────────────────
            new("Windows Server 2025 with SQL Server 2025 Standard",
                "ami-0439e7fb9a1b0a0eb", null,
                "Windows Server 2025 Datacenter + SQL Server 2025 Standard. SQL Server license costs apply. [English]"),
            new("Windows Server 2025 with SQL Server 2025 Enterprise",
                "ami-0bed7b36e78ec8f23", null,
                "Windows Server 2025 Datacenter + SQL Server 2025 Enterprise. SQL Server license costs apply. [English]"),
            // ── SQL Server 2022 ───────────────────────────────
            new("Windows Server 2022 with SQL Server 2022 Standard",
                "ami-0e2cf62a70db0d7c2", null,
                "Windows Server 2022 Datacenter + SQL Server 2022 Standard. SQL Server license costs apply. [English]"),
            new("Windows Server 2022 with SQL Server 2022 Enterprise",
                "ami-063261da003e4e052", null,
                "Windows Server 2022 Datacenter + SQL Server 2022 Enterprise. SQL Server license costs apply. [English]"),
            new("Windows Server 2022 with SQL Server 2022 Web",
                "ami-0281b93c30ac3021d", null,
                "Windows Server 2022 Datacenter + SQL Server 2022 Web edition. SQL Server license costs apply. [English]"),
            new("Windows Server 2019 with SQL Server 2022 Standard",
                "ami-011621e350ad426ea", null,
                "Windows Server 2019 Datacenter + SQL Server 2022 Standard. SQL Server license costs apply. [English]"),
            new("Windows Server 2019 with SQL Server 2022 Enterprise",
                "ami-0860fe356c09afaa8", null,
                "Windows Server 2019 Datacenter + SQL Server 2022 Enterprise. SQL Server license costs apply. [English]"),
            // ── SQL Server 2019 ───────────────────────────────
            new("Windows Server 2022 with SQL Server 2019 Standard",
                "ami-0ac342a1a936dadae", null,
                "Windows Server 2022 Datacenter + SQL Server 2019 Standard. SQL Server license costs apply. [English]"),
            new("Windows Server 2022 with SQL Server 2019 Enterprise",
                "ami-0579ed8151dea72b9", null,
                "Windows Server 2022 Datacenter + SQL Server 2019 Enterprise. SQL Server license costs apply. [English]"),
            new("Windows Server 2019 with SQL Server 2019 Standard",
                "ami-0d0b565c5b8e11072", null,
                "Windows Server 2019 Datacenter + SQL Server 2019 Standard. SQL Server license costs apply. [English]"),
            new("Windows Server 2019 with SQL Server 2019 Enterprise",
                "ami-084f1dad214c37d63", null,
                "Windows Server 2019 Datacenter + SQL Server 2019 Enterprise. SQL Server license costs apply. [English]"),
            // ── Office ────────────────────────────────────────
            new("Windows Server 2022 with Office Professional Plus",
                "ami-0d9f5378cc8179d01", null,
                "Windows Server 2022 with Microsoft Office Professional Plus pre-installed. License costs apply. [English]"),
        ]),

        // ── 3. Red Hat ───────────────────────────────────────────
        new("Red Hat",
        [
            new("Red Hat Enterprise Linux 10 (HVM), SSD Volume Type",
                "ami-0c56a9c577d7c5963", "ami-0e3d65f62b4e94862",
                "RHEL 10 — newest major release. Current generation with latest security features and tooling. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Red Hat Enterprise Linux 10 with High Availability",
                "ami-0821c6b67e8270a6e", null,
                "RHEL 10 with High Availability add-on. Includes Pacemaker cluster stack for HA workloads. x86_64 only."),
            new("Red Hat Enterprise Linux 9 (HVM), SSD Volume Type",
                "ami-074a9d465bc43b508", "ami-0b67561c9eb1a316b",
                "RHEL 9 — Extended Update Support through 2032. Stable and enterprise-grade. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("Red Hat Enterprise Linux 8 (HVM), SSD Volume Type",
                "ami-0056d98d3fe05cdbd9", "ami-0b28bbd4ff0df7ac8",
                "RHEL 8 — LTS through 2029. Widely deployed in enterprise environments. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("RHEL 8 with SQL Server 2022 Standard Edition AMI",
                "ami-0ed15b98767233fdb", null,
                "RHEL 8 with Microsoft SQL Server 2022 Standard pre-installed. x86_64 only. SQL Server license costs apply."),
        ]),

        // ── 4. Debian ────────────────────────────────────────────
        new("Debian",
        [
            new("Debian 12 (Bookworm) HVM, EBS",
                "ami-09aaab6bcf097ddfa", "ami-0a9e4c2e234e09e60",
                "Debian 12 — current stable release, LTS until June 2028. Minimal and reliable.",
                "Free tier eligible"),
            new("Debian 11 (Bullseye) HVM, EBS",
                "ami-09b0d0f96f2cde7ec", "ami-047d3a50e14b2e6f5",
                "Debian 11 — LTS until June 2026. Previous stable release."),
        ]),

        // ── 5. SUSE Linux ────────────────────────────────────────
        new("SUSE Linux",
        [
            new("SUSE Linux Enterprise Server 16 (HVM), SSD Volume Type",
                "ami-0d2945b6b30408829", "ami-03ebf781b475960c8",
                "SLES 16 — newest major SUSE enterprise release. Cloud-optimized kernel, AWS integration. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
            new("SUSE Linux Enterprise Server 15 SP7 (HVM), SSD Volume Type",
                "ami-0affda52580913356", "ami-0dc09f10fa9c835a7",
                "SLES 15 SP7 — current service pack with full enterprise support and long-term maintenance. Virtualization: hvm · ENA: true · Root: ebs.",
                "Free tier eligible"),
        ]),

        // ── 6. macOS ─────────────────────────────────────────────
        new("macOS", IsMac: true,
        Variants:
        [
            new("macOS Tahoe",
                null, "ami-004cc2d9a0e66d217",
                "macOS Tahoe — latest macOS release. Mac-Arm (Apple Silicon) only. Requires mac2.metal, mac2-m2.metal, mac2-m2pro.metal or mac2-m1ultra.metal Dedicated Host."),
            new("macOS Sequoia",
                "ami-0f5821c8a62966b27", "ami-025db40a592bbfea7",
                "macOS Sequoia — supported on all Mac instance families. Intel: mac1.metal · Apple Silicon: mac2.metal / mac2-m2.metal+"),
            new("macOS Sonoma",
                "ami-02618143f2df7ce3f", "ami-0ae21f86840b4b86f",
                "macOS Sonoma — supported on all Mac instance families. Virtualization: hvm · ENA: true · Root: ebs."),
        ]),
    ];

    // ── Instance types ────────────────────────────────────────────
    private record InstanceTypeEntry(string Label, string Value, int VCpu, string Memory, bool FreeTier);

    private static readonly InstanceTypeEntry[] InstanceTypes =
    [
        new("t3.nano      — 2 vCPU · 0.5 GiB",                        "t3.nano",    2, "0.5 GiB", false),
        new("t3.micro     — 2 vCPU · 1 GiB  (Free tier eligible)",    "t3.micro",   2, "1 GiB",   true),
        new("t3.small     — 2 vCPU · 2 GiB",                          "t3.small",   2, "2 GiB",   false),
        new("t3.medium    — 2 vCPU · 4 GiB",                          "t3.medium",  2, "4 GiB",   false),
        new("t3.large     — 2 vCPU · 8 GiB",                          "t3.large",   2, "8 GiB",   false),
        new("t3.xlarge    — 4 vCPU · 16 GiB",                         "t3.xlarge",  4, "16 GiB",  false),
        new("t3a.micro    — 2 vCPU · 1 GiB",                          "t3a.micro",  2, "1 GiB",   false),
        new("t3a.small    — 2 vCPU · 2 GiB",                          "t3a.small",  2, "2 GiB",   false),
        new("t3a.medium   — 2 vCPU · 4 GiB",                          "t3a.medium", 2, "4 GiB",   false),
        new("m5.large     — 2 vCPU · 8 GiB",                          "m5.large",   2, "8 GiB",   false),
        new("m5.xlarge    — 4 vCPU · 16 GiB",                         "m5.xlarge",  4, "16 GiB",  false),
        new("m5.2xlarge   — 8 vCPU · 32 GiB",                         "m5.2xlarge", 8, "32 GiB",  false),
        new("c5.large     — 2 vCPU · 4 GiB",                          "c5.large",   2, "4 GiB",   false),
        new("c5.xlarge    — 4 vCPU · 8 GiB",                          "c5.xlarge",  4, "8 GiB",   false),
        new("r5.large     — 2 vCPU · 16 GiB",                         "r5.large",   2, "16 GiB",  false),
        new("r5.xlarge    — 4 vCPU · 32 GiB",                         "r5.xlarge",  4, "32 GiB",  false),
    ];

    // ── Volume types ──────────────────────────────────────────────
    private static readonly (string Label, string Value)[] VolumeTypes =
    [
        ("gp3  — General Purpose SSD (recommended)", "gp3"),
        ("gp2  — General Purpose SSD",               "gp2"),
        ("io1  — Provisioned IOPS SSD",              "io1"),
        ("io2  — Provisioned IOPS SSD",              "io2"),
        ("st1  — Throughput Optimized HDD",          "st1"),
        ("sc1  — Cold HDD",                          "sc1"),
        ("standard  — Magnetic",                     "standard"),
    ];

    // Current state
    private int           _familyIndex;
    private int           _variantIndex;
    private IReadOnlyList<SecurityGroupSummary> _secGroups = [];

    // ── Constructor ───────────────────────────────────────────────
    public LaunchInstanceDialog(string currentRegion, IEc2Service ec2)
    {
        InitializeComponent();
        _ec2       = ec2;
        _newSgName = $"launch-wizard-{DateTime.Now:MMddHHmmss}";

        TxtRegionBadge.Text = $"Region: {currentRegion}";
        TxtSgPreview.Text   = $"We'll create a new security group called '{_newSgName}' with the following rules:";

        foreach (var t in InstanceTypes)
            CmbInstanceType.Items.Add(new ComboBoxItem { Content = t.Label, Tag = t.Value });
        CmbInstanceType.SelectedIndex = 1;

        foreach (var (label, value) in VolumeTypes)
            CmbVolumeType.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        CmbVolumeType.SelectedIndex = 0;

        Loaded += async (_, _) =>
        {
            UpdateVariants();   // populates PnlAmiVariants and AMI card
            TxtName.Focus();
            await LoadRemoteDataAsync();
        };
    }

    private void DragHandle_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    // ── Remote data loading ───────────────────────────────────────
    private async Task LoadRemoteDataAsync()
    {
        TxtNetworkLoading.Visibility = Visibility.Visible;
        CmbVpc.Items.Clear();
        CmbSubnet.Items.Clear();
        CmbKeyPair.Items.Clear();

        try
        {
            var vpcsTask    = _ec2.GetVpcsAsync();
            var kpsTask     = _ec2.GetKeyPairsAsync();
            var sgsTask     = _ec2.GetSecurityGroupsAsync();
            await Task.WhenAll(vpcsTask, kpsTask, sgsTask);

            // VPCs
            CmbVpc.Items.Add(new ComboBoxItem
                { Content = "No preference (Default subnet in any availability zone)", Tag = "" });
            foreach (var v in vpcsTask.Result)
                CmbVpc.Items.Add(new ComboBoxItem { Content = v.DisplayLabel, Tag = v.VpcId });
            CmbVpc.SelectedIndex = 0;

            // Subnets for default VPC
            var defaultVpc = vpcsTask.Result.FirstOrDefault(v => v.IsDefault);
            await PopulateSubnetsAsync(defaultVpc?.VpcId);

            // Key pairs
            CmbKeyPair.Items.Add(new ComboBoxItem
                { Content = "Proceed without key pair", Tag = "" });
            foreach (var kp in kpsTask.Result)
                CmbKeyPair.Items.Add(new ComboBoxItem { Content = kp.KeyName, Tag = kp.KeyName });
            CmbKeyPair.SelectedIndex = 0;

            // Security groups (for "Select existing")
            _secGroups = sgsTask.Result;
            RefreshExistingSgDropdown();
        }
        catch (Exception ex)
        {
            TxtNetworkError.Text       = $"Could not load network data: {ex.Message}";
            TxtNetworkError.Visibility = Visibility.Visible;

            // Fallback: still usable with empty dropdowns
            if (CmbKeyPair.Items.Count == 0)
                CmbKeyPair.Items.Add(new ComboBoxItem { Content = "Proceed without key pair", Tag = "" });
            CmbKeyPair.SelectedIndex = 0;
        }
        finally
        {
            TxtNetworkLoading.Visibility = Visibility.Collapsed;
        }
    }

    private async Task PopulateSubnetsAsync(string? vpcId)
    {
        CmbSubnet.Items.Clear();
        CmbSubnet.Items.Add(new ComboBoxItem
            { Content = "No preference (Default subnet in any availability zone)", Tag = "" });
        try
        {
            var subnets = await _ec2.GetSubnetsAsync(vpcId);
            foreach (var s in subnets)
                CmbSubnet.Items.Add(new ComboBoxItem { Content = s.DisplayLabel, Tag = s.SubnetId });
        }
        catch { /* ignore — no preference works fine */ }
        CmbSubnet.SelectedIndex = 0;
    }

    private void RefreshExistingSgDropdown()
    {
        CmbExistingSg.Items.Clear();
        var vpcId = (CmbVpc.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
        var filtered = string.IsNullOrEmpty(vpcId)
            ? _secGroups
            : _secGroups.Where(sg => sg.VpcId == vpcId).ToList();
        foreach (var sg in filtered)
            CmbExistingSg.Items.Add(new ComboBoxItem { Content = sg.DisplayLabel, Tag = sg.GroupId });
        if (CmbExistingSg.Items.Count > 0) CmbExistingSg.SelectedIndex = 0;
        TxtSgLoading.Visibility = Visibility.Collapsed;
    }

    // ── VPC selection changes subnets + SG list ───────────────────
    private async void CmbVpc_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbVpc.SelectedItem is not ComboBoxItem item) return;
        var vpcId = item.Tag as string ?? "";
        await PopulateSubnetsAsync(string.IsNullOrEmpty(vpcId) ? null : vpcId);
        RefreshExistingSgDropdown();
    }

    // ── AMI variants ──────────────────────────────────────────────
    private void Os_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton rb && int.TryParse(rb.Tag?.ToString(), out int idx))
            _familyIndex = idx;
        _variantIndex = 0;
        UpdateVariants();
    }

    private void UpdateVariants()
    {
        if (PnlAmiVariants == null) return;

        var family = Families[_familyIndex];
        PnlAmiVariants.Children.Clear();

        for (int i = 0; i < family.Variants.Length; i++)
        {
            var variant  = family.Variants[i];
            var isFirst  = i == 0;
            var rb       = BuildVariantRadioButton(variant, isFirst, i);
            PnlAmiVariants.Children.Add(rb);
        }

        UpdateAmiCard();
    }

    private RadioButton BuildVariantRadioButton(AmiVariant variant, bool isChecked, int index)
    {
        // Name + free tier badge row
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal };
        nameRow.Children.Add(new TextBlock
        {
            Text       = variant.Name,
            FontSize   = 12,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)FindResource("TextPrimaryBrush")
        });
        if (!string.IsNullOrEmpty(variant.FreeTierLabel))
        {
            nameRow.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(4),
                Background   = new SolidColorBrush(Color.FromArgb(0x22, 0x22, 0xC5, 0x5E)),
                Padding      = new Thickness(5, 1, 5, 1),
                Margin       = new Thickness(8, 0, 0, 0),
                Child = new TextBlock
                {
                    Text       = variant.FreeTierLabel,
                    FontSize   = 10,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(Color.FromRgb(0x22, 0xC5, 0x5E))
                }
            });
        }

        // AMI ID (prefer x86, fall back to arm64 for Arm-only variants like macOS Tahoe)
        var amiIdText = new TextBlock
        {
            Text       = variant.X86Id ?? variant.Arm64Id ?? string.Empty,
            FontFamily = new FontFamily("Consolas"),
            FontSize   = 10,
            Foreground = (Brush)FindResource("TextMutedBrush"),
            Margin     = new Thickness(0, 2, 0, 0)
        };

        var content = new StackPanel();
        content.Children.Add(nameRow);
        content.Children.Add(amiIdText);

        var rb = new RadioButton
        {
            Style     = (Style)FindResource("VariantRadio"),
            GroupName = "AmiVariant",
            IsChecked = isChecked,
            Tag       = index,
            Content   = content
        };
        rb.Checked += VariantRadio_Checked;
        return rb;
    }

    private void VariantRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: int idx })
            _variantIndex = idx;
        UpdateAmiCard();
    }

    private void UpdateAmiCard()
    {
        if (TxtAmiName == null) return;

        var family  = Families[_familyIndex];
        var variant = family.Variants[_variantIndex];

        TxtAmiName.Text        = variant.Name;
        TxtAmiBadge.Text       = variant.FreeTierLabel;
        TxtAmiBadge.Visibility = string.IsNullOrEmpty(variant.FreeTierLabel)
            ? Visibility.Collapsed : Visibility.Visible;
        TxtAmiDesc.Text = variant.Description;

        // Architecture selector — different labels for macOS
        CmbArch.Items.Clear();
        if (family.IsMac)
        {
            if (variant.X86Id != null)
                CmbArch.Items.Add(new ComboBoxItem { Content = "64-bit (Mac — Intel)",            Tag = "x86_64_mac" });
            if (variant.Arm64Id != null)
                CmbArch.Items.Add(new ComboBoxItem { Content = "64-bit (Mac-Arm — Apple Silicon)", Tag = "arm64_mac" });
        }
        else
        {
            if (variant.X86Id != null)
                CmbArch.Items.Add(new ComboBoxItem { Content = "64-bit (x86)", Tag = "x86_64" });
            if (variant.Arm64Id != null)
                CmbArch.Items.Add(new ComboBoxItem { Content = "64-bit (Arm)", Tag = "arm64" });
        }
        CmbArch.SelectedIndex = 0;

        // macOS Dedicated Host note
        if (PnlMacOsNote != null)
            PnlMacOsNote.Visibility = family.IsMac ? Visibility.Visible : Visibility.Collapsed;

        RefreshAmiId();
    }

    private void RefreshAmiId()
    {
        var family  = Families[_familyIndex];
        var variant = family.Variants[_variantIndex];
        var arch    = SelectedArch();
        var isArm   = arch is "arm64" or "arm64_mac";
        var id      = isArm ? (variant.Arm64Id ?? variant.X86Id) : (variant.X86Id ?? variant.Arm64Id);

        TxtAmiId.Text = family.IsMac
            ? $"AMI ID: {id}  (varies by region)"
            : $"AMI ID: {id}";
    }

    private void CmbArch_SelectionChanged(object sender, SelectionChangedEventArgs e) => RefreshAmiId();

    private string SelectedArch()
        => (CmbArch.SelectedItem as ComboBoxItem)?.Tag as string ?? "x86_64";

    // ── Instance type info ────────────────────────────────────────
    private void CmbInstanceType_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbInstanceType.SelectedItem is not ComboBoxItem item) return;
        var value = item.Tag as string ?? string.Empty;
        var info  = Array.Find(InstanceTypes, t => t.Value == value);
        if (info == null) return;

        TxtInstanceFamily.Text         = $"Family: {value.Split('.')[0]}";
        TxtInstanceVcpu.Text           = $"{info.VCpu} vCPU";
        TxtInstanceMem.Text            = $"{info.Memory} Memory";
        TxtInstanceFreeTier.Text       = info.FreeTier ? "Free tier eligible" : string.Empty;
        TxtInstanceFreeTier.Visibility = info.FreeTier ? Visibility.Visible : Visibility.Collapsed;
    }

    // ── Key pair ──────────────────────────────────────────────────
    private void CmbKeyPair_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbKeyPair.SelectedItem is not ComboBoxItem item) return;
        var tag = item.Tag as string ?? string.Empty;
        PnlNoKeyPairWarn.Visibility = string.IsNullOrEmpty(tag)
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void CreateKeyPair_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new CreateKeyPairDialog(_ec2) { Owner = this };
        dlg.ShowDialog();
        if (!dlg.Confirmed) return;

        // Add to dropdown and select it
        var name = dlg.KeyPairName;
        var existing = CmbKeyPair.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(i => (string?)i.Tag == name);
        if (existing != null)
        {
            CmbKeyPair.SelectedItem = existing;
        }
        else
        {
            var item = new ComboBoxItem { Content = name, Tag = name };
            CmbKeyPair.Items.Add(item);
            CmbKeyPair.SelectedItem = item;
        }
    }

    // ── Security group mode ───────────────────────────────────────
    private void SgMode_Changed(object sender, RoutedEventArgs e)
    {
        if (PnlNewSg == null) return;
        bool createNew = RdoCreateSg.IsChecked == true;
        PnlNewSg.Visibility    = createNew ? Visibility.Visible   : Visibility.Collapsed;
        PnlExistingSg.Visibility = createNew ? Visibility.Collapsed : Visibility.Visible;
    }

    // ── Advanced details toggle ───────────────────────────────────
    private void ToggleAdvanced_Click(object sender, RoutedEventArgs e)
    {
        _advancedOpen = !_advancedOpen;
        PnlAdvanced.Visibility    = _advancedOpen ? Visibility.Visible : Visibility.Collapsed;
        TxtAdvancedChevron.Text   = _advancedOpen ? "▼" : "▶";
    }

    // ── Validation ────────────────────────────────────────────────
    private bool Validate()
    {
        var ok = true;

        TxtVolumeError.Visibility = Visibility.Collapsed;
        if (!int.TryParse(TxtVolumeSize.Text.Trim(), out int vol) || vol < 1 || vol > 16384)
        {
            TxtVolumeError.Text       = "Volume size must be between 1 and 16,384 GiB.";
            TxtVolumeError.Visibility = Visibility.Visible;
            ok = false;
        }

        TxtCountError.Visibility = Visibility.Collapsed;
        if (!int.TryParse(TxtCount.Text.Trim(), out int count) || count < 1 || count > 20)
        {
            TxtCountError.Text       = "Number of instances must be between 1 and 20.";
            TxtCountError.Visibility = Visibility.Visible;
            ok = false;
        }

        return ok;
    }

    // ── Launch ────────────────────────────────────────────────────
    private void Launch_Click(object sender, RoutedEventArgs e)
    {
        if (!Validate()) return;

        var variant = Families[_familyIndex].Variants[_variantIndex];
        var arch    = SelectedArch();
        var isArm   = arch is "arm64" or "arm64_mac";
        var amiId   = isArm
            ? (variant.Arm64Id ?? variant.X86Id ?? "")
            : (variant.X86Id   ?? variant.Arm64Id ?? "");

        _ = int.TryParse(TxtVolumeSize.Text.Trim(), out int volSize);
        _ = int.TryParse(TxtCount.Text.Trim(),       out int count);

        var volType      = (CmbVolumeType.SelectedItem   as ComboBoxItem)?.Tag as string ?? "gp3";
        var instanceType = (CmbInstanceType.SelectedItem as ComboBoxItem)?.Tag as string ?? "t3.micro";
        var keyPairName  = (CmbKeyPair.SelectedItem       as ComboBoxItem)?.Tag as string ?? "";
        var vpcId        = (CmbVpc.SelectedItem           as ComboBoxItem)?.Tag as string ?? "";
        var subnetId     = (CmbSubnet.SelectedItem        as ComboBoxItem)?.Tag as string ?? "";
        var existingSgId = (CmbExistingSg.SelectedItem    as ComboBoxItem)?.Tag as string ?? "";

        Result = new LaunchInstanceOptions
        {
            Name                    = TxtName.Text.Trim(),
            AmiId                   = amiId,
            AmiDisplayName          = variant.Name,
            Architecture            = arch,
            InstanceType            = instanceType,
            KeyPairName             = string.IsNullOrEmpty(keyPairName) ? null : keyPairName,
            VpcId                   = string.IsNullOrEmpty(vpcId) ? null : vpcId,
            SubnetId                = string.IsNullOrEmpty(subnetId) ? null : subnetId,
            AutoAssignPublicIp      = RdoPublicIpEnable.IsChecked == true,
            CreateNewSecurityGroup  = RdoCreateSg.IsChecked == true,
            NewSecurityGroupName    = _newSgName,
            ExistingSecurityGroupId = existingSgId,
            AllowSsh                = ChkAllowSsh.IsChecked  == true,
            AllowHttp               = ChkAllowHttp.IsChecked  == true,
            AllowHttps              = ChkAllowHttps.IsChecked == true,
            RootVolumeSize          = volSize,
            RootVolumeType          = volType,
            IamInstanceProfile      = string.IsNullOrWhiteSpace(TxtIamProfile.Text) ? null : TxtIamProfile.Text.Trim(),
            UserData                = string.IsNullOrWhiteSpace(TxtUserData.Text)   ? null : TxtUserData.Text,
            ShutdownBehavior        = RdoShutdownTerminate.IsChecked == true ? "terminate" : "stop",
            TerminationProtection   = ChkTermProtect.IsChecked == true,
            DetailedMonitoring      = ChkMonitoring.IsChecked  == true,
            EbsOptimized            = ChkEbsOptimized.IsChecked == true,
            Imdsv2                  = RdoImdsRequired.IsChecked == true ? "required" : "optional",
            Count                   = count,
        };

        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }
}
