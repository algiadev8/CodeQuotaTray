param(
    [string]$Version = "1.0.0"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# 1) 自己完結・単一EXEを dist に出力
& .\build.ps1
if ($LASTEXITCODE -ne 0) { throw "build.ps1 failed" }

# 2) WiX Toolset (dotnet tool) を用意
$env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    dotnet tool install --global wix --version 5.0.2
    if ($LASTEXITCODE -ne 0) { throw "wix install failed" }
}

# 3) MSI を作成
$msi = Join-Path $PSScriptRoot "dist\CodeQuotaTray-$Version-x64.msi"
wix build .\installer\Package.wxs -arch x64 -d Version=$Version -d SourceDir=$PSScriptRoot\dist -o $msi
if ($LASTEXITCODE -ne 0) { throw "wix build failed" }

Write-Host "Created: $msi"
