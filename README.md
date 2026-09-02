# TeamCity Agent GitLab Release CLI and AndroidSDKManager

## Overview
TeamCity Agent GitLab Release CLI is a command-line tool designed to automate the process of creating GitLab releases triggered by build pipelines in JetBrains TeamCity. This tool streamlines the release management workflow by integrating GitLab releases directly into the CI/CD pipeline orchestrated by TeamCity.

## Features
- Automated Release Creation: Automatically create GitLab releases triggered by successful build pipelines in TeamCity.
- Tagging Support: Create GitLab releases with associated tags for version tracking and management.
- Flexible Configuration: Customize release settings and parameters through simple CLI options.
- Integration with TeamCity: Seamlessly integrate the release creation process with existing TeamCity build pipelines.

## Documentazione

| File | Domanda a cui risponde |
|---|---|
| [`INTENT.md`](INTENT.md) | **Perché** esiste il repo, obiettivi, non-obiettivi, confini |
| [`docs/overview.md`](docs/overview.md) | **Cosa** c'è dentro nel dettaglio: Dockerfile riga per riga, workflow, uso in pipeline |
| [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) | **Come** si lavora qui (regole per persone e agent AI) |
| [`CHANGELOG.md`](CHANGELOG.md) | **Cosa è cambiato** (ogni commit = release taggata `vX.Y.Z`) |

## Immagini pubblicate

- `ghcr.io/hiway-media/teamcity-agent-gitlab-release-cli-latest` — base `teamcity-agent-latest`, `linux/amd64`
- `ghcr.io/hiway-media/teamcity-agent-gitlab-release-cli-2023.11.3` — base `teamcity-agent-2023.11.3`, `linux/amd64,linux/arm64`

Tag pubblicati per ogni release: `vX.Y.Z`, `vX.Y`, `vX`, `latest`.
Il push di un tag git fa partire `docker-publish-latest` e `docker-publish-2023.11.3`.

## Aggiornamento automatico del canale `latest`

[`.github/workflows/teamcity-version-watch.yml`](.github/workflows/teamcity-version-watch.yml) gira ogni
giorno alle 05:17 UTC (più `workflow_dispatch` manuale) e decide fra tre azioni:

| Condizione | Azione |
|---|---|
| Base image `teamcity-agent-latest` ricostruita | **release**: bump (`minor` se cambia anche la versione TeamCity, `patch` se no), commit, tag `vX.Y.Z`, GitHub Release con le note, e dispatch di `docker-publish-latest` + `docker-publish-2023.11.3` su quel tag |
| Nuova release TeamCity ma base image ferma | **notify**: nessun tag — pubblicherebbe byte identici. Apre una issue verso `HiWay-Media/teamcity-agent` (dopo `policy.stale_after_days`, default 7) + recap Slack |
| Niente di nuovo | nulla, solo job summary |

Il gate è il **digest della base image** e non l'annuncio JetBrains perché `Dockerfile.latest` fa
`FROM ghcr.io/hiway-media/teamcity-agent-latest` senza pin: finché quella base non viene ricostruita nel
suo repo, il contenuto della nostra immagine non cambia.

Non serve un PAT: `workflow_dispatch` è una delle due eccezioni alla regola per cui gli eventi generati
con `GITHUB_TOKEN` non innescano altri workflow, quindi il watcher crea il tag e poi lancia i publish
con `gh workflow run --ref <tag>`.

Lo stesso controllo si esegue in locale:

```bash
./scripts/check-teamcity-release.sh          # report leggibile, exit 0 anche quando serve una release
./scripts/check-teamcity-release.sh --json   # output per pipeline
```

Stato tracciato in [`teamcity-version.json`](teamcity-version.json) (schema 2): `shipped` è l'ancora del
confronto, `pending` segna una catena bloccata a monte. Non modificarlo a mano.

**Stato al 2026-09-02**: base image a `v1.9.0` del 2025-09-18 (349 giorni), TeamCity a `2026.1.3`
(uscita 37 giorni fa) → il watcher sta in `notify`: il canale `latest` gira su un agent di settembre
2025 e si sblocca solo con un rebuild in `HiWay-Media/teamcity-agent`.

Configurazione opzionale: secret `SLACK_WEBHOOK_URL` (recap Slack), secret `BASE_REPO_PAT`
(`repository_dispatch` di rebuild verso il repo della base image), `policy.stale_after_days` nello state
file.
