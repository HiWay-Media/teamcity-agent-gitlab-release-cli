# Changelog

Tutte le modifiche rilevanti a questo repository.
Formato [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioning [SemVer](https://semver.org/lang/it/).

Convenzione: **ogni commit e una release taggata `vX.Y.Z`**. Il tag pushato fa partire
`docker-publish-latest` e `docker-publish-2023.11.3`, che pubblicano le immagini su GHCR con i tag
`vX.Y.Z`, `vX.Y`, `vX` e `latest`.

## [1.7.1] - 2026-09-10

### Changed

- Allineamento immagine agent `latest`: nuova release TeamCity 2026.1.3 -> 2026.2; baseline digest base image mancante: primo allineamento.
- TeamCity tracciato: `2026.1.3` -> `2026.2` ([release notes](https://www.jetbrains.com/help/teamcity/2026.2/teamcity-2026-2-release-notes.html)).
- Base image `ghcr.io/hiway-media/teamcity-agent-latest:latest` digest `sha256:c14190b826c06bca78b4a4b8288fae7f54245aaa099a553362322597e8231a9d`.
- Aggiornato da `.github/workflows/teamcity-version-watch.yml`.

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
