$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
dotnet publish .\CodeQuotaTray.Windows\CodeQuotaTray.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\dist
Write-Host "Created: $PSScriptRoot\dist\CodeQuotaTray.exe"
