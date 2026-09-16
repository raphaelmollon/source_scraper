# Export-FilteredTreeZip

Petit utilitaire pour extraire récursivement les fichiers d'un ou plusieurs répertoires en filtrant par extension, et reconstituer une archive ZIP qui préserve l'arborescence d'origine.

Deux versions équivalentes :
- `Export-FilteredTreeZip.ps1` — PowerShell (Windows)
- `Export-FilteredTreeZip.sh` — Bash (Linux, macOS, Git Bash)

## Cas d'usage typique

Tu as un projet volumineux (`$PROJET/src`, `$PROJET/inc`, plus d'autres dossiers contenant des logs, fichiers de build, etc.). Tu veux récupérer uniquement les sources (par extension) en évitant de scanner les dossiers inutiles.

```powershell
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\projet\src','C:\projet\inc' -Extensions h,c
```

Produit dans le répertoire courant : `projet_20260429_115615.zip` contenant
```
projet/
├── src/...
└── inc/...
```

## Pré-requis

| Version | Dépendances |
|---|---|
| `.ps1` | PowerShell 5.1+ (`System.IO.Compression`, natif .NET) |
| `.sh`  | `bash`, `find`, `mktemp`, `zip`, `realpath` ou `readlink -f` |

## Syntaxe

### PowerShell

```
.\Export-FilteredTreeZip.ps1 -SourceDirectory <chemin>[,<chemin>,...] -Extensions <ext1,ext2,...> [-OutputName <nom_zip>]
.\Export-FilteredTreeZip.ps1 <chemin>[,<chemin>,...] <ext1,ext2,...> [nom_zip]
.\Export-FilteredTreeZip.ps1 -Help
```

### Bash

```
./Export-FilteredTreeZip.sh --source-directory <chemin>[,<chemin>,...] --extensions <ext1,ext2,...> [--output-name <nom_zip>]
./Export-FilteredTreeZip.sh -s <chemin> [-s <chemin> ...] -e <ext1,ext2,...> [-o <nom_zip>]
./Export-FilteredTreeZip.sh <chemin>[,<chemin>,...] <ext1,ext2,...> [nom_zip]
./Export-FilteredTreeZip.sh --help
```

## Paramètres

| PS | SH | Description |
|---|---|---|
| `-SourceDirectory` | `-s`, `--source-directory` | Un ou plusieurs répertoires sources. Multi-valeur via virgule (les deux versions) ou flag répété (SH). |
| `-Extensions` | `-e`, `--extensions` | Liste d'extensions séparées par virgules. Avec ou sans point. Insensible à la casse. |
| `-OutputName` | `-o`, `--output-name` | Nom du ZIP de sortie. `.zip` ajouté si absent. |
| `-Help`, `-H`, `-?` | `-h`, `--help` | Affiche l'aide. |

## Comportement

### Une seule source

L'archive contient un dossier racine portant le nom de la source, avec toute son arborescence relative en dessous.

```powershell
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\src' -Extensions html,js
# → src_20260429_120000.zip
#   └── src/...
```

### Plusieurs sources avec parent commun

Le parent commun devient la racine de l'archive. L'arborescence relative à ce parent est préservée.

```powershell
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\projet\src','C:\projet\inc' -Extensions h,c
# → projet_20260429_120000.zip
#   └── projet/
#       ├── src/...
#       └── inc/...
```

### Plusieurs sources sans parent commun

Fallback : chaque source devient une racine top-level dans l'archive (nommée par sa feuille). ZIP nommé `export_<timestamp>.zip` par défaut.

```powershell
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\foo','D:\bar' -Extensions txt
# → export_20260429_120000.zip
#   ├── foo/...
#   └── bar/...
```

### Nom du ZIP par défaut

| Cas | Nom |
|---|---|
| 1 source | `<nom_source>_<timestamp>.zip` |
| N sources, parent commun | `<nom_parent_commun>_<timestamp>.zip` |
| N sources, pas de parent commun | `export_<timestamp>.zip` |

Le timestamp est au format `yyyyMMdd_HHmmss`. Le ZIP est créé dans le répertoire d'exécution courant (pas dans la source).

## Exemples

```powershell
# Extraction simple, nom auto
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\projet\src' -Extensions js,ts

# Multi-source, nom personnalisé
.\Export-FilteredTreeZip.ps1 -SourceDirectory 'C:\projet\src','C:\projet\inc' -Extensions h,c -OutputName backup_projet

# Forme positionnelle
.\Export-FilteredTreeZip.ps1 'C:\projet\src' js,ts mon_export
```

```bash
# Multi-source via flag répété
./Export-FilteredTreeZip.sh -s /projet/src -s /projet/inc -e h,c -o export_projet

# Multi-source via virgule
./Export-FilteredTreeZip.sh -s '/projet/src,/projet/inc' -e h,c
```

## Garde-fous et erreurs

- **Aucun fichier ne matche** → message clair, **aucune archive créée**.
- **Source imbriquée dans une autre** → erreur (`'A/sub' est contenu dans 'A'`).
- **Sources avec même nom de feuille** (mode fallback sans parent commun) → erreur de collision.
- **Source inexistante ou non-dossier** → erreur de validation.
- **Sources dupliquées** → dédupliquées silencieusement.

## Notes

- Le filtrage par extension est insensible à la casse (`.H` matche `h`).
- `.ps1` : l'archive est écrite directement depuis les sources (pas de staging dans `%TEMP%`, donc pas de dépassement MAX_PATH) ; une archive partielle est supprimée en cas d'erreur. `.sh` : le staging temporaire est systématiquement nettoyé.
- Les chemins absolus sont résolus via `Resolve-Path` (PS) / `realpath` ou `readlink -f` (SH).
- Si un ZIP du même nom existe déjà, il est écrasé.
- Les deux versions sont fonctionnellement équivalentes ; la seule différence pratique est le niveau de compression (`Optimal` côté .NET vs niveau 6 par défaut côté `zip`).
