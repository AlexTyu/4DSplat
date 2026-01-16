# Download ml-sharp checkpoint
$checkpointUrl = "https://ml-site.cdn-apple.com/models/sharp/sharp_2572gikvuh.pt"
$checkpointDir = Join-Path $PSScriptRoot "checkpoints"
$checkpointFile = Join-Path $checkpointDir "sharp_2572gikvuh.pt"

# Create directory if it doesn't exist
if (-not (Test-Path $checkpointDir)) {
    New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
    Write-Host "Created directory: $checkpointDir"
}

# Check if file already exists
if (Test-Path $checkpointFile) {
    $existingFile = Get-Item $checkpointFile
    $sizeMB = [math]::Round($existingFile.Length / 1MB, 2)
    Write-Host "Checkpoint already exists: $checkpointFile"
    Write-Host "Size: $sizeMB MB"
    
    if ($sizeMB -gt 500) {
        Write-Host "File appears complete. Skipping download."
        exit 0
    } else {
        Write-Host "File appears incomplete. Re-downloading..."
        Remove-Item $checkpointFile -Force
    }
}

Write-Host "Downloading checkpoint from: $checkpointUrl"
Write-Host "Saving to: $checkpointFile"
Write-Host "This may take several minutes (file is ~1-2 GB)..."
Write-Host ""

try {
    $ProgressPreference = 'Continue'
    Invoke-WebRequest -Uri $checkpointUrl -OutFile $checkpointFile -UseBasicParsing
    
    if (Test-Path $checkpointFile) {
        $downloadedFile = Get-Item $checkpointFile
        $sizeMB = [math]::Round($downloadedFile.Length / 1MB, 2)
        Write-Host ""
        Write-Host "[OK] Download complete!"
        Write-Host "  File: $checkpointFile"
        Write-Host "  Size: $sizeMB MB"
    } else {
        Write-Host "[ERROR] Download failed - file not found"
        exit 1
    }
} catch {
    Write-Host "[ERROR] Error downloading checkpoint: $_"
    exit 1
}
