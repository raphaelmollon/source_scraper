#!/usr/bin/env bash

set -euo pipefail

show_usage() {
  local script_name
  script_name="$(basename "$0")"
  cat <<EOF
Usage:
  ./$script_name --source-directory <chemin>[,<chemin>,...] --extensions <ext1,ext2,...> [--output-name <nom_zip>]
  ./$script_name -s <chemin> [-s <chemin> ...] -e <ext1,ext2,...> [-o <nom_zip>]
  ./$script_name <chemin>[,<chemin>,...] <ext1,ext2,...> [nom_zip]
  ./$script_name --help

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
  -s, --source-directory  Repertoire source. Repetable, ou liste separee par virgules.
  -e, --extensions        Liste des extensions a inclure, avec ou sans point.
                          Exemples valides: html, js, .html, .js
  -o, --output-name       Nom du fichier ZIP a creer. ".zip" est ajoute si necessaire.
  -h, --help              Affiche cette aide.

Exemples:
  ./$script_name --source-directory '/src' --extensions html,js
  ./$script_name -s '/projet/src' -s '/projet/inc' -e h,c -o export_projet
  ./$script_name '/projet/src,/projet/inc' h,c export_projet
  ./$script_name --help
EOF
}

write_status() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

fail() {
  printf 'Erreur: %s\n' "$1" >&2
  exit 1
}

normalize_extension() {
  local ext trimmed
  ext="${1-}"
  trimmed="$ext"
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  if [[ -z "$trimmed" ]]; then
    fail "Une extension vide a ete fournie."
  fi

  if [[ "$trimmed" != .* ]]; then
    trimmed=".$trimmed"
  fi

  printf '%s\n' "${trimmed,,}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "La commande requise '$1' est introuvable."
}

resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
    return
  fi

  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$1"
    return
  fi

  fail "Impossible de resoudre les chemins absolus: installez 'realpath' ou 'readlink'."
}

# Affiche le parent commun de tous les chemins absolus passes en arguments,
# ou rien si aucun parent utile (un seul segment, ou divergence des la racine).
get_common_parent() {
  if [[ $# -le 1 ]]; then
    return
  fi

  local first="$1"
  shift

  local IFS_save="$IFS"
  IFS='/' read -r -a first_seg <<< "$first"
  local n=${#first_seg[@]}

  local path
  for path in "$@"; do
    local seg=()
    IFS='/' read -r -a seg <<< "$path"
    local m=${#seg[@]}
    local lim=$(( n < m ? n : m ))
    local i=0
    while [[ $i -lt $lim ]]; do
      if [[ "${first_seg[$i]}" != "${seg[$i]}" ]]; then
        break
      fi
      i=$((i + 1))
    done
    n=$i
  done
  IFS="$IFS_save"

  # Si seul l'element root ('') ou la racine 'C:' est commun, pas utile.
  if [[ $n -le 1 ]]; then
    return
  fi

  local result="${first_seg[0]}"
  local i
  for ((i = 1; i < n; i++)); do
    result="$result/${first_seg[$i]}"
  done

  printf '%s\n' "$result"
}

# Ajoute une chaine eventuellement separee par des virgules au tableau sources_raw.
add_sources_from_string() {
  local list="$1"
  local IFS_save="$IFS"
  IFS=',' read -r -a parts <<< "$list"
  IFS="$IFS_save"
  local p
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    if [[ -n "$p" ]]; then
      sources_raw+=("$p")
    fi
  done
}

sources_raw=()
extensions_raw=""
output_name=""
help_requested=0

if [[ $# -eq 0 ]]; then
  show_usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      help_requested=1
      shift
      ;;
    --source-directory|-s)
      [[ $# -ge 2 ]] || fail "La valeur de --source-directory est manquante."
      add_sources_from_string "$2"
      shift 2
      ;;
    --extensions|-e)
      [[ $# -ge 2 ]] || fail "La valeur de --extensions est manquante."
      extensions_raw="$2"
      shift 2
      ;;
    --output-name|-o)
      [[ $# -ge 2 ]] || fail "La valeur de --output-name est manquante."
      output_name="$2"
      shift 2
      ;;
    -*)
      fail "Parametre inconnu: $1"
      ;;
    *)
      if [[ ${#sources_raw[@]} -eq 0 ]]; then
        add_sources_from_string "$1"
      elif [[ -z "$extensions_raw" ]]; then
        extensions_raw="$1"
      elif [[ -z "$output_name" ]]; then
        output_name="$1"
      else
        fail "Trop d'arguments positionnels."
      fi
      shift
      ;;
  esac
done

if [[ $help_requested -eq 1 ]]; then
  show_usage
  exit 0
fi

if [[ ${#sources_raw[@]} -eq 0 || -z "$extensions_raw" ]]; then
  show_usage
  fail "Les parametres --source-directory et --extensions sont obligatoires."
fi

require_command find
require_command mktemp
require_command zip

# Resolution + validation
resolved_sources=()
for src in "${sources_raw[@]}"; do
  resolved="$(resolve_path "$src")"
  [[ -d "$resolved" ]] || fail "Le repertoire source '$src' est introuvable ou n'est pas un dossier."
  resolved_sources+=("$resolved")
done

# Dedupe
declare -a deduped=()
declare -A seen=()
for r in "${resolved_sources[@]}"; do
  if [[ -z "${seen[$r]+x}" ]]; then
    seen[$r]=1
    deduped+=("$r")
  fi
done
resolved_sources=("${deduped[@]}")

# Detection d'imbrication
for a in "${resolved_sources[@]}"; do
  for b in "${resolved_sources[@]}"; do
    if [[ "$a" != "$b" && "$b" == "$a"/* ]]; then
      fail "Source imbriquee detectee: '$b' est contenu dans '$a'."
    fi
  done
done

common_parent=""
if [[ ${#resolved_sources[@]} -gt 1 ]]; then
  common_parent="$(get_common_parent "${resolved_sources[@]}")"
fi

declare -A extension_set=()
IFS=',' read -r -a extensions_list <<< "$extensions_raw"
for extension in "${extensions_list[@]}"; do
  normalized_extension="$(normalize_extension "$extension")"
  extension_set["${normalized_extension#.}"]=1
done

if [[ ${#extension_set[@]} -eq 0 ]]; then
  fail "Aucune extension exploitable n'a ete fournie."
fi

execution_directory="$(pwd)"

# Determination du nom de racine
if [[ ${#resolved_sources[@]} -eq 1 ]]; then
  primary_root_name="$(basename "${resolved_sources[0]}")"
elif [[ -n "$common_parent" ]]; then
  primary_root_name="$(basename "$common_parent")"
else
  primary_root_name="export"
fi

if [[ -z "$output_name" ]]; then
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  output_name="${primary_root_name}_${timestamp}.zip"
elif [[ "${output_name,,}" != *.zip ]]; then
  output_name="${output_name}.zip"
fi

zip_path="$execution_directory/$output_name"
staging_root="$(mktemp -d)"

cleanup() {
  if [[ -n "${staging_root-}" && -d "$staging_root" ]]; then
    rm -rf -- "$staging_root"
  fi
}
trap cleanup EXIT

# Plan de placement de chaque source dans le staging
declare -a plan_source=()
declare -a plan_staging_rel=()

if [[ ${#resolved_sources[@]} -eq 1 ]]; then
  plan_source+=("${resolved_sources[0]}")
  plan_staging_rel+=("$(basename "${resolved_sources[0]}")")
elif [[ -n "$common_parent" ]]; then
  common_leaf="$(basename "$common_parent")"
  for src in "${resolved_sources[@]}"; do
    rel_from_common="${src#"$common_parent"/}"
    plan_source+=("$src")
    plan_staging_rel+=("$common_leaf/$rel_from_common")
  done
else
  declare -A used_leaves=()
  for src in "${resolved_sources[@]}"; do
    leaf="$(basename "$src")"
    leaf_lower="${leaf,,}"
    if [[ -n "${used_leaves[$leaf_lower]+x}" ]]; then
      fail "Collision de noms : deux sources ont la meme feuille '$leaf'. Specifiez un parent commun ou renommez."
    fi
    used_leaves[$leaf_lower]=1
    plan_source+=("$src")
    plan_staging_rel+=("$leaf")
  done
fi

write_status "Preparation de l'export depuis : ${resolved_sources[*]}"
mkdir -p "$staging_root"

write_status "Analyse recursive des fichiers..."

declare -a matching_files=()
declare -a matching_source_root=()
declare -a matching_staging_rel=()

for ((idx = 0; idx < ${#plan_source[@]}; idx++)); do
  src_root="${plan_source[$idx]}"
  staging_rel="${plan_staging_rel[$idx]}"
  while IFS= read -r -d '' file; do
    file_ext="${file##*.}"
    lower_ext="${file_ext,,}"
    if [[ -n "${extension_set[$lower_ext]+x}" ]]; then
      matching_files+=("$file")
      matching_source_root+=("$src_root")
      matching_staging_rel+=("$staging_rel")
    fi
  done < <(find "$src_root" -type f -print0)
done

matching_count="${#matching_files[@]}"
if [[ "$matching_count" -eq 0 ]]; then
  write_status "Aucun fichier correspondant aux extensions demandees n'a ete trouve."
  write_status "Aucune archive ZIP n'a ete cree."
  exit 0
fi

write_status "$matching_count fichier(s) a copier."

copied_count=0
for ((i = 0; i < matching_count; i++)); do
  copied_count=$((copied_count + 1))
  file="${matching_files[$i]}"
  src_root="${matching_source_root[$i]}"
  staging_rel="${matching_staging_rel[$i]}"

  rel_path="${file#"$src_root"/}"
  destination_path="$staging_root/$staging_rel/$rel_path"
  destination_directory="$(dirname "$destination_path")"
  percent_complete=$(( copied_count * 100 / matching_count ))

  write_status "Copie [$percent_complete%] $staging_rel/$rel_path"
  mkdir -p "$destination_directory"
  cp -f -- "$file" "$destination_path"
done

write_status "Copie terminee : $matching_count fichier(s) exporte(s)."

# Top-level dirs a archiver
declare -a tops=()
declare -A tops_seen=()
for rel in "${plan_staging_rel[@]}"; do
  top="${rel%%/*}"
  if [[ -z "${tops_seen[$top]+x}" ]]; then
    tops_seen[$top]=1
    tops+=("$top")
  fi
done

if [[ -f "$zip_path" ]]; then
  rm -f -- "$zip_path"
fi

write_status "Creation de l'archive ZIP..."
(
  cd "$staging_root"
  zip -qr "$zip_path" "${tops[@]}"
)
write_status "Archive creee."

printf '%s\n' "$zip_path"
