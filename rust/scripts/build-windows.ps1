# 构建 Windows x64 开发目录；不安装驱动、不启动 GUI、不触发媒体输入输出。
[CmdletBinding()]
param([switch]$Restore)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$rust = Join-Path $root 'rust'
$build = Join-Path $rust 'build/windows'
$publish = Join-Path $build 'app'
$project = Join-Path $rust 'windows/CallBridge.Windows/CallBridge.Windows.csproj'
$checks = Join-Path $rust 'windows/CallBridge.CoreChecks/CallBridge.CoreChecks.csproj'

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Environment]::OSVersion.Version.Build -lt 22000 -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This build supports Windows 11 x64 only (PowerShell 7).'
}
foreach ($tool in @('cargo', 'rustc', 'dotnet', 'node', 'npm', 'python')) { Get-Command $tool -ErrorAction Stop | Out-Null }
Invoke-Checked 'python' @('-c', 'import struct,sys; assert sys.version_info >= (3,11) and struct.calcsize("P")==8, "Python 3.11+ x64 required"')
Invoke-Checked 'node' @('-e', 'if(Number(process.versions.node.split(".")[0])<22||process.arch!=="x64")process.exit(1)')
New-Item -ItemType Directory -Force -Path $build, $publish | Out-Null
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'

# 缺失缓存直接失败；只有显式 -Restore 才允许工具下载构建依赖。
$cargoArgs = @('build', '--locked', '--release', '--manifest-path', (Join-Path $rust 'Cargo.toml'), '--target', 'x86_64-pc-windows-msvc')
if (-not $Restore) { $cargoArgs += '--offline' }
Invoke-Checked 'cargo' $cargoArgs
if ($Restore) {
    Invoke-Checked 'dotnet' @('restore', $project, '--locked-mode', '-r', 'win-x64', '-p:SelfContained=true')
    Invoke-Checked 'dotnet' @('restore', $checks, '--locked-mode')
}
Invoke-Checked 'dotnet' @('run', '--project', $checks, '--no-restore', '--', (Join-Path $rust 'target/x86_64-pc-windows-msvc/release/callbridge_abi_probe.dll'))
Invoke-Checked 'dotnet' @('publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '--no-restore', '-o', $publish)
Copy-Item (Join-Path $rust 'target/x86_64-pc-windows-msvc/release/callbridge_abi_probe.dll') $publish -Force

Push-Location (Join-Path $rust 'avatar')
try {
    if ($Restore) { Invoke-Checked 'npm' @('ci', '--ignore-scripts') }
    # 不调用 prepare.mjs：大模型必须由用户另行准备，本脚本只复用已校验素材。
    Invoke-Checked 'npm' @('run', 'build')
} finally { Pop-Location }
New-Item -ItemType Directory -Force -Path (Join-Path $publish 'runtime'), (Join-Path $publish 'avatar'), (Join-Path $publish 'avatar-host') | Out-Null
Copy-Item (Get-Command node).Source (Join-Path $publish 'runtime/node.exe') -Force
Copy-Item (Join-Path $rust 'build/avatar/*') (Join-Path $publish 'avatar') -Recurse -Force
Copy-Item (Join-Path $rust 'avatar/preview.jpg') (Join-Path $publish 'avatar/preview.jpg') -Force
Copy-Item (Join-Path $rust 'avatar/cloud-guides') $publish -Recurse -Force
foreach ($file in @('server.mjs', 'camera-bridge.mjs')) {
    Copy-Item (Join-Path $rust "avatar/scripts/$file") (Join-Path $publish 'avatar-host') -Force
}
Copy-Item (Join-Path $rust 'avatar/scripts/cloud') (Join-Path $publish 'avatar-host') -Recurse -Force

$venv = Join-Path $build 'camera-env'
$python = Join-Path $venv 'Scripts/python.exe'
if (-not (Test-Path $python)) { Invoke-Checked 'python' @('-m', 'venv', $venv) }
$pipArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', (Join-Path $rust 'windows/camera/requirements.txt'))
if (-not $Restore) { $pipArgs += '--no-index' }
Invoke-Checked $python $pipArgs
$previousTestCore = $env:CB_TEST_CORE
$env:CB_TEST_CORE = Join-Path $publish 'callbridge_abi_probe.dll'
try { Invoke-Checked $python @('-m', 'unittest', 'discover', '-s', (Join-Path $rust 'windows/camera'), '-p', 'test_*.py') }
finally { if ($null -eq $previousTestCore) { Remove-Item Env:CB_TEST_CORE } else { $env:CB_TEST_CORE = $previousTestCore } }
Invoke-Checked $python @('-m', 'PyInstaller', '--noconfirm', '--onedir', '--console', '--name', 'callbridge-camera-sender',
    '--distpath', (Join-Path $build 'camera-dist'), '--workpath', (Join-Path $build 'camera-work'), '--specpath', $build,
    '--collect-all', 'pyvirtualcam', '--copy-metadata', 'numpy', (Join-Path $rust 'windows/camera/camera_sender.py'))
New-Item -ItemType Directory -Force -Path (Join-Path $publish 'camera') | Out-Null
Copy-Item (Join-Path $build 'camera-dist/callbridge-camera-sender/*') (Join-Path $publish 'camera') -Recurse -Force
Copy-Item (Join-Path $publish 'callbridge_abi_probe.dll') (Join-Path $publish 'camera') -Force
$previousSender = $env:CB_TEST_CAMERA_SENDER
$env:CB_TEST_CAMERA_SENDER = Join-Path $publish 'camera/callbridge-camera-sender.exe'
try { Invoke-Checked 'node' @((Join-Path $rust 'windows/camera/check_bridge.mjs')) }
finally { if ($null -eq $previousSender) { Remove-Item Env:CB_TEST_CAMERA_SENDER } else { $env:CB_TEST_CAMERA_SENDER = $previousSender } }
Copy-Item (Join-Path $rust 'windows/README.md') (Join-Path $publish 'WINDOWS.md') -Force
Copy-Item (Join-Path $rust 'windows/UI-ACCEPTANCE.md') $publish -Force
Copy-Item (Join-Path $rust 'windows/THIRD_PARTY.md') $publish -Force
Copy-Item (Join-Path $root 'LICENSE') $publish -Force
Copy-Item (Join-Path $rust 'windows/camera') (Join-Path $publish 'camera-source') -Recurse -Force
Write-Host "Windows development build: $publish/CallBridge.exe"
Write-Host 'Build only. No driver installation, capture, virtual-device sending or call acceptance was performed.'
