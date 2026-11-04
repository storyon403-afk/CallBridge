# Windows 入口只启动已构建桌面程序；不存在时提供构建提示，不隐式下载或改系统配置。
param([switch]$Text)
$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot 'rust/build/windows/app/CallBridge.exe'
if (-not (Test-Path $app)) { throw '请先运行 .\rust\scripts\build-windows.ps1；首次恢复构建依赖时显式添加 -Restore。' }
if ($Text) { Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -ArgumentList '--text' }
else { Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) }
