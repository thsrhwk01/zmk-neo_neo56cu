[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path
)

$ErrorActionPreference = "Stop"
$ResolvedPath = Resolve-Path -LiteralPath $Path
[byte[]]$Image = [IO.File]::ReadAllBytes($ResolvedPath)

if ($Image.Length -lt 8) {
    throw "Image is too small to contain an ARM vector table."
}
[uint32]$InitialMsp = [BitConverter]::ToUInt32($Image, 0)
[uint32]$ResetHandler = [BitConverter]::ToUInt32($Image, 4)
[uint32]$ResetAddress = $ResetHandler -band 0xFFFFFFFE
$Hash = (Get-FileHash -LiteralPath $ResolvedPath -Algorithm SHA256).Hash

$MspValid = $InitialMsp -ge 0x20000000 -and
    $InitialMsp -le 0x20004000 -and
    ($InitialMsp -band 7) -eq 0
$ResetValid = ($ResetHandler -band 1) -eq 1 -and
    $ResetAddress -ge 0x08000000 -and
    $ResetAddress -lt 0x08020000
$SizeValid = $Image.Length -le 0x20000

[pscustomobject]@{
    Path = $ResolvedPath.Path
    SizeBytes = $Image.Length
    SizeHex = "0x{0:X}" -f $Image.Length
    SHA256 = $Hash
    InitialMSP = "0x{0:X8}" -f $InitialMsp
    ResetHandler = "0x{0:X8}" -f $ResetHandler
    FitsMainFlash = $SizeValid
    MSPInF072SRAM = $MspValid
    ResetInMainFlash = $ResetValid
}

if (-not ($SizeValid -and $MspValid -and $ResetValid)) {
    throw "Image failed one or more Neo65 CU STM32F072 safety checks."
}
