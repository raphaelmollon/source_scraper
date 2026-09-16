[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$SourceDirectory,

    [Parameter(Position = 1)]
    [string[]]$Extensions,

    [Parameter(Position = 2)]
    [string]$OutputName,

    [Alias('H', '?')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    $scriptName = Split-Path -Path $PSCommandPath -Leaf
    @"
Usage:
  .\$scriptName -SourceDirectory <chemin>[,<chemin>,...] -Extensions <ext1,ext2,...> [-OutputName <nom_zip>]
  .\$scriptName <chemin>[,<chemin>,...] <ext1,ext2,...> [nom_zip]
  .\$scriptName -Help

Description:
  Recherche recursivement les fichiers correspondant aux extensions fournies dans
  un ou plusieurs repertoires sources, reconstruit l'arborescence d'origine,
  cree un fichier ZIP dans le repertoire courant d'execution,
  puis affiche le chemin complet de l'archive creee.

  Quand plusieurs sources sont fournies et qu'elles partagent un parent commun,
  l'arborescence relative a ce parent est preservee dans l'archive (la racine
  porte le nom du parent commun). Sinon, chaque source devient une racine de
  premier niveau dans l'archive (nommee par sa feuille).

Parametres:
  -SourceDirectory  Un ou plusieurs repertoires sources (separes par des virgules).
  -Extensions       Liste des extensions a inclure, avec ou sans point.
                    Exemples valides: html, js, .html, .js
  -OutputName       Nom du fichier ZIP a creer. ".zip" est ajoute si necessaire.
  -Help, -H, -?     Affiche cette aide.

Exemples:
  .\$scriptName -SourceDirectory 'C:\src' -Extensions html,js
  .\$scriptName -SourceDirectory 'C:\projet\src','C:\projet\inc' -Extensions h,c
  .\$scriptName 'C:\projet\src','C:\projet\inc' h,c export_projet
  .\$scriptName -Help
"@ | Write-Output
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Normalize-Extension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $trimmed = $Extension.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Une extension vide a ete fournie."
    }

    if (-not $trimmed.StartsWith('.')) {
        $trimmed = '.' + $trimmed
    }

    return $trimmed.ToLowerInvariant()
}

function Get-CommonParent {
    param([string[]]$Paths)

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $segments = @()
    foreach ($p in $Paths) {
        $segments += ,($p -split '[\\/]')
    }

    $minLen = ($segments | ForEach-Object { $_.Length } | Measure-Object -Minimum).Minimum
    $commonCount = 0
    for ($i = 0; $i -lt $minLen; $i++) {
        $token = $segments[0][$i]
        $allEqual = $true
        for ($j = 1; $j -lt $segments.Count; $j++) {
            if ([string]::Compare($segments[$j][$i], $token, $true) -ne 0) {
                $allEqual = $false
                break
            }
        }
        if (-not $allEqual) { break }
        $commonCount++
    }

    if ($commonCount -le 1) { return $null }

    $commonSegments = $segments[0][0..($commonCount - 1)]
    $result = $commonSegments -join $sep

    # Drive root only (e.g. "C:") n'est pas un parent utile
    if ($result -match '^[A-Za-z]:$') { return $null }

    return $result
}

if ($Help -or $PSBoundParameters.Count -eq 0) {
    Show-Usage
    return
}

if (-not $SourceDirectory -or $SourceDirectory.Count -eq 0 -or -not $Extensions -or $Extensions.Count -eq 0) {
    Show-Usage
    throw "Les parametres -SourceDirectory et -Extensions sont obligatoires."
}

# Resolution + validation de chaque source
$resolvedSources = @()
foreach ($src in $SourceDirectory) {
    if ([string]::IsNullOrWhiteSpace($src)) {
        throw "Une source vide a ete fournie."
    }
    $resolved = (Resolve-Path -LiteralPath $src).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Le repertoire source '$src' est introuvable ou n'est pas un dossier."
    }
    $resolvedSources += $resolved
}

# Dedupe (case-insensitive sur Windows via Resolve-Path qui canonise la casse)
$resolvedSources = @($resolvedSources | Sort-Object -Unique)

# Detection d'imbrication
foreach ($a in $resolvedSources) {
    foreach ($b in $resolvedSources) {
        if ($a -ne $b) {
            $startsBackslash = $b.StartsWith($a + '\', [System.StringComparison]::OrdinalIgnoreCase)
            $startsSlash = $b.StartsWith($a + '/', [System.StringComparison]::OrdinalIgnoreCase)
            if ($startsBackslash -or $startsSlash) {
                throw "Source imbriquee detectee: '$b' est contenu dans '$a'."
            }
        }
    }
}

$commonParent = $null
if ($resolvedSources.Count -gt 1) {
    $commonParent = Get-CommonParent -Paths $resolvedSources
}

$normalizedExtensions = $Extensions |
    ForEach-Object { Normalize-Extension -Extension $_ } |
    Select-Object -Unique

if (-not $normalizedExtensions) {
    throw "Aucune extension exploitable n'a ete fournie."
}

$executionDirectory = (Get-Location).Path

# Determination du nom de racine (pour le nom de ZIP par defaut)
if ($resolvedSources.Count -eq 1) {
    $primaryRootName = Split-Path -Path $resolvedSources[0] -Leaf
}
elseif ($commonParent) {
    $primaryRootName = Split-Path -Path $commonParent -Leaf
}
else {
    $primaryRootName = 'export'
}

if ([string]::IsNullOrWhiteSpace($OutputName)) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputName = "{0}_{1}.zip" -f $primaryRootName, $timestamp
}
elseif (-not $OutputName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
    $OutputName = "$OutputName.zip"
}

$zipPath = Join-Path -Path $executionDirectory -ChildPath $OutputName

# Plan de placement de chaque source dans l'archive
# Chaque entree: @{ Source = chemin absolu source; ArchiveRel = chemin relatif dans l'archive }
$sourcePlan = @()

if ($resolvedSources.Count -eq 1) {
    $sourcePlan += @{
        Source     = $resolvedSources[0]
        ArchiveRel = (Split-Path -Path $resolvedSources[0] -Leaf)
    }
}
elseif ($commonParent) {
    $commonLeaf = Split-Path -Path $commonParent -Leaf
    foreach ($src in $resolvedSources) {
        $relFromCommon = $src.Substring($commonParent.Length).TrimStart('\', '/')
        $sourcePlan += @{
            Source     = $src
            ArchiveRel = (Join-Path -Path $commonLeaf -ChildPath $relFromCommon)
        }
    }
}
else {
    $usedLeaves = @{}
    foreach ($src in $resolvedSources) {
        $leaf = Split-Path -Path $src -Leaf
        $key = $leaf.ToLowerInvariant()
        if ($usedLeaves.ContainsKey($key)) {
            throw "Collision de noms : deux sources ont la meme feuille '$leaf'. Specifiez un parent commun ou renommez."
        }
        $usedLeaves[$key] = $true
        $sourcePlan += @{ Source = $src; ArchiveRel = $leaf }
    }
}

# L'archive est ecrite directement depuis les sources (pas de copie dans %TEMP%) :
# evite de depasser MAX_PATH (260) quand le dossier temporaire allonge les chemins.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$sourceList = ($resolvedSources -join "', '")
Write-Status "Preparation de l'export depuis '$sourceList'."

Write-Status "Analyse recursive des fichiers..."
$allMatching = @()
foreach ($entry in $sourcePlan) {
    $files = Get-ChildItem -LiteralPath $entry.Source -Recurse -File
    $matching = @($files | Where-Object { $normalizedExtensions -contains $_.Extension.ToLowerInvariant() })
    foreach ($f in $matching) {
        $allMatching += @{
            File       = $f
            SourceRoot = $entry.Source
            ArchiveRel = $entry.ArchiveRel
        }
    }
}

if ($allMatching.Count -eq 0) {
    Write-Status "Aucun fichier correspondant aux extensions demandees n'a ete trouve."
    Write-Status "Aucune archive ZIP n'a ete cree."
    return
}

Write-Status ("{0} fichier(s) a ajouter." -f $allMatching.Count)

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Write-Status "Creation de l'archive ZIP..."
$zipCompleted = $false
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $addedCount = 0
    foreach ($item in $allMatching) {
        $addedCount++
        $relativePath = $item.File.FullName.Substring($item.SourceRoot.Length).TrimStart('\', '/')
        $entryName = (Join-Path -Path $item.ArchiveRel -ChildPath $relativePath) -replace '\\', '/'

        $percentComplete = [math]::Floor(($addedCount / $allMatching.Count) * 100)
        Write-Progress -Activity "Ajout des fichiers a l'archive" -Status $entryName -PercentComplete $percentComplete

        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $item.File.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
    $zipCompleted = $true
}
finally {
    $zip.Dispose()
    Write-Progress -Activity "Ajout des fichiers a l'archive" -Completed
    if (-not $zipCompleted -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force
    }
}

Write-Status ("Archive creee : {0} fichier(s) exporte(s)." -f $allMatching.Count)
Write-Output $zipPath
