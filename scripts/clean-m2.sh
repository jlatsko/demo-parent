#!/usr/bin/env bash
# clean_m2.sh — Clean old versions from Maven local repository
# Usage:
#   ./clean_m2.sh                          # all artifacts
#   ./clean_m2.sh -g com.example           # filter by groupId
#   ./clean_m2.sh -a my-artifact           # filter by artifactId
#   ./clean_m2.sh -g com.example -a my-artifact
#   ./clean_m2.sh --dry-run                # preview without deleting
#   ./clean_m2.sh --keep 3                 # keep N latest versions (default: 2)

set -uo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
M2_REPO="${HOME}/.m2/repository"
FILTER_GROUP=""
FILTER_ARTIFACT=""
DRY_RUN=false
KEEP_VERSIONS=2

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--group)    FILTER_GROUP="$2";    shift 2 ;;
    -a|--artifact) FILTER_ARTIFACT="$2"; shift 2 ;;
    -r|--repo)     M2_REPO="$2";         shift 2 ;;
    -k|--keep)     KEEP_VERSIONS="$2";   shift 2 ;;
    --dry-run)     DRY_RUN=true;         shift   ;;
    -h|--help)
      echo "Usage: $0 [-g groupId] [-a artifactId] [-k N] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
hr() { printf '%0.s─' {1..70}; echo; }

bytes_of() {
  du -sb "$1" 2>/dev/null | awk '{print $1}'
}

human() {
  local b=$1
  awk -v b="$b" 'BEGIN {
    if      (b >= 1073741824) printf "%.2f GiB\n", b/1073741824
    else if (b >= 1048576)   printf "%.2f MiB\n", b/1048576
    else if (b >= 1024)      printf "%.2f KiB\n", b/1024
    else                     printf "%d B\n",      b
  }'
}

# Sort version directories using version-aware sort (newest first)
sort_versions_newest_first() {
  local parent="$1"
  find "$parent" -mindepth 1 -maxdepth 1 -type d | sort -Vr
}

# ── Validation ───────────────────────────────────────────────────────────────
[[ -d "$M2_REPO" ]] || { echo "Repository not found: $M2_REPO" >&2; exit 1; }
command -v bc &>/dev/null || { echo "'bc' is required but not installed." >&2; exit 1; }

# ── Header ───────────────────────────────────────────────────────────────────
hr
echo "  Maven .m2 Repository Cleaner"
echo "  Repository : $M2_REPO"
echo "  Keep       : $KEEP_VERSIONS latest version(s) per artifact"
[[ -n "$FILTER_GROUP"    ]] && echo "  Group      : $FILTER_GROUP"
[[ -n "$FILTER_ARTIFACT" ]] && echo "  Artifact   : $FILTER_ARTIFACT"
$DRY_RUN && echo "  Mode       : DRY RUN (no files will be deleted)"
hr

INITIAL_BYTES=$(bytes_of "$M2_REPO")
echo ""
echo "  Initial repository size : $(human $INITIAL_BYTES)  ($INITIAL_BYTES bytes)"
echo ""
echo "  Scanning repository…"
echo ""

# ── Phase 1: Discover artifact directories ────────────────────────────────────
# Strategy: find all version dirs (dirs that contain *.pom or *.jar files)
# using a line-delimited approach safe in Cygwin.

declare -A ARTIFACT_VERSIONS
declare -A ARTIFACT_GROUP
declare -A ARTIFACT_ID

# Collect unique version directories into a temp file (newline-delimited, Cygwin-safe)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

find "$M2_REPO" -mindepth 3 -maxdepth 6 -type f \( -name "*.pom" -o -name "*.jar" \) \
  | sed 's|/[^/]*$||' \
  | sort -u > "$TMPFILE"

while IFS= read -r version_dir; do
  [[ -d "$version_dir" ]] || continue

  artifact_dir="$(dirname "$version_dir")"
  group_path="$(dirname "$artifact_dir")"
  rel_group="${group_path#"$M2_REPO/"}"
  artifact_id="$(basename "$artifact_dir")"
  group_id="${rel_group//\//.}"

  # Apply filters
  if [[ -n "$FILTER_GROUP" ]]; then
    [[ "$group_id" == "$FILTER_GROUP"* ]] || continue
  fi
  if [[ -n "$FILTER_ARTIFACT" ]]; then
    [[ "$artifact_id" == *"$FILTER_ARTIFACT"* ]] || continue
  fi

  key="${artifact_dir}"
  ARTIFACT_GROUP["$key"]="$group_id"
  ARTIFACT_ID["$key"]="$artifact_id"
  # Mark this artifact as seen (versions computed later per artifact dir)
done < "$TMPFILE"

# ── Phase 2: Compute statistics ───────────────────────────────────────────────
total_artifacts=0
total_versions_found=0
total_versions_to_delete=0
total_bytes_to_free=0
total_artifacts_affected=0

declare -A TO_DELETE

printf "  %-55s %6s %7s %7s %12s\n" "Artifact" "Found" "Keep" "Delete" "Reclaimable"
hr

for key in $(echo "${!ARTIFACT_GROUP[@]}" | tr ' ' '\n' | sort); do
  group_id="${ARTIFACT_GROUP[$key]}"
  artifact_id="${ARTIFACT_ID[$key]}"
  artifact_dir="$key"

  mapfile -t sorted_versions < <(sort_versions_newest_first "$artifact_dir")

  total_found=${#sorted_versions[@]}
  (( total_found == 0 )) && continue

  (( total_versions_found += total_found ))
  (( total_artifacts++ ))

  to_keep=$(( total_found < KEEP_VERSIONS ? total_found : KEEP_VERSIONS ))
  to_delete=$(( total_found - to_keep ))

  if (( to_delete <= 0 )); then
    continue
  fi

  (( total_versions_to_delete += to_delete ))
  (( total_artifacts_affected++ ))

  artifact_bytes=0
  delete_list=""
  for (( i=to_keep; i<total_found; i++ )); do
    v="${sorted_versions[$i]}"
    vbytes=$(bytes_of "$v")
    (( artifact_bytes += vbytes ))
    delete_list+="${v}"$'\n'
  done

  (( total_bytes_to_free += artifact_bytes ))
  TO_DELETE["$key"]="$delete_list"

  printf "  %-55s %6d %7d %7d %12s\n" \
    "${group_id}:${artifact_id}" \
    "$total_found" \
    "$to_keep" \
    "$to_delete" \
    "$(human $artifact_bytes)"
done

# ── Phase 3: Summary ──────────────────────────────────────────────────────────
hr
echo ""
echo "  ── Pre-Delete Summary ──────────────────────────────────────────────"
printf "  %-40s %d\n"  "Total artifacts scanned:"        "$total_artifacts"
printf "  %-40s %d\n"  "Artifacts with old versions:"    "$total_artifacts_affected"
printf "  %-40s %d\n"  "Total versions found:"           "$total_versions_found"
printf "  %-40s %d\n"  "Versions to keep:"               "$(( total_versions_found - total_versions_to_delete ))"
printf "  %-40s %d\n"  "Versions to delete:"             "$total_versions_to_delete"
printf "  %-40s %s\n"  "Estimated space to reclaim:"     "$(human $total_bytes_to_free)"
printf "  %-40s %s\n"  "Current repository size:"        "$(human $INITIAL_BYTES)"
echo ""

if (( total_artifacts_affected == 0 )); then
  echo "  Nothing to clean up. Exiting."
  exit 0
fi

# ── Phase 4: Confirm & execute ────────────────────────────────────────────────
if ! $DRY_RUN; then
  read -rp "  Proceed with deletion? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
  echo ""

  deleted_count=0
  for key in "${!TO_DELETE[@]}"; do
    while IFS= read -r version_dir; do
      [[ -z "$version_dir" ]] && continue
      echo "  Deleting: $version_dir"
      rm -rf "$version_dir"
      (( deleted_count++ ))
    done <<< "${TO_DELETE[$key]}"
  done

  FINAL_BYTES=$(bytes_of "$M2_REPO")
  ACTUAL_FREED=$(( INITIAL_BYTES - FINAL_BYTES ))

  echo ""
  hr
  echo "  ── Post-Delete Summary ───────────────────────────────────────────"
  printf "  %-40s %d\n"  "Version directories deleted:"  "$deleted_count"
  printf "  %-40s %s\n"  "Repository size before:"       "$(human $INITIAL_BYTES)"
  printf "  %-40s %s\n"  "Repository size after:"        "$(human $FINAL_BYTES)"
  printf "  %-40s %s\n"  "Actual space freed:"           "$(human $ACTUAL_FREED)"
  hr
else
  echo "  DRY RUN complete — no files were deleted."
  hr
fi
