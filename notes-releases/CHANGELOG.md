# Changelog

All notable changes to Atlas will be documented in this file.

---

## [Unreleased] — 2026-06-09 (updated 2026-06-12)

### Fixed

#### S3 — Editor de ficheiros inline

- **Botão Save sempre desativado** — o JavaScript do Monaco usava `window.chrome.webview.postMessage(JSON.stringify({...}))`, que envia uma string ao WebView2; o lado C# fazia `JsonDocument.Parse(e.WebMessageAsJson)` e recebia um `JsonValueKind.String` em vez de `Object`, causando `InvalidOperationException` em `GetProperty("type")` — engolida pelo `catch { return; }`. Todas as mensagens do Monaco (incluindo `"ready"`, `"change"` e `"save"`) eram silenciosamente descartadas: o botão Save ficava sempre a 45 % de opacidade (desativado), `_cachedContent` nunca era atualizado e Ctrl+S não funcionava. Corrigido removendo `JSON.stringify` de todas as chamadas `postMessage` — o WebView2 serializa objetos diretamente e `WebMessageAsJson` devolve o JSON correto.

- **Ctrl+S fechava o editor após guardar** — `PerformSaveAsync` chamava sempre `Close()` em caso de sucesso, independentemente de o save ter sido iniciado pelo botão ou pelo atalho de teclado. Corrigido com parâmetro `closeOnSuccess`: o botão Save continua a fechar o diálogo; Ctrl+S guarda o ficheiro, limpa o indicador `● Modified`, mostra `✓ Saved` na barra de estado e mantém o editor aberto.

### Added

#### IaC — Infrastructure as Code (Terraform integration)

**Data layer**
- `TerraformProjectConfig` model — properties: `Id`, `Name`, `RootPath`, `DefaultWorkspace`, `BackendType`, `AutoCommitEnabled`, `ManagedModules`, `IsInitialized`, `CreatedAt`
- `ITerraformProjectRepository` / `TerraformProjectRepository` — full CRUD + `MarkInitialized`; persisted in SQLite (`TerraformProjects` table added to `DatabaseContext.InitializeSchema`)

**Service layer — Project Manager**
- `ITerraformProjectManager` / `TerraformProjectManager` — validates `.tf` presence in directory, delegates `init` to CLI wrapper, saves/removes projects

**Service layer — CLI Wrapper** (`Services/Terraform/`)
- `TerraformAwsCredentials` record — `AccessKeyId`, `SecretAccessKey`, `Region`, `SessionToken?`; injected as child-process env vars only — parent process env is never modified
- `TerraformResult` record — `Status` (`Success`, `PlanHasChanges`, `NoChanges`, `Failed`, `Cancelled`, `TimedOut`, `TerraformNotFound`), `IsSuccess`, `Stdout`, `Stderr`, `FullOutput`, `ParsedErrors`, `DiagnosticMessage`, `Duration`
- `ITerraformCliWrapper` interface — `GetVersionAsync`, `InitAsync`, `ValidateAsync`, `PlanAsync`, `ApplyAsync`, `ImportAsync`, `OutputAsync`; all accept `IProgress<string>?` and `CancellationToken`
- `TerraformCliWrapper` implementation:
  - Executes `terraform` via `System.Diagnostics.Process` with `BeginOutputReadLine`/`BeginErrorReadLine` for real-time streaming
  - `TF_IN_AUTOMATION=1` and `TF_INPUT=false` always set — prevents interactive prompts
  - Linked `CancellationTokenSource` separates user cancellation from configurable timeout (default 5 min)
  - `terraform plan` exit-code 2 mapped to `PlanHasChanges` (not an error)
  - `terraform` not found in PATH detected via `Win32Exception` native codes and mapped to `TerraformNotFound`
  - Terraform error block parser: supports TF 1.x `╷/╵` diagnostic format and legacy `Error:` prefix lines
  - Friendly diagnostic messages for: expired/invalid AWS credentials, state lock, uninitialized backend, missing provider, insufficient permissions, HCL syntax errors
  - All operations logged via `FileLogger`

**ViewModel**
- `TerraformViewModel` — `[RelayCommand]` for `LoadAsync`, `AddProject`, `RemoveProject`, `RunInit`, `RunValidate`, `RunPlan`, `RunApply`, `RunOutput`
- `RunCommandAsync` central method streams output line-by-line via `IProgress<string>` → updates `TerminalOutput` on the UI thread in real time
- Reads active AWS account credentials from `IAccountService` at execution time — never cached in the ViewModel
- Detects and displays terraform CLI version badge on page load

**View**
- `TerraformView.xaml` — new IaC page styled to match all existing views (`Card`, `GhostButton`, `PrimaryButton`, standard margins)
- Per-project action bar: **init · validate · plan · apply · output** ghost buttons, all disabled while a command runs
- Integrated terminal panel: header with running/success/error state, scrollable `Consolas` output, stderr appended with separator
- "Add Project" form: Project Name, Root Path (with `OpenFolderDialog` browse button), Default Workspace, Backend Type dropdown (`local`, `s3`, `azurerm`, `gcs`, `remote`), Auto-commit toggle
- terraform CLI version badge in page header (hidden when CLI not found)

**Navigation & DI**
- `NavigationPage.IaC` added to the enum — free tier (not Pro-gated)
- Sidebar item "IaC" (`&#xE9F5;`) added before the Settings separator
- `DataTemplate` registered in `MainWindow.xaml`
- DI registrations in `App.xaml.cs`: `ITerraformProjectRepository`, `ITerraformCliWrapper`, `ITerraformProjectManager`, `TerraformViewModel`
- IaC page added to Command Palette with keywords: terraform, iac, infrastructure, init, workspace

#### IaC — HCL Generator (Parte 3)

**NuGet / project**
- Added `Scriban 5.*` package; added `<package pattern="Scriban"/>` to `nuget.config` PackageSourceMapping
- HCL template files declared as `<EmbeddedResource Include="Templates\Terraform\**\*.tpl"/>` — shipped inside the assembly, no external files required

**Scriban templates** (`Templates/Terraform/`)
- `ec2_instance.tf.tpl` — `aws_instance` with AMI, instance type, subnet, security groups, key pair, IAM profile, root EBS volume, monitoring, user-data, tags, lifecycle ignore
- `s3_bucket.tf.tpl` — `aws_s3_bucket` + public access block + optional versioning + optional SSE + optional logging
- `security_group.tf.tpl` — `aws_security_group` with typed ingress/egress rule lists
- `iam_role.tf.tpl` — `aws_iam_role` + inline policies + managed policy attachments via ARN; ARN used as resource name suffix
- `modules/ec2/main.tf.tpl` — module main using `var.*` references
- `modules/ec2/variables.tf.tpl` — full typed variable declarations with defaults
- `modules/ec2/outputs.tf.tpl` — instance_id, instance_arn, private_ip, public_ip
- `modules/s3/main.tf.tpl` — module main with bucket + public access block + versioning + SSE
- `modules/s3/variables.tf.tpl` — typed variable declarations
- `modules/s3/outputs.tf.tpl` — bucket_id, bucket_arn, domain names

**ATLAS-MANAGED marker system** (`HclMergeEngine`)
- Markers: `# ATLAS-MANAGED-START <key>` … `# ATLAS-MANAGED-END <key>` wrapping each generated block
- Regex with backreference ensures START/END keys always match
- Merge rules: existing managed block → replaced by new version; existing block with no new counterpart → preserved intact; new block with no existing counterpart → appended; all content outside managed blocks → always preserved
- Public helpers: `Merge(existing, new)`, `ExtractKeys(content)`, `HasManagedBlocks(content)`

**HCL models** (`Services/Terraform/Hcl/Models/`)
- `HclTag` record — `(string Key, string Value)` for `tags = { ... }` blocks
- `Ec2InstanceHclModel` — all EC2 resource fields + `FromAtlasInstance()` factory from live `Ec2InstanceModel`
- `S3BucketHclModel` — all S3 resource fields + `FromAtlasBucket()` factory from live `S3BucketModel`
- `SecurityGroupHclModel` — typed `SgRule` list for ingress/egress; `WebServer()` preset
- `IamRoleHclModel` — inline policies + managed ARNs; `LambdaExecution()` and `Ec2InstanceProfile()` presets
- `HclGenerationRequest` — `TemplateName`, `Model`, `OutputPath?`, `OverwriteManaged`
- `HclGenerationResult` — `Success`, `Content`, `OutputPath?`, `WasWritten`, `ErrorMessage?`, `ManagedBlockKeys`

**HCL Generator** (`HclGenerator`)
- Loads templates from embedded resources via `Assembly.GetManifestResourceStream`
- PascalCase → snake_case member renamer for Scriban (e.g. `AmiId` → `ami_id`)
- `GenerateAsync` — renders template, merges with existing file (or creates new), writes atomically
- `OverwriteManaged=false` mode: skips re-generation of blocks already present in target file
- Strongly-typed convenience methods: `GenerateEc2InstanceAsync`, `GenerateS3BucketAsync`, `GenerateSecurityGroupAsync`, `GenerateIamRoleAsync`
- `GenerateModuleAsync(moduleName, model, outputDir)` — generates main.tf + variables.tf + outputs.tf into a directory; silently skips missing module templates
- `AvailableTemplates` property enumerates all embedded `.tf.tpl` resources
- Registered in DI as `services.AddSingleton<ITerraformHclGenerator, HclGenerator>()`

#### IaC — Import Service (Parte 4)

**Domain types** (`Services/Terraform/Import/`)
- `AwsResourceType` enum — `Ec2Instance`, `SecurityGroup`, `Vpc`, `Subnet`, `S3Bucket`, `IamRole`, `IamUser`
- `TagFilter` record — `(string Key, string? Value)` — null value matches any tag value
- `ImportOptions` — `Region`, `ResourceTypes`, `TagFilters`, `MaxResourcesPerType`, `IncludeTerminated`, `IncludeAwsManagedResources`; static presets: `ComputeOnly()`, `StorageOnly()`, `IamOnly()`, `NetworkOnly()`, `ForEnvironment(env)`
- `ImportConfidence` enum — `High` (Name tag present) / `Medium` (identifiable by ID) / `Low` (ambiguous)
- `DiscoveredResource` — `AwsId`, `ResourceName`, `SuggestedTfName`, `TerraformType`, `ResourceAddress` (computed), `ImportId`, `Region`, `Tags`, `Confidence`, `Notes`, `HclModel`
- `HclSuggestion` — pairs a `DiscoveredResource` with its `HclGenerationResult`
- `ImportAnalysisResult` — `Resources`, `CountByType`, `PartialErrors`, `Duration`; computed properties `HighConfidence`, `NeedsReview`, `TotalDiscovered`

**`IImportService` interface**
- `DiscoverResourcesAsync(options, progress?, ct)` → `ImportAnalysisResult`
- `GenerateImportBlocksAsync(resources, ct)` → `string` (Terraform HCL)
- `SuggestHclFromExistingResourcesAsync(resources, outputDir?, ct)` → `IReadOnlyList<HclSuggestion>`

**`ImportService` implementation**
- Resource discovery runs per-type in parallel via `Task.WhenAll`; each type is wrapped in `SafeDiscoverAsync` — failures isolated to `ImportAnalysisResult.PartialErrors`, never crash the whole scan
- **EC2**: `DescribeInstances` with state filter (excludes terminated by default) + tag filter; builds `Ec2InstanceHclModel` during discovery; notes: stopped state, missing key pair, missing IAM profile, IMDSv1 warning
- **Security Groups**: `DescribeSecurityGroups`; maps `IpPermission` → `SgRule` (supports IPv4/IPv6/protocol -1); skips default SG unless `IncludeAwsManagedResources`
- **VPC**: `DescribeVpcs`; skips default VPC unless `IncludeAwsManagedResources`; notes CIDR block
- **Subnet**: `DescribeSubnets`; skips default-for-AZ subnets; notes AZ + CIDR
- **S3**: `ListBuckets` + `GetBucketTagging` per-bucket for tag filtering; handles `NoSuchTagSet` gracefully
- **IAM Roles**: `ListRoles` with pagination; skips `/aws-service-role/` and `AWSServiceRoleFor*` by default; confidence = Low for AWS-managed
- **IAM Users**: `ListUsers` with pagination; notes users who never logged in via console
- `SanitizeTfName` — converts any string to valid snake_case Terraform identifier (no leading digits)
- `GenerateImportBlocksAsync` — Terraform 1.5+ `import { to = …; id = … }` blocks wrapped in ATLAS-MANAGED markers; legacy `terraform import` CLI command as comment
- `SuggestHclFromExistingResourcesAsync` — dispatches each resource to the appropriate `ITerraformHclGenerator` method (ec2/s3/sg/iam_role); groups output by resource type into one `.tf` file per type; skips types without a template with an informative error result
- Changed to `services.AddSingleton<IImportService, ImportService>()` in Parte 5 (safe — no mutable state)

#### IaC — TerraformService orchestrator (Parte 5)

**`TerraformOperationResult`** — unified result for all `ITerraformService` operations
- `Success`, `OperationName`, `ErrorMessage`, `Output`, `Duration`
- `WrittenFiles` — absolute paths of `.tf` files written
- `GeneratedBlocks` — ATLAS-MANAGED block keys created/updated
- `CliResult` — raw `TerraformResult` from plan/apply/validate
- `ImportAnalysis` — `ImportAnalysisResult` from discovery operations
- `HclSuggestions` — list of `HclSuggestion` from HCL generation
- `Steps` — `IReadOnlyList<OperationStep>` (name, success, message, duration per step)
- Computed: `PlanHasChanges`, `ResourcesFound`, `HasCliResult`, `HasImport`

**`OperationStep`** — lightweight step record with `Ok`/`Err` factories

**`ITerraformService`** interface
- `ActiveProject` — first initialized project, or first project if none initialized
- `GenerateAndWriteResourceAsync(object model, projectId?, ct)` — auto-dispatches by model type to typed HCL generator; writes to `{project}/{type}_s.tf`
- `GenerateEc2ResourceAsync(Ec2InstanceHclModel, projectId?, ct)` — typed EC2 shortcut
- `GenerateS3ResourceAsync(S3BucketHclModel, projectId?, ct)` — typed S3 shortcut
- `ImportExistingResourcesAsync(ImportOptions, generateHcl, progress, ct)` — discover + write `imports.tf` + optionally generate HCL
- `SyncWithAwsAsync(progress, ct)` — full sync: init → discover all → imports.tf → HCL files → validate
- `EnsureInitializedAsync(ct)` — runs `terraform init` only if not already initialized
- `RunPlanAsync(progress, ct)` — `terraform plan -detailed-exitcode`; saves plan to `.atlas_plan.tfplan`
- `ApplyChangesAsync(progress, ct)` — uses saved plan if present; cleans up plan file after apply

**`TerraformService`** implementation
- Resolves active project: first initialized project, then first available
- Builds `TerraformAwsCredentials` from `IAccountService.ActiveAccount` at call time
- `GenerateAndWriteResourceAsync` dispatches by C# type: `Ec2InstanceHclModel` → `GenerateEc2InstanceAsync`, `S3BucketHclModel` → `GenerateS3BucketAsync`, etc.; falls back to generic `GenerateAsync` for unknown models
- `SyncWithAwsAsync` orchestrates: EnsureInitialized → ImportExisting(all types) → terraform validate; non-fatal validate failure is recorded in Steps but does not fail the operation
- `ImportExistingResourcesAsync` fills missing `Region` from `IAccountService.ActiveRegion`
- `WriteWithMergeAsync` uses `HclMergeEngine` to safely merge into existing files
- `ApplyChangesAsync` prefers saved plan file over fresh apply; cleans up `.atlas_plan.tfplan` after success
- DI: `services.AddSingleton<ITerraformService, TerraformService>()`; `IImportService` also upgraded to `Singleton`

#### Onboarding — Add Account wizard multi-step

**AddAccountDialog — página 2 (Next action)**
- Após validação bem-sucedida das credenciais, em vez de fechar, o diálogo transita para uma segunda página com o título "Account Connected"
- Três opções de próximo passo apresentadas como cards clicáveis com hover state:
  - **Open project** — ícone `HardDrive`; abre um projeto local existente (fecha o diálogo com `NextAction = "open"`)
  - **Clone repository** — ícone `Download`; clona um repositório Git (fecha com `NextAction = "clone"`)
  - **Import from AWS** — ícone `Cloud`; avança para a página 3 de configuração do import
- Botão "Skip for now" no rodapé fecha sem ação adicional
- Botão "← Back" disponível na página 3 para regressar à seleção

**AddAccountDialog — página 3 (Import from AWS setup)**
- Campo **Stack name** — título da stack a criar
- Campo **Destination folder** com botão Browse que abre `OpenFolderDialog`
- Botão **"Create & Import"** valida os campos e fecha o diálogo com `NextAction = "import"`, `StackName`, `ProjectPath`
- Feedback de erro inline caso algum campo esteja vazio

**`AddAccountResult`** — novo record em `IDialogService.cs`
- `record AddAccountResult(bool Added, string? NextAction, string? StackName, string? ProjectPath)`
- `IDialogService.ShowAddAccountDialog()` alterado de `bool` para `AddAccountResult`
- `DialogService` atualizado para expor todos os campos do diálogo

**`DashboardViewModel`**
- `OpenAddAccountDialog` usa `AddAccountResult` em vez de `bool`
- Nova `Action<string, string>? ImportFromAwsRequested` — disparada com `(stackName, projectPath)` quando `NextAction == "import"`

---

#### IaC — Stacks view (Parte 7)

**Data layer**
- `StackEntry` model — `Id`, `Name`, `ProjectPath`, `Status` (`Ready`, `Queued`, `Running`, `Finished`, `Failed`), `CreatedAt`, `List<StackRun> Runs`
- `StackRun` model — `Id`, `StackId`, `Type` (`Import`, `Init`, `Plan`, `Apply`), `Status` (`Running`, `Success`, `Failed`, `Cancelled`), `Output`, `TriggerLabel?`, `StartedAt`, `CompletedAt?`; computed `Duration` e `DurationText`
- `IStackRepository` / `StackRepository` — CRUD completo com persistência em `%AppData%\Atlas\stacks.json` via `System.Text.Json`; `JsonStringEnumConverter` garante legibilidade do ficheiro; cache em memória por sessão; load lazy na primeira leitura

**ViewModel layer**
- `StackRunViewModel` (`ObservableObject`) — `[ObservableProperty] Status`, `Output`, `IsExpanded`; `TypeLabel`, `StartedText`, `DurationText`, `TriggerText`, `StatusBadgeText`, `StatusColor` (hex); `AppendOutput(line)` — acumula output e atualiza o model subjacente; `Complete(status)` — sella `CompletedAt` e notifica propriedades derivadas; `ToggleOutputCommand`
- `StackEntryViewModel` (`ObservableObject`) — `[ObservableProperty] Status`, `IsExpanded`; `Name`, `ProjectPath`, `CreatedText`, `RunCount`, `StatusBadgeText`, `StatusBadgeColor`, `StatusBadgeBg` (com canal alpha, e.g. `#1A4ADE80`); `ObservableCollection<StackRunViewModel> Runs`; `ToggleExpandCommand`; `AddRun(StackRun)` despacha no UI thread; `UpdateStatus()` e `NotifyRunCountChanged()`
- `StacksViewModel` (`ObservableObject`) — carrega stacks do repositório ordenadas por `CreatedAt desc`; `BeginImportAsync(name, path)`:
  1. Cria `StackEntry` + dois `StackRun` (Init e Import), persiste e exibe imediatamente
  2. Regista `TerraformProjectConfig` via `ITerraformProjectManager.SaveProject()`
  3. Executa `ITerraformCliWrapper.InitAsync()` com `IProgress<string>` → output em tempo real
  4. Em caso de falha do init: marca ambas as runs como `Failed`, stack como `Failed`, persiste e sai
  5. Executa `IImportService.DiscoverResourcesAsync()` com `ImportOptions` default (todos os tipos, sem tags, sem terminados, sem AWS-managed)
  6. Escreve `imports.tf` via `IImportService.GenerateImportBlocksAsync()`
  7. Gera ficheiros HCL via `IImportService.SuggestHclFromExistingResourcesAsync()` com `outputDir`
  8. Finaliza runs e persiste estado final (Ready/Failed)

**View — `StacksView.xaml`**
- Cabeçalho com título "Stacks" e subtítulo descritivo
- Estado vazio com ícone `Layers` e instrução para importar do Dashboard
- Lista de stacks (`ItemsControl`), cada card (`Card` style, padding zero):
  - **Header clicável** (`Button` com template custom): chevron rotativo (0° → 90° com `DataTrigger`), nome + badge de run count, meta row (Created date · caminho do projeto), badge de estado com cor dinâmica via `HexToBrush` converter; ponto pulsante visível apenas em estado `Running`
  - **Expansão** (visível quando `IsExpanded`): divider, tabela de cabeçalhos (Status · Type · Date · Duration · Logs) com background `SidebarActiveBrush`
  - **Linha de run**: badge de status colorido com ícone contextual (✓ `Check`, ⟳ `LoaderCircle`, ✕ `X`, `Minus` para Cancelled), badge de tipo (`IMPORT`/`INIT`/`PLAN`/`APPLY` em `AccentBrush`), texto de trigger + data formatada, duração em Consolas, botão "Show/Hide" para painel de output
  - **Painel de output** (expansível por run): `ScrollViewer` + `TextBox` read-only em Consolas 11.5pt, `MaxHeight=280`, `Background="#0D000000"` para distinguir do card

**`HexStringToBrushConverter`** — novo converter em `Helpers/Converters.cs`
- Converte string hex `#RRGGBB` ou `#AARRGGBB` para `SolidColorBrush` via `ColorConverter.ConvertFromString`; registado em `App.xaml` como `{StaticResource HexToBrush}`

**Navigation & DI**
- `NavigationPage.Stacks` adicionado ao enum (free tier, não Pro-gated)
- Sidebar "Stacks" (ícone `Layers`) atualizado de `NavigationPage.IaC` para `NavigationPage.Stacks`
- `DataTemplate` registado em `MainWindow.xaml`: `StacksViewModel` → `StacksView`
- `StacksVM` injetado no construtor de `MainViewModel`; `NavigateTo` switch atualizado
- `DashboardVM.ImportFromAwsRequested` fiado em `MainViewModel`: navega para Stacks e chama `StacksVM.BeginImportAsync(name, path)`
- DI em `App.xaml.cs`: `IStackRepository → StackRepository` (singleton), `StacksViewModel` (singleton)
- Command Palette: "Go to Stacks" com keywords `stacks, terraform, runs, import, plan, apply, history`

---

#### IaC — Stacks: Pipeline visual e melhorias de UX (sessão 2)

**Bug fix — runs duplicadas**
- Corrigido bug no `BeginImportAsync` que criava as runs duplicadas: os `StackRun` eram adicionados a `stack.Runs` antes da criação do `StackEntryViewModel` (o construtor já os carregava), e depois `AddRun()` era chamado novamente para cada run
- `AddRun()` é agora a única fonte de verdade — adiciona ao `_entry.Runs` e à `ObservableCollection<StackRunViewModel>` atomicamente
- `Load()` passa a chamar `WireRunRequested()` em todos os stacks carregados do repositório

**Pipeline visual — ícones circulares estilo Bitbucket**
- Substituídos os badges de texto (`SUCCESS`, `RUNNING`, `FAILED`) por ícones circulares por run:
  - **Success**: círculo verde (`#16A34A`) preenchido com checkmark branco
  - **Failed**: círculo vermelho preenchido com X branco
  - **Running**: arco azul animado (rotação contínua via `DoubleAnimation`, 1 s por volta)
  - **Cancelled**: círculo outline cinzento com traço horizontal
- Ícone reduzido de 22 px para 16 px; coluna de status encolhida de 110 px para 36 px

**Pipeline visual — linha conectora**
- Cada run row usa um `Grid` de 3 rows (linha acima / ícone / linha abaixo) com `VerticalAlignment="Stretch"` para que os segmentos toquem as rows adjacentes sem espaço
- `BoolToHiddenConverter` adicionado (`true → Hidden`, preserva espaço) — distingue-se de `BoolToInvisibleConverter` que usa `Collapsed`
- `IsFirst` e `IsLast` adicionados a `StackRunViewModel`; `RefreshConnectors()` em `StackEntryViewModel` recalcula após cada `AddRun()`
- Linha removida no topo do primeiro item e no fundo do último; a cor da linha é `#16A34A` (verde escuro, igual aos ícones de sucesso)
- Row border alterada de `Padding="20,10"` para `Padding="0"` + `MinHeight="44"` para eliminar gaps verticais que interrompiam a linha; padding horizontal redistribuído por coluna

**Actions dropdown por stack**
- Botão **Actions ▾** adicionado ao cabeçalho de cada stack (novo `ColumnDefinition Width="Auto"` entre o nome e o badge de estado)
- Usa `Menu` / `MenuItem` WPF com header customizado (texto + chevron SVG)
- Itens: **Init**, **Import**, separador, **Apply**, separador, **Remove Stack** (a vermelho via `DangerBrush`)
- `RunInitCommand`, `RunImportCommand`, `RunApplyCommand`, `RemoveStackCommand` adicionados a `StackEntryViewModel` com `[RelayCommand]`
- `RunRequested: Action<StackEntryViewModel, StackRunType>` e `RemoveRequested: Action<StackEntryViewModel>` expostos e fiados em `WireRunRequested()`

**Remove Stack**
- **Actions → Remove Stack** remove o stack da colecção e do `stacks.json` via `IStackRepository.Delete()`; ficheiros em disco são preservados

---

#### IaC — Import "full": pipeline completo + cobertura de serviços AWS

**Pipeline de 4 runs**

| Run | Trigger | O que executa |
|---|---|---|
| **INIT** | automático | Garante bucket de state S3 → escreve `provider.tf` → `terraform init` |
| **IMPORT** | automático | Descobre todos os recursos AWS → escreve `imports.tf` (blocos `import { }` TF 1.5+) |
| **PLAN** | automático | `terraform plan -generate-config-out=generated_resources.tf` — Terraform gera HCL completo a partir dos import blocks |
| **APPLY** | **manual** (Actions → Apply) | `terraform apply -auto-approve` — importa para o `.tfstate` |

- `PlanWithGenerateConfigAsync(workingDir, generateConfigOut, credentials?, progress?, ct)` adicionado a `ITerraformCliWrapper` e `TerraformCliWrapper`; apaga o ficheiro anterior antes de executar (evita erro "file already exists"); exit code 2 mapeado a `PlanHasChanges` (não é erro)
- `RunStepAsync` helper partilhado — cria a run, envolve o body em try/catch, marca success/fail, persiste e retorna `bool` para abortar o pipeline em caso de falha
- Após o PLAN, a mensagem no log indica explicitamente que o utilizador deve usar **Actions → Apply** para importar para o state
- `RunImportAsync` (manual) corre o mesmo pipeline completo: Import → Plan (Apply continua manual)

**S3 Remote State**
- `EnsureStateBucketAsync(region, progress?, ct)` adicionado a `IImportService` e `ImportService`
  - Obtém o `accountId` via STS `GetCallerIdentity` — garante unicidade global: nome do bucket `atlas-tfstate-{accountId}`
  - Cria o bucket apenas se não existir; região `us-east-1` não inclui `LocationConstraint` (comportamento correcto da API S3)
  - Activações automáticas no bucket criado: **versioning**, **bloqueio de acesso público** (todos os 4 flags), **encriptação SSE-KMS**
  - Graceful fallback para state local com aviso no output se a criação falhar (ex.: permissões insuficientes)
- `WriteProviderTfAsync` aceita agora `stateBucket?` e `stateKey?` e inclui o bloco `backend "s3" { … }` no bloco `terraform { }` do `provider.tf`; chave por stack: `stacks/{name}/terraform.tfstate`
- Credenciais **nunca** escritas em `provider.tf` — injectadas como env vars pelo `TerraformCliWrapper`

**Cobertura de serviços AWS — 35 tipos**

| Categoria | Tipos adicionados |
|---|---|
| Compute | `AutoScalingGroup`, `LaunchTemplate` (+ `Ec2Instance` já existia) |
| Networking | `RouteTable`, `InternetGateway`, `NatGateway`, `LoadBalancer` (ALB/NLB), `TargetGroup` (+ VPC, Subnet, SG já existiam) |
| Database | `RdsInstance`, `RdsCluster`, `DynamoDbTable`, `ElastiCacheCluster` |
| Serverless | `LambdaFunction`, `ApiGatewayRestApi` |
| Containers | `EcsCluster`, `EcsService`, `EcrRepository`, `EksCluster` |
| Messaging | `SqsQueue`, `SnsTopic` |
| IAM | `IamGroup`, `IamPolicy` (customer-managed) (+ Role, User já existiam) |
| Security | `KmsKey`, `SecretsManagerSecret`, `AcmCertificate` |
| DNS | `Route53HostedZone` |
| Monitoring | `CloudWatchLogGroup`, `CloudWatchAlarm` |

- NuGet packages adicionados: `AWSSDK.AutoScaling`, `AWSSDK.Lambda`, `AWSSDK.ECS`, `AWSSDK.ECR`, `AWSSDK.EKS`, `AWSSDK.RDS`, `AWSSDK.DynamoDBv2`, `AWSSDK.ElastiCache`, `AWSSDK.ElasticLoadBalancingV2`, `AWSSDK.SQS`, `AWSSDK.SimpleNotificationService`, `AWSSDK.APIGateway`, `AWSSDK.KeyManagementService`, `AWSSDK.SecretsManager`, `AWSSDK.CertificateManager`, `AWSSDK.CloudWatchLogs`, `AWSSDK.Route53`
- `AwsClientFactory` refactorizado com método genérico `Get<T>(service, creds, factory)` para eliminar repetição; factory methods adicionados para todos os novos serviços
- Conflitos de nomes entre SDKs resolvidos com aliases de namespace (`EcsModel`, `EksModel`, `AsgModel`, `ElbModel`, `R53Model`, `CwModel`, `Ec2Filter`, `Ec2Tag`)
- Todos os discovery methods suportam paginação (`NextToken`/`Marker`) e respeitam `MaxResourcesPerType`
- `EcsService` discovery itera clusters primeiro e depois os serviços por cluster; import id usa o formato `cluster/service`
- `KmsKey` discovery ignora chaves AWS-managed (`KeyManagerType.AWS`) e chaves em `PendingDeletion`
- `IamPolicy` discovery usa `Scope = Local` para devolver apenas políticas customer-managed

---

#### IaC — Stacks: Fix de memória e performance no output de runs

**Problema**
- `AppendOutput(line)` fazia `Output = Output + line + "\n"` — concatenação O(n²), notificação WPF a cada linha, output sem limite crescia para centenas de MB em plans com 500+ recursos, causando UI freeze e scroll lento

**Solução — `StackRunViewModel` refactorizado**
- Output armazenado internamente em `List<string> _lines` com `lock` thread-safe
- **Limite de 1 500 linhas** por run em memória: quando ultrapassado, remove as 200 linhas mais antigas e activa flag `_wasTrimmed`; cabeçalho `[⚠ earlier output not shown — N lines total]` adicionado automaticamente ao display
- **Debounce de UI**: `OnPropertyChanged("Output")` disparado apenas a cada 15 linhas (`NotifyEveryLines = 15`) em vez de a cada linha
- **`BeginInvoke`** (assíncrono) em vez de `Invoke` (bloqueante) para actualizações de Output — o thread de I/O do processo terraform nunca bloqueia à espera do dispatcher WPF
- **Persistência limitada**: apenas as últimas 300 linhas (`MaxPersistLines`) são escritas em `_run.Output` e guardadas no `stacks.json` — evita ficheiros de centenas de MB
- `Complete()` chama `FlushToUi(persist: true)` para garantir que o output final é sempre exibido e persistido, independentemente do debounce
- Re-hydratação de stacks carregados do disco reconstrói `_lines` a partir de `run.Output` sem passar pelo caminho de flush

**Output panel (XAML)**
- `IsUndoEnabled="False"` no `TextBox` — elimina o undo buffer interno do WPF (era um leak silencioso que crescia com cada `Text` change)
- `MaxHeight` aumentado de 280 px para 320 px; `CanContentScroll="True"` no `ScrollViewer`

---

#### IaC — Stacks: Import S3 estável + UX da pipeline (2026-06-10)

**Import restrito a S3 (passo incremental)**
- `ImportOptions.ResourceTypes` explicitamente definido como `[AwsResourceType.S3Bucket]` em `BeginImportAsync` e `RunImportAsync` — discovery deixa de tentar todos os 35 tipos simultaneamente; mensagens de progresso atualizadas para "S3 buckets"
- `GeneratedHclFixer` simplificado: mantém apenas a remoção de `tags_all = {}` (provider-managed); todas as correções específicas de Lambda, Subnet, RouteTable, ACM, DynamoDB, API Gateway, VPC e runtime foram removidas (não relevantes para S3)
- `s3_bucket.tf.tpl` corrigido para contexto de import:
  - Removidas tags hardcoded `Name` e `ManagedBy = "Atlas"` — passavam a ser drift detectado no plan (90 buckets "to change")
  - Bloco `aws_s3_bucket_public_access_block` tornado condicional: só gerado quando algum dos 4 flags `block_public_acls/policy/ignore/restrict` está `true`
  - Bloco `aws_s3_bucket_server_side_encryption_configuration` já era condicional via `{{- if server_side_encryption }}`
- `DiscoverS3Async` em `ImportService`: modelo S3 criado com todos os flags de sub-recursos a `false` durante import — elimina os 180 "to add" (90 public_access_block + 90 encryption_configuration) que surgiam no plan
- Resultado esperado do plan após correções: **90 to import, 0 to add, 0 to change, 0 to destroy**
- Condição de falha do `generated_resources.tf` relaxada: quando o Atlas já escreveu HCL via templates próprios (`written > 0`), a ausência do ficheiro gerado pelo Terraform é tratada como sucesso (Terraform não cria o ficheiro quando todos os recursos já têm definição HCL)

**Pipeline unificada — single run**
- `BeginImportAsync` e `RunImportAsync` colapsados de 3–4 runs separadas (Init / Import / Fix / Plan) para **um único `StackRun` de tipo `Import`**
- Secções separadas por cabeçalhos no output (`━━━ Init`, `━━━ Import`, `━━━ Plan`)
- Passo **Fix** (correcção de schema HCL + extracção de env vars) executa inline dentro do run único, sem entry própria na lista de runs

**Auto-expand e auto-scroll de logs**
- `RunStepAsync` faz `vm.IsExpanded = true` imediatamente ao criar o run — logs visíveis automaticamente sem o utilizador ter de clicar
- `ScrollBehavior` (novo `Helpers/ScrollBehavior.cs`) — attached behavior para `ScrollViewer`:
  - Quando novo conteúdo chega e o utilizador está no fundo: scroll automático para o fim
  - Quando o utilizador faz scroll manual para cima: auto-scroll suspenso
  - Quando o utilizador regressa ao fundo: auto-scroll retomado
  - Implementado via `ScrollChanged` event + `ConditionalWeakTable<ScrollViewer, StickState>` (sem leaks de memória)
- `helpers:ScrollBehavior.AutoScroll="True"` aplicado ao `ScrollViewer` do painel de output em `StacksView.xaml`

**UX da pipeline**
- **Row clicável**: border do run row convertida num `Button` com `ToggleOutputCommand` + hover highlight — clicar em qualquer ponto da linha expande/colapsa os logs; botão "Show/Hide" redundante removido
- **Botão Copy nos logs**: `CopyOutputCommand` adicionado a `StackRunViewModel`; botão "Copy" (ícone `Icon.Copy` + texto) posicionado no canto superior direito do painel de output como overlay
- `Icon.Copy` adicionado a `LucideIcons.xaml` — dois rectângulos sobrepostos (Lucide copy icon)
- **Scroll thumb mínimo**: `<Thumb MinHeight="40">` no template vertical do `ScrollBar` em `ControlStyles.xaml` — thumb nunca fica menor que 40 px mesmo com logs muito longos
- **Linhas conectoras cinza**: `Rectangle.Fill` das linhas acima/abaixo dos ícones alterado de `#16A34A` para `{DynamicResource TextMutedBrush}`; ícone de sucesso (Ellipse verde) mantém `Fill="#16A34A"`

---

#### IaC — Stacks: Seleção de recursos no import + Create new stack (2026-06-10)

**Ecrã de seleção de recursos (checkbox screen)**
- Novo `ImportSelectionDialog` (`Views/ImportSelectionDialog.xaml`) — após a discovery, mostra todos os recursos encontrados agrupados em 10 categorias: Compute, Networking, Storage, Database, Serverless, Containers, Messaging, IAM, Security, DNS/Monitoring
- Checkbox tri-state por categoria (seleciona/desseleciona o grupo inteiro; estado parcial quando só alguns itens estão marcados) + checkbox individual por recurso
- Cada linha mostra badge do tipo (EC2, VPC, Lambda, …), nome do recurso e AWS ID; botões "Select all" / "Deselect all"; contador "N of M selected"; botão Import desativado com 0 selecionados
- `DiscoverAndSelectAsync` — novo helper partilhado em `StacksViewModel` que unifica discovery + seleção nas duas pipelines (`BeginImportAsync` e `RunImportAsync`); apenas os recursos selecionados vão para `imports.tf` / geração HCL
- Cancelar o diálogo marca o run como **CANCELLED** (novo suporte em `RunStepAsync`: body devolve `bool?` — `null` = cancelado, stack volta a Ready)
- `IDialogService.ShowImportSelectionDialog` + implementação em `DialogService`

**Create new stack**
- Botão accent "Create new stack" no header da view Stacks (mesmo estilo do "Launch instance" da view EC2)
- Novo `CreateStackDialog` — pede nome do stack + pasta de destino (com Browse); valida nome duplicado antes de arrancar
- `CreateNewStackCommand` em `StacksViewModel` inicia a pipeline completa de import (com o novo ecrã de seleção)

**Fix — validation plan no Import manual**
- `RunImportAsync` ainda usava `PlanWithGenerateConfigAsync` no passo de validação (apaga e regenera `generated_resources.tf`, anulando as correções do `GeneratedHclFixer`) — trocado por `PlanAsync` nas duas chamadas (plan inicial + retry), igual ao fix aplicado em `BeginImportAsync`

#### S3 — Editor de ficheiros inline (2026-06-12)

**Abertura por duplo-clique**
- Duplo-clique num ficheiro na object browser do S3 abre o editor inline (se o ficheiro for editável); duplo-clique numa pasta continua a navegar para dentro da pasta
- `IsTextEditable(S3ObjectModel)` — método estático em `S3ViewModel` que verifica extensão (50+ tipos: `.json`, `.yaml`, `.tf`, `.py`, `.cs`, `.sh`, `.md`, `.sql`, `.env`, …) e nomes de ficheiro conhecidos (`Dockerfile`, `Makefile`, `Gemfile`, `.gitignore`, …); ficheiros > 5 MB são excluídos automaticamente
- `OpenFileEditorCommand` — `[AsyncRelayCommand]` em `S3ViewModel`: carrega conteúdo via `GetFileContentAsync`, abre o diálogo, e se o utilizador guardar chama `PutFileContentAsync` e refresca a listagem de objetos

**Monaco Editor (VS Code engine)**
- `S3FileEditorDialog` — nova janela (`Views/S3FileEditorDialog.xaml` + `.xaml.cs`)
- Monaco Editor 0.50.0 carregado via CDN (`cdn.jsdelivr.net/npm/monaco-editor@0.50.0`) dentro de um `WebView2`; tema `vs-dark`, Consolas 13 px, números de linha, folding, sem minimap
- Detecção automática de linguagem por extensão para 25+ tipos: `json`, `yaml`, `hcl`, `typescript`, `python`, `csharp`, `rust`, `sql`, `dockerfile`, `makefile`, `shell`, `plaintext`, …
- Atalho **Ctrl+S** dentro do editor dispara o Save sem sair do teclado

**Janela personalizada (sem barra branca do OS)**
- `WindowStyle="None"` + `WindowChrome` (`CaptionHeight="34"`, `ResizeBorderThickness="6"`, `GlassFrameThickness="0"`) — elimina o chrome nativo do Windows mantendo redimensionamento completo
- Header de 34 px (`#2d2d30`) com: ícone de ficheiro, nome do ficheiro em Consolas, caminho relativo em cinzento, indicador "● Modified" a âmbar
- Botões Min / Max-Restore / Close com `WindowChrome.IsHitTestVisibleInChrome="True"`; Close com hover vermelho (`#c42b1c`), Min/Max com hover `#3f3f46`; ícone □/❐ actualizado em `Window_StateChanged`; margem de 6 px adicionada quando maximizado para não sobrepor a taskbar

**Barra de status (footer)**
- Barra inferior de 30 px (`#007acc`) com: posição do cursor (`Ln N, Col N`), contagem de linhas, linguagem activa, codificação `UTF-8`
- Botão **Cancel** (fecha sem guardar) e botão **Save** (desactivado até o editor estar pronto)

**Estratégia de Save fiável**
- Monaco envia o conteúdo completo via `postMessage` debounced a 400 ms a cada alteração; C# armazena em `_cachedContent` no background thread
- `Save_Click` executa `ExecuteScriptAsync("window._editor.getValue()")` para capturar as últimas teclas dentro da janela de debounce; em caso de falha usa `_cachedContent`; `CommitSave()` é síncrono — define `EditedContent`, `Saved = true` e `Close()`
- Ctrl+S: se a mensagem "save" chegar com `content` já enviado, chama `CommitSave()` directamente; caso contrário faz flush via `FlushAndSaveAsync()`

**Camada de serviço**
- `IS3Service` — dois novos métodos: `GetFileContentAsync(bucket, key, ct)` e `PutFileContentAsync(bucket, key, content, ct)`
- `S3Service` — `GetFileContentAsync`: usa `GetObjectAsync` + `StreamReader` com detecção de BOM; `PutFileContentAsync`: codifica como UTF-8, envolve em `MemoryStream`, infere `ContentType` pela extensão (json, yaml, xml, html, css, js, md, csv, sh, …), chama `PutObjectAsync`
- `TerraformAwareS3Service` — passthrough para ambos os novos métodos
- `IDialogService` — novo método `ShowS3FileEditor(fileKey, content)`; `DialogService` instancia `S3FileEditorDialog`, chama `ShowDialog()` e devolve o conteúdo editado ou `null` se cancelado

---

### Removed

- **Settings → Infrastructure**: tab removida da view Settings (botão + conteúdo "Add Terraform Project" / "Configured Projects"); `SettingsTab.Infrastructure` removido do enum; `TerraformVM` removido de `SettingsViewModel`; a página IaC própria mantém-se inalterada

### Build

- `nuget.config`: adicionado `<package pattern="System.Diagnostics.EventLog"/>` ao mapping de nuget.org — `Microsoft.Extensions.Hosting 9.0.17` (floating `9.0.*`) passou a exigir `System.Diagnostics.EventLog 9.0.17`, que só existia na cache local até 9.0.16

---

#### IaC — Integração com Serviços Existentes (Parte 6)

**Decorator pattern — sem modificar os serviços originais**
- `TerraformAwareEc2Service` wraps `IEc2Service`; após `LaunchInstanceAsync` dispara em background `ITerraformService.GenerateEc2ResourceAsync` com `Ec2InstanceHclModel` construído a partir de `LaunchInstanceOptions` (AMI, instance type, subnet, key pair, security group, IAM profile, user data, monitoring, termination protection, root volume)
- `TerraformAwareS3Service` wraps `IS3Service`; após `CreateBucketAsync` dispara em background `ITerraformService.GenerateS3ResourceAsync` com `S3BucketHclModel` construído a partir de `CreateBucketOptions` (block public access flags, versioning, SSE, tags)
- Ambos os decorators são fire-and-forget — não adicionam latência à operação AWS principal; erros são silenciados para `FileLogger`
- DI: concretos registados directamente (`Ec2Service`, `S3Service`) + decoradores registados como factory delegates para `IEc2Service`/`IS3Service`

**`Ec2ViewModel` — Sync to Terraform**
- Injecção de `ITerraformService terraform` no construtor
- `[ObservableProperty] IsTerraformSyncing` / `TerraformSyncMessage` / `TerraformSyncSuccess`
- `HasTerraformProject` — computed property, true quando `ITerraformService.ActiveProject != null`
- `SyncToTerraformCommand` — gera HCL para instâncias seleccionadas (ou todas carregadas, limit 100); usa `Ec2InstanceHclModel.FromAtlasInstance()`; mostra resultado inline; falhas por instância são logged sem abortar o lote

**`S3ViewModel` — Sync to Terraform**
- Mesma estrutura que `Ec2ViewModel`
- `SyncToTerraformCommand` — gera HCL para buckets seleccionados (ou todos carregados, limit 100); usa `S3BucketHclModel.FromAtlasBucket()`

---

## [0.0.1] — 2026-06-02

### Initial release

First public build of **Atlas** — a desktop AWS management client for Windows built on WPF / .NET 9.

---

### Added

#### Shell & Navigation
- Sidebar navigation with radio-button items and a 3 px blue active indicator
- Pages: Dashboard, EC2 Instances, S3 Buckets, IAM, Billing, CloudWatch, GuardDuty, Settings
- PRO gating: IAM, Billing, CloudWatch, and GuardDuty are locked behind an upgrade prompt on free tier
- Theme toggle (☀ / 🌙) in the top bar — switches between Dark and Light themes at runtime without restart
- Active account picker in the top bar — switching accounts reloads all page data automatically
- Global resource search bar

#### Dashboard
- KPI cards: EC2 Running, EC2 Stopped, S3 Buckets, Active CloudWatch Alarms
- Account ID display and last-refreshed timestamp
- Manual Refresh button
- "No account configured" empty state with guidance to open Settings
- Loading overlay and error banner
- Dashboard API calls execute concurrently — a single failed permission does not block the rest
- Cost Explorer integration: costs and usage overview panel

#### EC2 Instances
- Table with columns: State badge, Name, Instance ID, Type, Public IP, Private IP, Launch Time
- Real-time search by name, instance ID, or IP address
- Status filter dropdown: All / running / stopped / pending / terminated
- Color-coded state badges (green, red, amber, purple, gray)
- Multi-select via row checkboxes plus header select-all toggle
- Batch actions: Start, Stop, Reboot, Terminate — all require a confirmation dialog
- Auto-reload after any batch action completes
- Instance detail side panel (slides in when exactly one row is selected):
  - Summary: ID, state, type, vCPUs, IPs, region, DNS, VPC/Subnet, IAM role, ASG, IMDSv2, ARN
  - Details: AMI ID, monitoring, platform, key pair, launch time, virtualization, lifecycle, boot mode, credit spec
  - Host & placement: tenancy, host ID, affinity, placement group, partition, reservation
  - Capacity reservation fields
- Ctrl+A shortcut hint in the action bar
- Minimum column widths with horizontal scroll instead of column collapse

#### S3 Buckets
- Bucket list panel (left) with name and creation date
- Object browser panel (right) — click a bucket to load its contents
- Object table columns: Key/Name, Size (auto-formatted B / KB / MB / GB), Storage Class, Last Modified
- Upload with real-time progress bar and percentage
- Download with save dialog and real-time progress bar and percentage
- Prefix-based folder-like navigation
- Empty state illustration when no bucket is selected

#### IAM *(PRO)*
- Accessible to PRO accounts

#### Billing *(PRO)*
- Accessible to PRO accounts

#### CloudWatch *(PRO)*
- Alarms list with state filter chips: All / ALARM / OK / INSUFFICIENT_DATA
- Real-time text search across alarms
- KPI cards per alarm state

#### GuardDuty *(PRO)*
- Findings list with severity filter chips: All / HIGH / MEDIUM / LOW
- Real-time text search across findings
- KPI cards per severity level

#### Account Management (Settings)
- Add AWS accounts: Name, Access Key ID, Secret Access Key (masked), Default Region
- 12 supported regions in the dropdown
- Validate & Add Account — verifies credentials via STS `GetCallerIdentity` before saving
- Inline validation feedback (green / red)
- Account list with name, access key ID, region, and active badge
- Set Active and Remove buttons; next account activates automatically when the active one is removed

#### Confirm Dialog
- Frameless modal matching application theme (no native Windows chrome)
- Draggable header, rounded corners, deep drop-shadow
- Default variant (blue icon + button) for Start / Stop / Reboot
- Danger variant (red icon + button) for Terminate, with explicit irreversibility warning
- Centered over the main window

#### Themes
- Full Dark and Light theme support via `ResourceDictionary` swap at runtime
- Custom templates for all controls: TextBox, ComboBox, DataGrid, ScrollBar, CheckBox, ProgressBar, Buttons
- Design tokens: background, surface, border, accent, text primary/secondary, success, warning, danger

#### Security
- AWS secret keys encrypted with Windows DPAPI (user-scoped) before writing to SQLite
- Keys decrypted in memory only at the moment an AWS API call is made
- No plaintext credentials persisted on disk

#### Error Handling & Logging
- Unhandled UI, AppDomain, and Task exceptions caught at application level
- Errors written to `atlas-errors.txt` (application directory) in prepend mode — newest entries first
- Log format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] message` + full stack trace
- Recoverable errors show an error banner in the UI without crashing

#### Performance
- AWS SDK clients cached per `(service, region, access key)` — HTTP connections reused
- Cache fully invalidated on account switch
- Dashboard API calls run in parallel via `Task.WhenAll`
- Each ViewModel caches loaded data for 30 seconds — navigating back within that window skips a new API call
- In-flight loads cancelled via `CancellationToken` when a new load is triggered

#### Technology Stack
- Runtime: .NET 9.0 (Windows, x64)
- UI: WPF (XAML) + CommunityToolkit.Mvvm
- AWS SDK v3: EC2, S3, CloudWatch, CostExplorer, SecurityToken, GuardDuty
- Local database: SQLite via Microsoft.Data.Sqlite
- DI: Microsoft.Extensions.Hosting
- Credential security: Windows DPAPI

---

[0.0.1]: https://github.com/your-org/atlas/releases/tag/v0.0.1
