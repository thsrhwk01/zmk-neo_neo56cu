# SPDX-License-Identifier: MIT

[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [string]$FirmwarePath
)

$ErrorActionPreference = "Stop"
$FirmwareName = "neo65cu-zmk.bin"
$ExpectedVidPid = "0483:df11"
$DfuModeSelector = ",$ExpectedVidPid"
$ApplicationAddress = "0x08000000"
$MainFlashLength = 0x20000
$MaximumImageSize = 0x20000
$FlashStart = [uint32]0x08000000
$SramStart = [uint32]0x20000000
$SramEnd = [uint32]0x20004000

function Stop-Flasher {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Test-Neo65CuImage {
    param([Parameter(Mandatory = $true)][string]$Path)

    [byte[]]$Image = [System.IO.File]::ReadAllBytes($Path)
    if ($Image.Length -lt 8 -or $Image.Length -gt $MaximumImageSize) {
        Stop-Flasher ("The firmware is {0} bytes; STM32F072 main flash is {1} bytes." -f $Image.Length, $MaximumImageSize)
    }

    [uint32]$InitialMsp = [System.BitConverter]::ToUInt32($Image, 0)
    [uint32]$ResetHandler = [System.BitConverter]::ToUInt32($Image, 4)
    [uint32]$ResetAddress = $ResetHandler -band 0xFFFFFFFE
    [uint32]$ImageEnd = $FlashStart + [uint32]$Image.Length

    if ($InitialMsp -lt $SramStart -or $InitialMsp -gt $SramEnd -or ($InitialMsp -band 7) -ne 0) {
        Stop-Flasher ("The firmware has an invalid STM32F072 stack pointer: 0x{0:X8}" -f $InitialMsp)
    }

    if (($ResetHandler -band 1) -eq 0 -or $ResetAddress -lt $FlashStart -or $ResetAddress -ge $ImageEnd) {
        Stop-Flasher ("The firmware has an invalid reset handler: 0x{0:X8}" -f $ResetHandler)
    }

    [pscustomobject]@{
        Size = $Image.Length
        Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        InitialMsp = $InitialMsp
        ResetHandler = $ResetHandler
    }
}

function Read-Checksums {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Checksums = @{}
    foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($Line)) {
            continue
        }

        if ($Line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') {
            Stop-Flasher "SHA256SUMS.txt contains an invalid line. Download and extract the ZIP again."
        }

        $Name = $Matches[2]
        if ($Checksums.ContainsKey($Name)) {
            Stop-Flasher "SHA256SUMS.txt contains a duplicate entry for $Name."
        }
        $Checksums[$Name] = $Matches[1].ToUpperInvariant()
    }

    return $Checksums
}

function Invoke-DfuUtilList {
    # Windows PowerShell converts native stderr redirected with 2>&1 into an
    # ErrorRecord. With the script-wide ErrorActionPreference=Stop, a warning
    # about an unrelated inaccessible DFU device can therefore terminate the
    # flasher before the 0483:df11 lines are parsed. Capture both native streams
    # directly so only target-specific diagnostics are treated as fatal below.
    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $script:DfuUtilPath
    $StartInfo.Arguments = "-l"
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true

    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo = $StartInfo
    try {
        if (-not $Process.Start()) {
            Stop-Flasher "dfu-util could not be started. Download and extract the ZIP again."
        }

        $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
        $StandardErrorTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        $StandardOutput = $StandardOutputTask.Result
        $StandardError = $StandardErrorTask.Result
        $ExitCode = $Process.ExitCode
    }
    finally {
        $Process.Dispose()
    }

    $Lines = @(
        @($StandardOutput, $StandardError) |
            ForEach-Object { $_ -split "`r?`n" } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    [pscustomobject]@{
        ExitCode = $ExitCode
        Lines = [string[]]$Lines
    }
}

function Get-Neo65CuDfuDevice {
    $Listing = Invoke-DfuUtilList
    $ListingLines = @($Listing.Lines)

    if ($ListingLines -match '(?i)Cannot open DFU device 0483:df11') {
        Stop-Flasher "Windows cannot open STM32 ROM DFU 0483:df11. Follow the WinUSB driver steps in README_KO.txt."
    }

    $TargetLines = @($ListingLines | Where-Object { $_ -match '(?i)^Found DFU: \[0483:df11\]' })
    if ($TargetLines.Count -eq 0) {
        return $null
    }

    $Entries = @()
    foreach ($Line in $TargetLines) {
        if ($Line -notmatch '(?i)path="(?<Path>[^"]+)".*alt=(?<Alt>[0-9]+), name="(?<Name>[^"]+)", serial="(?<Serial>[^"]*)"') {
            Stop-Flasher "The STM32 DFU descriptor could not be parsed. Nothing was written."
        }

        $Entries += [pscustomobject]@{
            Path = $Matches.Path
            Alt = [int]$Matches.Alt
            Name = ($Matches.Name -replace '\s+', ' ').Trim()
            Serial = $Matches.Serial
        }
    }

    if ($Entries.Count -ne 2) {
        Stop-Flasher "Expected exactly one STM32 DFU device with alt 0 and alt 1. Disconnect every other STM32 DFU device."
    }

    $InternalFlash = @($Entries | Where-Object {
        $_.Alt -eq 0 -and $_.Name -eq '@Internal Flash /0x08000000/064*0002Kg'
    })
    $OptionBytes = @($Entries | Where-Object {
        $_.Alt -eq 1 -and $_.Name -eq '@Option Bytes /0x1FFFF800/01*016 e'
    })

    if ($InternalFlash.Count -ne 1 -or $OptionBytes.Count -ne 1) {
        Stop-Flasher "The DFU alternate settings do not match the verified Neo65 CU STM32F072 memory map."
    }

    if ($InternalFlash[0].Path -ne $OptionBytes[0].Path -or
        $InternalFlash[0].Serial -ne $OptionBytes[0].Serial) {
        Stop-Flasher "DFU alt 0 and alt 1 do not belong to the same USB device."
    }

    [pscustomobject]@{
        Path = $InternalFlash[0].Path
        Serial = $InternalFlash[0].Serial
    }
}

$FirmwareLock = $null
$InstanceMutex = $null
$InstanceMutexOwned = $false
$VerificationPath = $null
try {
    $CustomFirmwareValidation = -not [string]::IsNullOrWhiteSpace($FirmwarePath)
    if (-not $CustomFirmwareValidation) {
        $ResolvedFirmwarePath = Join-Path $PSScriptRoot $FirmwareName
    }
    elseif ($ValidateOnly) {
        $ResolvedFirmwarePath = (Resolve-Path -LiteralPath $FirmwarePath).Path
    }
    else {
        Stop-Flasher "A custom firmware path is allowed only with -ValidateOnly. Flashing always uses the firmware packaged beside this script."
    }

    if (-not (Test-Path -LiteralPath $ResolvedFirmwarePath -PathType Leaf)) {
        Stop-Flasher "Firmware file not found: $ResolvedFirmwarePath"
    }

    # Keep the packaged BIN read-only and non-replaceable until dfu-util and
    # readback verification finish. dfu-util only needs a concurrent read.
    $FirmwareLock = [System.IO.File]::Open(
        $ResolvedFirmwarePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $ImageInfo = Test-Neo65CuImage -Path $ResolvedFirmwarePath

    if ($ValidateOnly -and $CustomFirmwareValidation) {
        Write-Host "Neo65 CU firmware image passed structural validation." -ForegroundColor Green
        Write-Host ("  File:             {0}" -f $ResolvedFirmwarePath)
        Write-Host ("  Size:             {0} bytes" -f $ImageInfo.Size)
        Write-Host ("  Reset handler:    0x{0:X8}" -f $ImageInfo.ResetHandler)
        Write-Host ("  SHA-256:          {0}" -f $ImageInfo.Hash)
        exit 0
    }

    $script:DfuUtilPath = Join-Path $PSScriptRoot "dfu-util.exe"
    $LibusbPath = Join-Path $PSScriptRoot "libusb-1.0.dll"
    $ChecksumsPath = Join-Path $PSScriptRoot "SHA256SUMS.txt"

    foreach ($RequiredPath in @($script:DfuUtilPath, $LibusbPath, $ChecksumsPath)) {
        if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
            Stop-Flasher ("{0} is missing. Extract the complete ZIP before running this file." -f (Split-Path $RequiredPath -Leaf))
        }
    }

    $ExpectedHashes = Read-Checksums -Path $ChecksumsPath
    foreach ($BundleFile in @($FirmwareName, "dfu-util.exe", "libusb-1.0.dll")) {
        if (-not $ExpectedHashes.ContainsKey($BundleFile)) {
            Stop-Flasher "SHA256SUMS.txt has no checksum for $BundleFile."
        }

        $BundlePath = Join-Path $PSScriptRoot $BundleFile
        $ActualHash = (Get-FileHash -LiteralPath $BundlePath -Algorithm SHA256).Hash
        if ($ActualHash -ne $ExpectedHashes[$BundleFile]) {
            Stop-Flasher "Checksum mismatch for $BundleFile. Download and extract the ZIP again."
        }
    }

    Write-Host "Neo65 CU firmware and bundle checksums verified." -ForegroundColor Green
    Write-Host ("  File:             {0}" -f $FirmwareName)
    Write-Host ("  Size:             {0} bytes" -f $ImageInfo.Size)
    Write-Host ("  Reset handler:    0x{0:X8}" -f $ImageInfo.ResetHandler)
    Write-Host ("  SHA-256:          {0}" -f $ImageInfo.Hash)

    if ($ValidateOnly) {
        Write-Host "Bundle validation passed." -ForegroundColor Green
        exit 0
    }

    $InstanceMutex = [System.Threading.Mutex]::new(
        $false,
        "Local\Neo65CuZmkFlasher"
    )
    try {
        $InstanceMutexOwned = $InstanceMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $InstanceMutexOwned = $true
    }
    if (-not $InstanceMutexOwned) {
        Stop-Flasher "Another Neo65 CU flasher is already running in this Windows session."
    }

    Write-Host ""
    Write-Host "WARNING: Confirm the exact target before continuing." -ForegroundColor Yellow
    Write-Host "Only use this flasher with a Qwertykeys Neo65 CU WIRED PCB" -ForegroundColor Yellow
    Write-Host "whose MCU is marked STM32F072CBT6." -ForegroundColor Yellow

    Add-Type -AssemblyName System.Windows.Forms
    $ConfirmationMessage = @"
Confirm that the target is a Qwertykeys Neo65 CU WIRED PCB
with an STM32F072CBT6 MCU.

The flasher will:
1. accept only the verified 0483:df11 ROM-DFU memory map,
2. back up all 128 KiB of main flash,
3. write only alt 0 at 0x08000000, and
4. read the image back and compare SHA-256.

It never selects alt 1 (Option Bytes) and never mass-erases.

Continue?
"@
    $Confirmation = [System.Windows.Forms.MessageBox]::Show(
        $ConfirmationMessage,
        "Neo65 CU Firmware Flasher",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($Confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host "Cancelled. Nothing was read from or written to any device." -ForegroundColor Cyan
        exit 0
    }

    Write-Host ""
    Write-Host "Enter STM32 ROM DFU using either method:" -ForegroundColor Cyan
    Write-Host "  - Disconnect USB, hold Esc, reconnect USB, then release Esc."
    Write-Host "  - From ZMK, hold Fn and press Delete."
    Write-Host "Waiting for Neo65 CU ROM DFU 0483:df11 (press Ctrl+C to cancel)..."

    $DfuDevice = $null
    while ($null -eq $DfuDevice) {
        $DfuDevice = Get-Neo65CuDfuDevice
        if ($null -eq $DfuDevice) {
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 1
        }
    }
    Write-Host ""
    Write-Host "Verified STM32F072 ROM-DFU descriptor." -ForegroundColor Green
    Write-Host ("  USB path: {0}" -f $DfuDevice.Path)
    Write-Host ("  Serial:   {0}" -f $DfuDevice.Serial)
    Write-Host "  Write target: alt 0 Internal Flash / 0x08000000 / 128 KiB"
    Write-Host "  Forbidden target: alt 1 Option Bytes (not selected)" -ForegroundColor Yellow

    $TargetArguments = @("-d", $DfuModeSelector, "-p", $DfuDevice.Path)
    if (-not [string]::IsNullOrWhiteSpace($DfuDevice.Serial)) {
        $TargetArguments += @("-S", $DfuDevice.Serial)
    }
    $TargetArguments += @("-a", "0")

    $BackupDirectory = Join-Path $PSScriptRoot "backups"
    [void][System.IO.Directory]::CreateDirectory($BackupDirectory)
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $BackupName = "neo65cu-mainflash-backup-$Timestamp.bin"
    $BackupPath = Join-Path $BackupDirectory $BackupName

    Write-Host ""
    Write-Host "Reading all 128 KiB of existing main flash before writing..." -ForegroundColor Cyan
    & $script:DfuUtilPath @TargetArguments "-s" "0x08000000:0x20000" "-U" $BackupPath
    if ($LASTEXITCODE -ne 0) {
        Stop-Flasher ("The pre-flash backup failed with dfu-util exit code {0}. Nothing was written." -f $LASTEXITCODE)
    }

    if ((Get-Item -LiteralPath $BackupPath).Length -ne $MainFlashLength) {
        Stop-Flasher "The pre-flash backup is not exactly 131072 bytes. Nothing was written."
    }

    $BackupHash = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash
    $BackupChecksumPath = "$BackupPath.sha256.txt"
    [System.IO.File]::WriteAllText(
        $BackupChecksumPath,
        ("{0}  {1}{2}" -f $BackupHash.ToLowerInvariant(), $BackupName, [Environment]::NewLine),
        [System.Text.Encoding]::ASCII
    )
    Write-Host "Backup complete. Keep both files in a second location." -ForegroundColor Green
    Write-Host ("  Backup: {0}" -f $BackupPath)
    Write-Host ("  SHA-256: {0}" -f $BackupHash)

    Write-Host ""
    Write-Host "Writing the verified firmware to alt 0 at 0x08000000..." -ForegroundColor Cyan
    & $script:DfuUtilPath @TargetArguments "-s" $ApplicationAddress "-D" $ResolvedFirmwarePath
    if ($LASTEXITCODE -ne 0) {
        Stop-Flasher ("Firmware download failed with dfu-util exit code {0}. Keep USB connected and use the backup for recovery." -f $LASTEXITCODE)
    }

    $VerificationPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        "neo65cu-write-verify-{0}.bin" -f [Guid]::NewGuid().ToString("N")
    )
    $ReadbackAddress = "0x08000000:0x{0:X}" -f $ImageInfo.Size

    Write-Host ""
    Write-Host "Reading the flashed image back before reboot..." -ForegroundColor Cyan
    & $script:DfuUtilPath @TargetArguments "-s" $ReadbackAddress "-U" $VerificationPath
    if ($LASTEXITCODE -ne 0) {
        Stop-Flasher ("Post-flash readback failed with dfu-util exit code {0}. Keep USB connected and do not assume success." -f $LASTEXITCODE)
    }

    [byte[]]$ReadbackBytes = [System.IO.File]::ReadAllBytes($VerificationPath)
    if ($ReadbackBytes.Length -ne $ImageInfo.Size) {
        Stop-Flasher "Post-flash readback length differs from the firmware. Keep USB connected and do not assume success."
    }

    [byte[]]$FirmwareBytes = [System.IO.File]::ReadAllBytes($ResolvedFirmwarePath)
    for ($Index = 0; $Index -lt $FirmwareBytes.Length; $Index++) {
        if ($ReadbackBytes[$Index] -ne $FirmwareBytes[$Index]) {
            Stop-Flasher ("Post-flash readback differs at image offset 0x{0:X}. Keep USB connected and restore from the backup." -f $Index)
        }
    }

    $ReadbackHash = (Get-FileHash -LiteralPath $VerificationPath -Algorithm SHA256).Hash
    if ($ReadbackHash -ne $ImageInfo.Hash) {
        Stop-Flasher "Post-flash readback SHA-256 differs from the firmware. Keep USB connected and restore from the backup."
    }

    Write-Host ""
    Write-Host "Flash and byte-for-byte readback verification complete." -ForegroundColor Green
    Write-Host ("  SHA-256: {0}" -f $ReadbackHash)
    Write-Host "Disconnect USB, then reconnect it without holding Esc." -ForegroundColor Cyan
    Write-Host "The keyboard should start as Neo65 CU ZMK."
    exit 0
}
catch {
    Stop-Flasher $_.Exception.Message
}
finally {
    if ($InstanceMutexOwned) {
        $InstanceMutex.ReleaseMutex()
    }
    if ($null -ne $InstanceMutex) {
        $InstanceMutex.Dispose()
    }
    if ($null -ne $FirmwareLock) {
        $FirmwareLock.Dispose()
    }
    if ($null -ne $VerificationPath -and (Test-Path -LiteralPath $VerificationPath -PathType Leaf)) {
        Remove-Item -LiteralPath $VerificationPath -Force
    }
}
