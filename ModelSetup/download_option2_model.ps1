param(
    [ValidateSet("q4_k_m", "q3_k_m", "q3_k_s")]
    [string]$Variant = "q4_k_m",
    [switch]$PushToPhone
)

$ErrorActionPreference = "Stop"

$Models = @{
    "q4_k_m" = @{
        Name     = "Qwen2.5-1.5B-Instruct (Q4_K_M - Best Balance)"
        FileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        Url      = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
        Approx   = "~1.04 GB (1066 MiB)"
    }
    "q3_k_m" = @{
        Name     = "Qwen2.5-1.5B-Instruct (Q3_K_M - Smaller)"
        FileName = "Qwen2.5-1.5B-Instruct-Q3_K_M.gguf"
        Url      = "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q3_K_M.gguf"
        Approx   = "~824 MB"
    }
    "q3_k_s" = @{
        Name     = "Qwen2.5-1.5B-Instruct (Q3_K_S - Compact)"
        FileName = "Qwen2.5-1.5B-Instruct-Q3_K_S.gguf"
        Url      = "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q3_K_S.gguf"
        Approx   = "~761 MB"
    }
}

$Selected = $Models[$Variant]
$OutputDir = Join-Path $PSScriptRoot "output"
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$TargetPath = Join-Path $OutputDir $Selected.FileName
$ChecksumPath = "$TargetPath.sha256"

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " AskMe Offline AI - Option 2 Model Setup" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "Model  : $($Selected.Name)"
Write-Host "Size   : $($Selected.Approx)"
Write-Host "License: Apache-2.0"
Write-Host "Save to: $TargetPath"
Write-Host ""

Write-Host "[1/3] Downloading GGUF model (resume supported)..." -ForegroundColor Yellow
& curl.exe -L --fail --continue-at - -o $TargetPath $Selected.Url
if ($LASTEXITCODE -ne 0) {
    throw "Download failed with exit code $LASTEXITCODE."
}

Write-Host "[2/3] Validating GGUF v2/v3 header..." -ForegroundColor Yellow
$Header = New-Object byte[] 24
$Stream = [System.IO.File]::OpenRead($TargetPath)
try {
    $Read = $Stream.Read($Header, 0, 24)
} finally {
    $Stream.Dispose()
}

if ($Read -lt 24 -or $Header[0] -ne 0x47 -or $Header[1] -ne 0x47 -or $Header[2] -ne 0x55 -or $Header[3] -ne 0x46) {
    throw "Downloaded file does not start with valid GGUF magic bytes."
}

$Version = [BitConverter]::ToUInt32($Header, 4)
if ($Version -lt 2 -or $Version -gt 3) {
    throw "Unsupported GGUF version: $Version (expected 2 or 3)."
}

Write-Host "[3/3] Computing SHA-256 checksum..." -ForegroundColor Yellow
$Hash = (Get-FileHash -Path $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  $($Selected.FileName)" | Set-Content -Path $ChecksumPath -Encoding UTF8

$SizeMb = [Math]::Round((Get-Item $TargetPath).Length / 1MB, 1)
Write-Host ""
Write-Host "SUCCESS! Option 2 Model Ready:" -ForegroundColor Green
Write-Host "  File    : $TargetPath ($SizeMb MB)"
Write-Host "  GGUF    : v$Version valid"
Write-Host "  SHA-256 : $Hash"
Write-Host "  Checksum: $ChecksumPath"
Write-Host ""

$Adb = Get-Command adb -ErrorAction SilentlyContinue
if ($PushToPhone -or $Adb) {
    if ($Adb) {
        $Devices = (& adb devices) | Select-String "\tdevice$"
        if ($Devices) {
            Write-Host "Android device detected via USB ADB. Pushing model to /sdcard/Download/..." -ForegroundColor Cyan
            & adb push $TargetPath "/sdcard/Download/$($Selected.FileName)"
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Copied to phone Downloads folder! Open AskMe -> Import Model -> Downloads -> $($Selected.FileName)" -ForegroundColor Green
                exit 0
            }
        }
    }
}

Write-Host "Next Step on your Phone:" -ForegroundColor Cyan
Write-Host "  1. Copy '$($Selected.FileName)' to your Android phone's Downloads folder."
Write-Host "  2. Open AskMe app -> tap 'Import Model' (or 'Import')."
Write-Host "  3. Open Downloads -> select '$($Selected.FileName)'."
Write-Host "  4. Wait for green 'Model Ready' badge, then chat 100% offline!"
