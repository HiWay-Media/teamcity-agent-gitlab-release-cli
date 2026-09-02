# Changelog

Tutte le modifiche rilevanti a questo repository.
Formato [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioning [SemVer](https://semver.org/lang/it/).

Convenzione: **ogni commit e una release taggata `vX.Y.Z`**. Il tag pushato fa partire
`docker-publish-latest` e `docker-publish-2023.11.3`, che pubblicano le immagini su GHCR con i tag
`vX.Y.Z`, `vX.Y`, `vX` e `latest`.

## [1.8.0] - 2026-09-02

### Added

- `teamcity-version-watch`: path **release** completo — commit, tag `vX.Y.Z`, GitHub Release con note
  generate, e dispatch di `docker-publish-latest` + `docker-publish-2023.11.3` sul tag. Bump `minor` se
  cambia la versione TeamCity, `patch` se cambia solo la base image.
- `teamcity-version-watch`: path **notify** — quando TeamCity va avanti ma la base image resta ferma non
  si tagga niente (pubblicherebbe byte identici): issue verso `HiWay-Media/teamcity-agent` dopo
  `policy.stale_after_days`, recap Slack, e `repository_dispatch` opzionale di rebuild (`BASE_REPO_PAT`).
- `workflow_dispatch` su `docker-publish-latest.yml` e `docker-publish-2023.11.3.yml`, così il watcher
  può lanciarli sul tag appena creato senza bisogno di un PAT.
- `check-teamcity-release.sh`: lettura di versione e data di build della base image dalle label OCI
  (`org.opencontainers.image.version`, `.created`) via config blob GHCR, `--mark-shipped TAG`, e
  decisione a tre stati `release` / `notify` / `none`.

### Changed

- **Il gate del rilascio è il digest della base image, non l'annuncio JetBrains.** `Dockerfile.latest`
  fa `FROM ghcr.io/hiway-media/teamcity-agent-latest` senza pin: finché quella base non viene
  ricostruita in `HiWay-Media/teamcity-agent`, una release qui pubblica byte identici.
- `teamcity-version.json` schema 2: `shipped` (ancora del confronto) separato dalle osservazioni
  `teamcity` / `base_image`, più `pending` e `policy.stale_after_days`.
- Rimosso il path PR e la dipendenza da `RELEASE_PAT`: `workflow_dispatch` è eccezione alla regola del
  `GITHUB_TOKEN`, quindi il dispatch esplicito basta.
- `INTENT.md`: il principio "l'automazione propone, la persona dispone" sostituito da "si rilascia solo
  se c'è contenuto nuovo" + "se la catena si blocca, si dice", che descrivono il disegno reale.

### Fixed

- `check-teamcity-release.sh`: un campo `jq` che valutava a stream vuoto (`"" | tonumber?`) annullava
  l'intero oggetto, producendo JSON vuoto nel path `release` e facendo fallire `--write`.
- `teamcity-version-watch`: `printf '- ...'` interpretato come opzione (`printf: - : invalid option`),
  che uccideva lo step di prep dopo aver già marcato lo stato. Aggiunto `--` e spostato
  `--mark-shipped` in fondo allo step.

### Notes

- Al 2026-09-02 la base image `teamcity-agent-latest` è a `v1.9.0` del **2025-09-18** (349 giorni) mentre
  TeamCity è a **2026.1.3**: il canale `latest` gira su un agent di settembre 2025. Il watcher è in
  `notify` e lo resterà finché quella base non viene ricostruita.

## [1.7.0] - 2026-09-02

### Added

- `AGENTS.md`, `CLAUDE.md`, `INTENT.md`: regole operative e documento di intento allineati alla
  convenzione di `devops_hiway` (perche / cosa / come).
- `teamcity-version.json`: stato tracciato della release TeamCity e del digest della base image.
- `scripts/check-teamcity-release.sh`: check con contratto `--json` / `--write` / `--github-output`,
  exit 0 anche su WARN (exit 1 solo per errore sistemico).
- `.github/workflows/teamcity-version-watch.yml`: watcher schedulato giornaliero che apre una PR
  (o, in `mode=release`, committa e tagga) quando esce una nuova release TeamCity o cambia il digest
  della base image `ghcr.io/hiway-media/teamcity-agent-latest`.
- `CHANGELOG.md` (questo file).

### Changed

- La documentazione dettagliata che stava in `CLAUDE.md` e ora in `docs/overview.md`; `CLAUDE.md`
  contiene le regole operative per gli agent, come in `devops_hiway`.

## Prima della 1.7.0

Storia non ricostruita in questo file: vedi `git log` e i tag da `v0.1.0` a `v1.6.3`.
Le release precedenti sono bump di `Dockerfile.latest` / `Dockerfile.2023.11.3` (versioni Android SDK,
golangci-lint, toolchain Go) pubblicati come immagini su GHCR.
