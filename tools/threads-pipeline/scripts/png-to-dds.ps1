param(
  [Parameter(Mandatory)][string]$In,
  [Parameter(Mandatory)][string]$Out,
  [ValidateSet('BC7_UNORM','BC3_UNORM','DXT5','DXT1')][string]$Format = 'BC7_UNORM',
  [int]$Mips = 1
)
# PNG -> DDS via Microsoft texconv. BC7_UNORM is the INTRACT-parity default (DX10 header).
# texconv names its output by the input basename, so we rename to the requested -Out.
$ErrorActionPreference = 'Stop'
$texconv = Join-Path $PSScriptRoot '..\vendor\texconv.exe'
if (-not (Test-Path $texconv)) { throw "texconv not found at $texconv (see README for download)" }
$outDir = Split-Path (Resolve-Path -LiteralPath (Split-Path $Out -Parent)) -NoQualifier
$outDir = Split-Path $Out -Parent
New-Item -ItemType Directory -Force $outDir | Out-Null

& $texconv -nologo -y -f $Format -m $Mips -o $outDir $In | Out-Null
$produced = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($In) + '.dds')
if ($produced -ne $Out) { Move-Item -Force $produced $Out }
if (-not (Test-Path $Out)) { throw "texconv produced no DDS for $In" }
Write-Output $Out
