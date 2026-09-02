#!/usr/bin/env bash
# check-teamcity-release.sh — rileva se serve ricostruire l'immagine agent "latest".
#
# Due segnali indipendenti:
#   1. TeamCity  — nuova release on-prem pubblicata da JetBrains (data.services.jetbrains.com)
#                  + immagine agent ufficiale disponibile su Docker Hub (jetbrains/teamcity-agent).
#   2. Base image — il digest di ghcr.io/hiway-media/teamcity-agent-latest:latest e cambiato
#                  (e' questo che cambia davvero il contenuto della NOSTRA immagine).
#
# Contratto (come gli health-check di devops_hiway):
#   exit 0  sempre, anche quando c'e' un aggiornamento (e' un WARN, non un errore)
#   exit 1  solo per errore sistemico del check (API irraggiungibile, JSON malformato, jq mancante)
#
# Uso:
#   scripts/check-teamcity-release.sh                 # report leggibile
#   scripts/check-teamcity-release.sh --json          # solo JSON (per pipeline)
#   scripts/check-teamcity-release.sh --write         # aggiorna teamcity-version.json
#   scripts/check-teamcity-release.sh --github-output # scrive gli output su $GITHUB_OUTPUT

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${REPO_ROOT}/teamcity-version.json"

JETBRAINS_API="https://data.services.jetbrains.com/products/releases?code=TC&latest=true&type=release"
DOCKERHUB_AGENT="https://hub.docker.com/v2/repositories/jetbrains/teamcity-agent/tags"
GHCR_REPO="hiway-media/teamcity-agent-latest"
GHCR_TAG="latest"

CURL="curl -sS --max-time 20 --retry 2 --retry-connrefused"

MODE_JSON=0
MODE_WRITE=0
MODE_GH_OUTPUT=0

die() { echo "ERRORE: $*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)          MODE_JSON=1 ;;
    --write)         MODE_WRITE=1 ;;
    --github-output) MODE_GH_OUTPUT=1 ;;
    --state)         shift; STATE_FILE="${1:-}" ;;
    -h|--help)       usage ;;
    *)               die "opzione sconosciuta: $1 (usa --help)" ;;
  esac
  shift
done

command -v jq  >/dev/null 2>&1 || die "jq non installato"
command -v curl >/dev/null 2>&1 || die "curl non installato"
[ -f "$STATE_FILE" ] || die "state file non trovato: $STATE_FILE"
jq -e . "$STATE_FILE" >/dev/null 2>&1 || die "state file non e' JSON valido: $STATE_FILE"

# ---------------------------------------------------------------- 1. JetBrains
jb_raw="$($CURL "$JETBRAINS_API")" || die "JetBrains data services irraggiungibile"
jq -e '.TC[0].version' >/dev/null 2>&1 <<<"$jb_raw" || die "risposta JetBrains inattesa"

new_version="$(jq -r '.TC[0].version'      <<<"$jb_raw")"
new_major="$(  jq -r '.TC[0].majorVersion' <<<"$jb_raw")"
new_build="$(  jq -r '.TC[0].build // ""'  <<<"$jb_raw")"
new_date="$(   jq -r '.TC[0].date // ""'   <<<"$jb_raw")"
new_notes="$(  jq -r '.TC[0].notesLink // ""' <<<"$jb_raw")"

# ------------------------------------------- 2. immagine agent ufficiale pronta
# Una release TeamCity e' azionabile solo quando esiste jetbrains/teamcity-agent:<ver>-linux.
agent_ready=false
if $CURL -o /dev/null -w '%{http_code}' "${DOCKERHUB_AGENT}/${new_version}-linux" 2>/dev/null | grep -q '^200$'; then
  agent_ready=true
fi

# ------------------------------------------------------- 3. digest base image
# Package pubblico su GHCR: basta il token anonimo. Non fatale se fallisce.
base_digest=""
gh_token="$($CURL "https://ghcr.io/token?scope=repository%3A${GHCR_REPO}%3Apull&service=ghcr.io" \
  | jq -r '.token // empty')" || true
if [ -n "$gh_token" ]; then
  base_digest="$($CURL -I \
    -H "Authorization: Bearer ${gh_token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${GHCR_REPO}/manifests/${GHCR_TAG}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')" || true
fi

# ------------------------------------------------------------ 4. confronto stato
old_version="$(jq -r '.teamcity.version // ""'   "$STATE_FILE")"
old_digest="$( jq -r '.base_image.digest // ""'  "$STATE_FILE")"

teamcity_changed=false
[ -n "$new_version" ] && [ "$new_version" != "$old_version" ] && teamcity_changed=true

base_changed=false
first_digest=false
if [ -n "$base_digest" ]; then
  if [ -z "$old_digest" ]; then
    first_digest=true
    base_changed=true
  elif [ "$base_digest" != "$old_digest" ]; then
    base_changed=true
  fi
fi

# Un bump TeamCity conta solo se l'immagine agent ufficiale esiste gia'.
has_update=false
{ [ "$teamcity_changed" = true ] && [ "$agent_ready" = true ]; } && has_update=true
[ "$base_changed" = true ] && has_update=true

reasons=()
[ "$teamcity_changed" = true ] && [ "$agent_ready" = true ] && \
  reasons+=("nuova release TeamCity ${old_version:-?} -> ${new_version}")
[ "$teamcity_changed" = true ] && [ "$agent_ready" = false ] && \
  reasons+=("TeamCity ${new_version} annunciata ma jetbrains/teamcity-agent:${new_version}-linux non ancora pubblicata (attendo)")
[ "$first_digest" = true ] && reasons+=("baseline digest base image mancante: primo allineamento")
[ "$base_changed" = true ] && [ "$first_digest" = false ] && \
  reasons+=("base image ${GHCR_REPO}:${GHCR_TAG} cambiata (${old_digest:0:19}... -> ${base_digest:0:19}...)")
[ ${#reasons[@]} -eq 0 ] && reasons+=("nessun cambiamento: TeamCity ${new_version}, base image invariata")

now="$(date -u +'%Y-%m-%d')"
result="$(jq -n \
  --arg version "$new_version" --arg major "$new_major" --arg build "$new_build" \
  --arg released "$new_date" --arg notes "$new_notes" --arg checked "$now" \
  --arg old_version "$old_version" --arg base_digest "$base_digest" --arg old_digest "$old_digest" \
  --argjson teamcity_changed "$teamcity_changed" --argjson base_changed "$base_changed" \
  --argjson agent_ready "$agent_ready" --argjson has_update "$has_update" \
  --argjson reasons "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s .)" \
  '{
     has_update: $has_update,
     teamcity_changed: $teamcity_changed,
     base_changed: $base_changed,
     agent_image_ready: $agent_ready,
     teamcity: { version:$version, major:$major, build:$build, released:$released,
                 notes:$notes, checked:$checked, previous:$old_version },
     base_image: { digest:$base_digest, previous:$old_digest, checked:$checked },
     reasons: $reasons
   }')"

# ------------------------------------------------------------------ 5. output
if [ "$MODE_WRITE" = 1 ]; then
  tmp="$(mktemp)"
  jq --argjson r "$result" '
      .teamcity.version  = $r.teamcity.version
    | .teamcity.major    = $r.teamcity.major
    | .teamcity.build    = $r.teamcity.build
    | .teamcity.released = $r.teamcity.released
    | .teamcity.notes    = $r.teamcity.notes
    | .teamcity.checked  = $r.teamcity.checked
    | .base_image.digest  = (if ($r.base_image.digest | length) > 0 then $r.base_image.digest else .base_image.digest end)
    | .base_image.checked = $r.base_image.checked
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
fi

if [ "$MODE_GH_OUTPUT" = 1 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "has_update=$(jq -r '.has_update'        <<<"$result")"
    echo "teamcity_changed=$(jq -r '.teamcity_changed' <<<"$result")"
    echo "base_changed=$(jq -r '.base_changed'    <<<"$result")"
    echo "version=$(jq -r '.teamcity.version'     <<<"$result")"
    echo "previous=$(jq -r '.teamcity.previous'   <<<"$result")"
    echo "major=$(jq -r '.teamcity.major'         <<<"$result")"
    echo "notes=$(jq -r '.teamcity.notes'         <<<"$result")"
    echo "digest=$(jq -r '.base_image.digest'     <<<"$result")"
    echo "reason=$(jq -r '.reasons | join("; ")'  <<<"$result")"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$MODE_JSON" = 1 ]; then
  echo "$result"
else
  status="OK"; [ "$has_update" = true ] && status="WARN"
  echo "[${status}] check-teamcity-release  ($now)"
  echo "  TeamCity ultima release : ${new_version} (major ${new_major}, build ${new_build:-?}, ${new_date:-?})"
  echo "  tracciata nel repo      : ${old_version:-<nessuna>}"
  echo "  agent image ufficiale   : jetbrains/teamcity-agent:${new_version}-linux -> $([ "$agent_ready" = true ] && echo presente || echo assente)"
  echo "  base image digest       : ${base_digest:-<non leggibile>}"
  echo "  digest tracciato        : ${old_digest:-<nessuno>}"
  echo "  rebuild necessario      : ${has_update}"
  printf '  motivo                  : %s\n' "${reasons[@]}"
fi

exit 0
