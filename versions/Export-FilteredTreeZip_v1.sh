#!/usr/bin/env bash

set -euo pipefail

show_usage() {
  local script_name
  script_name="$(basename "$0")"
  cat <<EOF
Usage:
  ./$script_name --source-directory <chemin> --extensions <ext1,ext2,...> [--output-name <nom_zip>]
  ./$script_name -s <chemin> -e <ext1,ext2,...> [-o <nom_zip>]
  ./$script_name <chemin> <ext1,ext2,...> [nom_zip]
  ./$script_name --help

Description:
  Recherche recursivement les fichiers correspondant aux extensions fournies,
  reconstruit l'arborescence d'origine dans une racine nommee comme le dossier source,
  cree un fichier ZIP dans le repertoire courant d'execution,
  puis affiche le chemin complet de l'archive creee.

Parametres:
  -s, --source-directory  Repertoire source a analyser.
  -e, --extensions        Liste des extensions a inclure, avec ou sans point.
                          Exemples valides: html, js, .html, .js
  -o, --output-name       Nom du fichier ZIP a creer. ".zip" est ajoute si necessaire.
  -h, --help              Affiche cette aide.

Exemples:
  ./$script_name --source-directory '/src' --extensions html,js
  ./$script_name -s '/src' -e html,js -o export_front_back
  ./$script_name '/src' html,js export_front_back
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

source_directory=""
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
      source_directory="$2"
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
      if [[ -z "$source_directory" ]]; then
        source_directory="$1"
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

if [[ -z "$source_directory" || -z "$extensions_raw" ]]; then
  show_usage
  fail "Les parametres -SourceDirectory et -Extensions sont obligatoires."
fi

require_command find
require_command mktemp
require_command zip

resolved_source="$(resolve_path "$source_directory")"
[[ -d "$resolved_source" ]] || fail "Le repertoire source '$source_directory' est introuvable ou n'est pas un dossier."

declare -A extension_set=()
IFS=',' read -r -a extensions_list <<< "$extensions_raw"
for extension in "${extensions_list[@]}"; do
  normalized_extension="$(normalize_extension "$extension")"
  extension_set["$normalized_extension"]=1
done

if [[ ${#extension_set[@]} -eq 0 ]]; then
  fail "Aucune extension exploitable n'a ete fournie."
fi

source_root_name="$(basename "$resolved_source")"
execution_directory="$(pwd)"

if [[ -z "$output_name" ]]; then
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  output_name="${source_root_name}_${timestamp}.zip"
elif [[ "${output_name,,}" != *.zip ]]; then
  output_name="${output_name}.zip"
fi

zip_path="$execution_directory/$output_name"
staging_root="$(mktemp -d)"
staging_source_root="$staging_root/$source_root_name"

cleanup() {
  if [[ -n "${staging_root-}" && -d "$staging_root" ]]; then
    rm -rf -- "$staging_root"
  fi
}
trap cleanup EXIT

write_status "Preparation de l'export depuis '$resolved_source'."
mkdir -p "$staging_source_root"

write_status "Analyse recursive des fichiers..."

declare -a matching_files=()
while IFS= read -r -d '' file; do
  lower_file="${file,,}"
  for extension in "${!extension_set[@]}"; do
    if [[ "$lower_file" == *"$extension" ]]; then
      matching_files+=("$file")
      break
    fi
  done
done < <(find "$resolved_source" -type f -print0)

matching_count="${#matching_files[@]}"
if [[ "$matching_count" -eq 0 ]]; then
  write_status "Aucun fichier correspondant aux extensions demandees n'a ete trouve."
else
  write_status "$matching_count fichier(s) a copier."
fi

copied_count=0
for file in "${matching_files[@]}"; do
  copied_count=$((copied_count + 1))
  relative_path="${file#"$resolved_source"/}"
  destination_path="$staging_source_root/$relative_path"
  destination_directory="$(dirname "$destination_path")"
  percent_complete=$(( copied_count * 100 / matching_count ))

  write_status "Copie [$percent_complete%] $relative_path"
  mkdir -p "$destination_directory"
  cp -f -- "$file" "$destination_path"
done

if [[ "$matching_count" -gt 0 ]]; then
  write_status "Copie terminee : $matching_count fichier(s) exporte(s)."
fi

if [[ -f "$zip_path" ]]; then
  rm -f -- "$zip_path"
fi

write_status "Creation de l'archive ZIP..."
(
  cd "$staging_root"
  zip -qr "$zip_path" "$source_root_name"
)
write_status "Archive creee."

printf '%s\n' "$zip_path"
