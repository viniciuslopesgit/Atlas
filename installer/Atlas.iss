#define AppName      "atlas"
#define AppVersion   "0.0.2"
#define AppPublisher "UM, LDA"
#define AppExeName   "atlas.exe"
#define PublishDir   "..\atlas\bin\Release\net9.0-windows\win-x64\publish"

[Setup]
AppId={{A3F2C1D4-7E8B-4F5A-9C2E-1D3B6F4E8A7C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://cloud-atlas.io
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=Output
OutputBaseFilename=atlas_v{#AppVersion}
SetupIconFile=..\atlas\icon\atlas.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; Assinatura digital (opcional — descomenta se tiveres um certificado)
; SignTool=signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com $f

[Languages]
Name: "english";    MessagesFile: "compiler:Default.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Copia tudo da pasta publish recursivamente
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Ícone da aplicação (necessário para os atalhos)
Source: "..\atlas\icon\atlas.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\atlas.ico"
Name: "{autodesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\atlas.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Remove o ficheiro de log e a base de dados SQLite gerados em runtime
Type: files; Name: "{app}\atlas-errors.txt"
Type: files; Name: "{app}\atlas.db"
