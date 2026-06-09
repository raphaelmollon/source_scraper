[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SourceDirectory,

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
  .\$scriptName -SourceDirectory <chemin> -Extensions <ext1,ext2,...> [-OutputName <nom_zip>]
  .\$scriptName <chemin> <ext1,ext2,...> [nom_zip]
  .\$scriptName -Help

Description:
  Recherche recursivement les fichiers correspondant aux extensions fournies,
  reconstruit l'arborescence d'origine dans une racine nommee comme le dossier source,
  cree un fichier ZIP dans le repertoire courant d'execution,
  puis affiche le chemin complet de l'archive creee.

Parametres:
  -SourceDirectory  Repertoire source a analyser.
  -Extensions       Liste des extensions a inclure, avec ou sans point.
                    Exemples valides: html, js, .html, .js
  -OutputName       Nom du fichier ZIP a creer. ".zip" est ajoute si necessaire.
  -Help, -H, -?     Affiche cette aide.

Exemples:
  .\$scriptName -SourceDirectory 'C:\src' -Extensions html,js
  .\$scriptName 'C:\src' html,js export_front_back
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

if ($Help -or $PSBoundParameters.Count -eq 0) {
    Show-Usage
    return
}

if ([string]::IsNullOrWhiteSpace($SourceDirectory) -or -not $Extensions -or $Extensions.Count -eq 0) {
    Show-Usage
    throw "Les parametres -SourceDirectory et -Extensions sont obligatoires."
}

$resolvedSource = (Resolve-Path -LiteralPath $SourceDirectory).Path
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
    throw "Le repertoire source '$SourceDirectory' est introuvable ou n'est pas un dossier."
}

$normalizedExtensions = $Extensions |
    ForEach-Object { Normalize-Extension -Extension $_ } |
    Select-Object -Unique

if (-not $normalizedExtensions) {
    throw "Aucune extension exploitable n'a ete fournie."
}

$sourceRootName = Split-Path -Path $resolvedSource -Leaf
$executionDirectory = (Get-Location).Path

if ([string]::IsNullOrWhiteSpace($OutputName)) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputName = "{0}_{1}.zip" -f $sourceRootName, $timestamp
}
elseif (-not $OutputName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
    $OutputName = "$OutputName.zip"
}

$zipPath = Join-Path -Path $executionDirectory -ChildPath $OutputName
$stagingRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString())
$stagingSourceRoot = Join-Path -Path $stagingRoot -ChildPath $sourceRootName

try {
    Write-Status "Preparation de l'export depuis '$resolvedSource'."
    New-Item -ItemType Directory -Path $stagingSourceRoot -Force | Out-Null

    Write-Status "Analyse recursive des fichiers..."
    $files = Get-ChildItem -LiteralPath $resolvedSource -Recurse -File
    $matchingFiles = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $normalizedExtensions })

    if ($matchingFiles.Count -eq 0) {
        Write-Status "Aucun fichier correspondant aux extensions demandees n'a ete trouve."
    }
    else {
        Write-Status ("{0} fichier(s) a copier." -f $matchingFiles.Count)
    }

    $copiedCount = 0
    foreach ($file in $matchingFiles) {
        $copiedCount++
        $relativePath = $file.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
        $destinationPath = Join-Path -Path $stagingSourceRoot -ChildPath $relativePath
        $destinationDirectory = Split-Path -Path $destinationPath -Parent

        $percentComplete = [math]::Floor(($copiedCount / $matchingFiles.Count) * 100)
        Write-Progress -Activity "Copie des fichiers" -Status $relativePath -PercentComplete $percentComplete

        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }

        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }

    if ($matchingFiles.Count -gt 0) {
        Write-Progress -Activity "Copie des fichiers" -Completed
        Write-Status ("Copie terminee : {0} fichier(s) exporte(s)." -f $matchingFiles.Count)
    }

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Write-Status "Creation de l'archive ZIP..."
    Compress-Archive -Path $stagingSourceRoot -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Status "Archive creee."
    Write-Output $zipPath
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
