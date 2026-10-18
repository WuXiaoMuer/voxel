; VoxelCraft - Windows installer
;
; Built by .github/workflows/build.yml with Inno Setup 6 (ISCC), on top of the portable
; build/windows/VoxelCraft.exe the Godot exporter produces. This is the ordinary Inno
; Setup shape for a single-file game: one payload, a Start menu entry, an optional desktop
; shortcut, and a "run it now" checkbox on the last page.
;
; The three paths the workflow needs -- the payload, the icon and where the installer
; itself is written -- arrive as ISCC /D defines, so this file never has to guess where it
; is being run from. The defaults below are for building it by hand from the repo root:
;
;     iscc /DAppVersion=1.0.0 tools\voxelcraft.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef PayloadDir
  #define PayloadDir "build\windows"
#endif
#ifndef IconFile
  #define IconFile "assets\icon\voxelcraft_deep.ico"
#endif
#ifndef DistDir
  #define DistDir "dist"
#endif

#define AppName "VoxelCraft"
#define AppExe "VoxelCraft.exe"
#define AppPublisher "WuXiaoMuer"
#define AppUrl "https://github.com/WuXiaoMuer/voxel"

[Setup]
AppId={{8F3A2C51-9B4E-4C7A-9E10-5D6C2B7A44E1}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; installs per user, so no administrator prompt is needed for a game that only copies
; one file and makes a shortcut
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExe}
OutputDir={#DistDir}
OutputBaseFilename=VoxelCraft-{#AppVersion}-setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; plain strings rather than Inno's message constants: the installer ships in English only,
; so there is nothing to localise, and a literal cannot be an unknown constant
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
