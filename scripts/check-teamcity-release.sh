#!/usr/bin/env bash
# check-teamcity-release.sh — decide se il canale "latest" va rilasciato, segnalato o lasciato stare.
#
# Perche' due segnali e non uno: Dockerfile.latest fa FROM ghcr.io/hiway-media/teamcity-agent-latest,
# che vive in un ALTRO repo (HiWay-Media/teamcity-agent). Una release TeamCity non cambia il contenuto
# della nostra immagine finche' quella base non viene ricostruita. Percio':
#
#   base image (digest) cambiata      -> c'e' contenuto nuovo da pubblicare  -> action=release
#   TeamCity avanti, base image ferma -> non c'e' niente da pubblicare       -> action=notify
#   ne' l'una ne' l'altra                                                    -> action=none
#
# Il confronto e' contro shipped.digest (cosa abbiamo davvero pubblicato), non contro l'ultima
# osservazione: cosi' i run di sola segnalazione non consumano il segnale di release.
#
# Bump: minor se la versione TeamCity e' cambiata rispetto a shipped.teamcity, altrimenti patch.
#
# Contratto (come gli health-check di devops_hiway):
#   exit 0  sempre, anche con action=release/notify (sono WARN, non errori)
#   exit 1  solo per errore sistemico del check (API irraggiungibile, JSON malformato, jq mancante)
#
# Uso:
#   scripts/check-teamcity-release.sh                    # report leggibile
#   scripts/check-teamcity-release.sh --json             # solo JSON
#   scripts/check-teamcity-release.sh --write            # aggiorna le osservazioni + pending
#   scripts/check-teamcity-release.sh --mark-shipped TAG # registra una release pubblicata
#   scripts/check-teamcity-release.sh --github-output    # scrive gli output su $GITHUB_OUTPUT

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
MARK_SHIPPED=""

die() { echo "ERRORE: $*" >&2; exit 1; }
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json)          MODE_JSON=1 ;;
    --write)         MODE_WRITE=1 ;;
    --github-output) MODE_GH_OUTPUT=1 ;;
    --mark-shipped)  shift; MARK_SHIPPED="${1:-}"; MODE_WRITE=1 ;;
    --state)         shift; STATE_FILE="${1:-}" ;;
    -h|--help)       usage ;;
    *)               die "opzione sconosciuta: $1 (usa --help)" ;;
  esac
  shift
done

command -v jq   >/dev/null 2>&1 || die "jq non installato"
command -v curl >/dev/null 2>&1 || die "curl non installato"
[ -f "$STATE_FILE" ] || die "state file non trovato: $STATE_FILE"
jq -e . "$STATE_FILE" >/dev/null 2>&1 || die "state file non e' JSON valido: $STATE_FILE"

today="$(date -u +'%Y-%m-%d')"

# giorni trascorsi da una data ISO (YYYY-MM-DD o timestamp completo). Portabile GNU/BSD.
days_since() {
  local iso="${1%%T*}" epoch now
  [ -n "$iso" ] || { echo ""; return; }
  epoch="$(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$iso" +%s 2>/dev/null || echo '')"
  [ -n "$epoch" ] || { echo ""; return; }
  now="$(date -u +%s)"
  echo $(( (now - epoch) / 86400 ))
}

# ---------------------------------------------------------------- 1. JetBrains
jb_raw="$($CURL "$JETBRAINS_API")" || die "JetBrains data services irraggiungibile"
jq -e '.TC[0].version' >/dev/null 2>&1 <<<"$jb_raw" || die "risposta JetBrains inattesa"

tc_version="$(jq -r '.TC[0].version'         <<<"$jb_raw")"
tc_major="$(  jq -r '.TC[0].majorVersion'    <<<"$jb_raw")"
tc_build="$(  jq -r '.TC[0].build // ""'     <<<"$jb_raw")"
tc_released="$(jq -r '.TC[0].date // ""'     <<<"$jb_raw")"
tc_notes="$(  jq -r '.TC[0].notesLink // ""' <<<"$jb_raw")"

# ------------------------------------------- 2. immagine agent ufficiale pronta
agent_ready=false
if $CURL -o /dev/null -w '%{http_code}' "${DOCKERHUB_AGENT}/${tc_version}-linux" 2>/dev/null | grep -q '^200$'; then
  agent_ready=true
fi

# --------------------------------- 3. base image: digest + versione + data build
# Package pubblico su GHCR: basta il token anonimo. Non fatale se fallisce.
base_digest=""; base_version=""; base_created=""
gh_token="$($CURL "https://ghcr.io/token?scope=repository%3A${GHCR_REPO}%3Apull&service=ghcr.io" \
  | jq -r '.token // empty')" || true

if [ -n "${gh_token:-}" ]; then
  reg_get() {
    $CURL -H "Authorization: Bearer ${gh_token}" \
      -H 'Accept: application/vnd.oci.image.index.v1+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$1"
  }
  base_digest="$($CURL -I -H "Authorization: Bearer ${gh_token}" \
      -H 'Accept: application/vnd.oci.image.index.v1+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "https://ghcr.io/v2/${GHCR_REPO}/manifests/${GHCR_TAG}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')" || true

  # index multi-arch -> manifest amd64 -> config blob -> label/created
  manifest="$(reg_get "https://ghcr.io/v2/${GHCR_REPO}/manifests/${GHCR_TAG}")" || true
  config_digest="$(jq -r '.config.digest // empty' <<<"${manifest:-{\}}" 2>/dev/null || echo '')"
  if [ -z "$config_digest" ] && [ -n "${manifest:-}" ]; then
    arch_digest="$(jq -r '[.manifests[]? | select(.platform.architecture=="amd64")][0].digest // empty' <<<"$manifest" 2>/dev/null || echo '')"
    if [ -n "$arch_digest" ]; then
      manifest="$(reg_get "https://ghcr.io/v2/${GHCR_REPO}/manifests/${arch_digest}")" || true
      config_digest="$(jq -r '.config.digest // empty' <<<"${manifest:-{\}}" 2>/dev/null || echo '')"
    fi
  fi
  if [ -n "$config_digest" ]; then
    # i blob su GHCR redirigono su CDN: serve -L
    cfg="$($CURL -L -H "Authorization: Bearer ${gh_token}" \
      "https://ghcr.io/v2/${GHCR_REPO}/blobs/${config_digest}")" || true
    if [ -n "${cfg:-}" ]; then
      base_version="$(jq -r '.config.Labels["org.opencontainers.image.version"] // ""' <<<"$cfg" 2>/dev/null || echo '')"
      base_created="$(jq -r '.created // ""'                                          <<<"$cfg" 2>/dev/null || echo '')"
    fi
  fi
fi

base_age="$(days_since "$base_created")"

# ------------------------------------------------------ 4. confronto con shipped
shipped_digest="$(jq -r '.shipped.digest   // ""' "$STATE_FILE")"
shipped_tc="$(    jq -r '.shipped.teamcity // ""' "$STATE_FILE")"
shipped_tag="$(   jq -r '.shipped.tag      // ""' "$STATE_FILE")"
pending_since="$( jq -r '.pending.since    // ""' "$STATE_FILE")"
stale_after="$(   jq -r '.policy.stale_after_days // 7' "$STATE_FILE")"

base_changed=false
if [ -n "$base_digest" ] && [ "$base_digest" != "$shipped_digest" ]; then
  base_changed=true
fi

tc_changed=false
if [ -n "$tc_version" ] && [ "$tc_version" != "$shipped_tc" ]; then
  tc_changed=true
fi

action=none; bump=""
if [ "$base_changed" = true ]; then
  action=release
  if [ "$tc_changed" = true ]; then bump="minor"; else bump="patch"; fi
elif [ "$tc_changed" = true ]; then
  action=notify
fi

# pending: TeamCity avanti ma base ferma. "since" = data della release TeamCity.
new_pending_since="$pending_since"
if [ "$action" = notify ]; then
  [ -n "$pending_since" ] || new_pending_since="${tc_released:-$today}"
else
  new_pending_since=""
fi
pending_days="$(days_since "$new_pending_since")"
stale=false
if [ -n "$pending_days" ] && [ "$pending_days" -gt "$stale_after" ] 2>/dev/null; then stale=true; fi

reasons=()
case "$action" in
  release)
    if [ "$tc_changed" = true ]; then
      reasons+=("base image ricostruita e TeamCity ${shipped_tc:-n/d} -> ${tc_version}: release ${bump}")
    else
      reasons+=("base image ricostruita (${base_version:-?}, TeamCity invariata): release ${bump}")
    fi
    reasons+=("digest ${shipped_digest:0:19}... -> ${base_digest:0:19}...")
    ;;
  notify)
    reasons+=("TeamCity ${tc_version} disponibile (uscita ${tc_released:-?}) ma la base image non e' stata ricostruita: niente di nuovo da pubblicare")
    reasons+=("base image ${GHCR_REPO}:${GHCR_TAG} = ${base_version:-?} del ${base_created%%T*} (${base_age:-?} giorni)")
    [ "$stale" = true ] && reasons+=("in attesa da ${pending_days} giorni (soglia ${stale_after}): va ricostruita ${GHCR_REPO} nel suo repo")
    ;;
  none)
    reasons+=("allineato: TeamCity ${tc_version}, base image ${base_version:-?} invariata dal rilascio ${shipped_tag:-n/d}")
    ;;
esac
[ "$tc_changed" = true ] && [ "$agent_ready" = false ] && \
  reasons+=("nota: jetbrains/teamcity-agent:${tc_version}-linux non ancora su Docker Hub")

result="$(jq -n \
  --arg action "$action" --arg bump "$bump" \
  --arg version "$tc_version" --arg major "$tc_major" --arg build "$tc_build" \
  --arg released "$tc_released" --arg notes "$tc_notes" --arg checked "$today" \
  --arg base_digest "$base_digest" --arg base_version "$base_version" \
  --arg base_created "$base_created" --arg base_age "${base_age:-}" \
  --arg shipped_digest "$shipped_digest" --arg shipped_tc "$shipped_tc" --arg shipped_tag "$shipped_tag" \
  --arg pending_since "$new_pending_since" --arg pending_days "${pending_days:-}" \
  --argjson base_changed "$base_changed" --argjson tc_changed "$tc_changed" \
  --argjson agent_ready "$agent_ready" --argjson stale "$stale" \
  --argjson reasons "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s .)" \
  '{
     action: $action, bump: $bump,
     base_changed: $base_changed, teamcity_changed: $tc_changed,
     agent_image_ready: $agent_ready, pending_stale: $stale,
     teamcity: { version:$version, major:$major, build:$build, released:$released,
                 notes:$notes, checked:$checked },
     base_image: { digest:$base_digest, version:$base_version, created:$base_created,
                   age_days:(($base_age|tonumber?) // null) },
     shipped: { digest:$shipped_digest, teamcity:$shipped_tc, tag:$shipped_tag },
     pending: { since:$pending_since, days:(($pending_days|tonumber?) // null) },
     reasons: $reasons
   }')"

# ------------------------------------------------------------------ 5. scrittura
if [ "$MODE_WRITE" = 1 ]; then
  tmp="$(mktemp)"
  jq --argjson r "$result" --arg tag "$MARK_SHIPPED" --arg today "$today" '
      .teamcity.version  = $r.teamcity.version
    | .teamcity.major    = $r.teamcity.major
    | .teamcity.build    = $r.teamcity.build
    | .teamcity.released = $r.teamcity.released
    | .teamcity.notes    = $r.teamcity.notes
    | .teamcity.checked  = $today
    | .base_image.digest  = (if ($r.base_image.digest  | length) > 0 then $r.base_image.digest  else .base_image.digest  end)
    | .base_image.version = (if ($r.base_image.version | length) > 0 then $r.base_image.version else .base_image.version end)
    | .base_image.created = (if ($r.base_image.created | length) > 0 then $r.base_image.created else .base_image.created end)
    | .base_image.checked = $today
    | .pending = (if ($r.pending.since | length) > 0
                  then { teamcity: $r.teamcity.version, since: $r.pending.since }
                  else null end)
    | if ($tag | length) > 0 then
        .shipped.tag      = $tag
      | .shipped.digest   = (if ($r.base_image.digest | length) > 0 then $r.base_image.digest else .shipped.digest end)
      | .shipped.teamcity = $r.teamcity.version
      | .shipped.date     = $today
      | .pending          = null
      else . end
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
fi

if [ "$MODE_GH_OUTPUT" = 1 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "action=$(jq -r '.action'                  <<<"$result")"
    echo "bump=$(jq -r '.bump'                      <<<"$result")"
    echo "version=$(jq -r '.teamcity.version'       <<<"$result")"
    echo "major=$(jq -r '.teamcity.major'           <<<"$result")"
    echo "released=$(jq -r '.teamcity.released'     <<<"$result")"
    echo "notes=$(jq -r '.teamcity.notes'           <<<"$result")"
    echo "digest=$(jq -r '.base_image.digest'       <<<"$result")"
    echo "base_version=$(jq -r '.base_image.version'   <<<"$result")"
    echo "base_created=$(jq -r '.base_image.created'   <<<"$result")"
    echo "base_age=$(jq -r '.base_image.age_days // ""' <<<"$result")"
    echo "shipped_teamcity=$(jq -r '.shipped.teamcity' <<<"$result")"
    echo "shipped_tag=$(jq -r '.shipped.tag'        <<<"$result")"
    echo "pending_days=$(jq -r '.pending.days // ""' <<<"$result")"
    echo "pending_stale=$(jq -r '.pending_stale'    <<<"$result")"
    echo "reason=$(jq -r '.reasons | join("; ")'    <<<"$result")"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$MODE_JSON" = 1 ]; then
  echo "$result"
else
  case "$action" in
    release) status=WARN ;;
    notify)  status=WARN ;;
    *)       status=OK   ;;
  esac
  echo "[${status}] check-teamcity-release  (${today})  action=${action}${bump:+ bump=${bump}}"
  echo "  TeamCity ultima release : ${tc_version} (major ${tc_major}, build ${tc_build:-?}, ${tc_released:-?})"
  echo "  agent image ufficiale   : jetbrains/teamcity-agent:${tc_version}-linux -> $([ "$agent_ready" = true ] && echo presente || echo assente)"
  echo "  base image              : ${GHCR_REPO}:${GHCR_TAG} = ${base_version:-?} del ${base_created%%T*} (${base_age:-?} giorni)"
  echo "  base image digest       : ${base_digest:-<non leggibile>}"
  echo "  ultimo rilascio nostro  : ${shipped_tag:-n/d} (TeamCity ${shipped_tc:-n/d}, digest ${shipped_digest:0:19}...)"
  [ -n "${pending_days:-}" ] && echo "  in attesa da            : ${pending_days} giorni (soglia ${stale_after})"
  printf '  motivo                  : %s\n' "${reasons[@]}"
fi

exit 0
