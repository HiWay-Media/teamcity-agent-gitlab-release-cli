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

`.github/workflows/teamcity-version-watch.yml` gira ogni giorno alle 05:17 UTC e controlla due segnali:

1. una **nuova release TeamCity** su `data.services.jetbrains.com` (azionabile solo quando esiste anche
   `jetbrains/teamcity-agent:<versione>-linux` su Docker Hub);
2. un **nuovo digest** della base image `ghcr.io/hiway-media/teamcity-agent-latest:latest`.

Se qualcosa è cambiato aggiorna [`teamcity-version.json`](teamcity-version.json) e il CHANGELOG, e apre
la PR `chore/teamcity-watch`. Con `mode=release` (o la repository variable `TC_WATCH_AUTO_RELEASE=true`)
committa su `main` e spinge il tag `vX.Y.Z`, che pubblica le immagini — questo richiede il secret
`RELEASE_PAT`, perché un tag pushato con `GITHUB_TOKEN` non innesca altri workflow.

Lo stesso controllo si esegue in locale:

```bash
./scripts/check-teamcity-release.sh          # report leggibile, exit 0 anche se serve un rebuild
./scripts/check-teamcity-release.sh --json   # output per pipeline
```

Configurazione opzionale: secret `RELEASE_PAT` (rilascio automatico), secret `SLACK_WEBHOOK_URL`
(recap su Slack), variable `TC_WATCH_AUTO_RELEASE`.
