[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path
)

$ErrorActionPreference = "Stop"
$ResolvedPath = Resolve-Path -LiteralPath $Path
[byte[]]$Image = [IO.File]::ReadAllBytes($ResolvedPath)

$FlashStart = [uint32]0x08000000
$FlashSize = [uint32]0x00020000
$SramStart = [uint32]0x20000000
$SramEnd = [uint32]0x20004000
$VectorWordCount = 48 # 16 Cortex-M0 vectors + 32 STM32F072 IRQ vectors

if ($Image.Length -lt ($VectorWordCount * 4)) {
    throw "Image is too small to contain the complete STM32F072 vector table."
}

[uint32]$InitialMsp = [BitConverter]::ToUInt32($Image, 0)
[uint32]$ResetHandler = [BitConverter]::ToUInt32($Image, 4)
[uint32]$ResetAddress = $ResetHandler -band 0xFFFFFFFE
[uint32]$ImageEnd = $FlashStart + $Image.Length
$Hash = (Get-FileHash -LiteralPath $ResolvedPath -Algorithm SHA256).Hash

$MspValid = $InitialMsp -ge $SramStart -and
    $InitialMsp -le $SramEnd -and
    ($InitialMsp -band 7) -eq 0
$ResetValid = ($ResetHandler -band 1) -eq 1 -and
    $ResetAddress -ge $FlashStart -and
    $ResetAddress -lt $ImageEnd
$SizeValid = $Image.Length -le $FlashSize

# Reset/NMI/HardFault/SVC/PendSV/SysTick and STM32F072 USB IRQ 31.
$RequiredVectors = @(1, 2, 3, 11, 14, 15, 47)
$InvalidVectors = [Collections.Generic.List[string]]::new()
$NonZeroHandlerVectors = 0
$ZeroHandlerVectors = 0

for ($Index = 1; $Index -lt $VectorWordCount; $Index++) {
    [uint32]$Vector = [BitConverter]::ToUInt32($Image, $Index * 4)

    if ($Vector -eq 0) {
        $ZeroHandlerVectors++
        if ($Index -in $RequiredVectors) {
            $InvalidVectors.Add("vector[$Index] is unexpectedly zero")
        }
        continue
    }

    $NonZeroHandlerVectors++
    [uint32]$Handler = $Vector -band 0xFFFFFFFE
    if (($Vector -band 1) -ne 1) {
        $InvalidVectors.Add(("vector[{0}] is not Thumb code: 0x{1:X8}" -f $Index, $Vector))
    }
    elseif ($Handler -lt $FlashStart -or $Handler -ge $ImageEnd) {
        $InvalidVectors.Add(("vector[{0}] is outside this image: 0x{1:X8}" -f $Index, $Vector))
    }
}

$VectorsValid = $InvalidVectors.Count -eq 0

[pscustomobject]@{
    Path = $ResolvedPath.Path
    SizeBytes = $Image.Length
    SizeHex = "0x{0:X}" -f $Image.Length
    ApplicationEnd = "0x{0:X8}" -f $ImageEnd
    SHA256 = $Hash
    InitialMSP = "0x{0:X8}" -f $InitialMsp
    ResetHandler = "0x{0:X8}" -f $ResetHandler
    VectorWordsChecked = $VectorWordCount
    NonZeroHandlers = $NonZeroHandlerVectors
    ZeroReservedVectors = $ZeroHandlerVectors
    InvalidVectors = $InvalidVectors.Count
    FitsMainFlash = $SizeValid
    MSPInF072SRAM = $MspValid
    ResetInImage = $ResetValid
    AllHandlersInImage = $VectorsValid
    SystemROMOutsideImage = $ImageEnd -le 0x1FFFC800
}

if (-not $VectorsValid) {
    $InvalidVectors | ForEach-Object { Write-Error $_ }
}

if (-not ($SizeValid -and $MspValid -and $ResetValid -and $VectorsValid)) {
    throw "Image failed one or more Neo65 CU STM32F072 safety checks."
}
