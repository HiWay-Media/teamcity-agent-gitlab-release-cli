# AGENTS.md — teamcity-agent-gitlab-release-cli

Repo che costruisce le **immagini Docker degli agent TeamCity di HiWay Media**
(`github.com/HiWay-Media/teamcity-agent-gitlab-release-cli`): due Dockerfile che partono dalle base
image `ghcr.io/hiway-media/teamcity-agent-{latest,2023.11.3}` e ci aggiungono toolchain Go, Android
SDK command-line tools, `gitlab-cli` e utility di pipeline. Le immagini finite escono su GHCR come
`ghcr.io/hiway-media/teamcity-agent-gitlab-release-cli-{latest,2023.11.3}`.

Qui **non c'è un'applicazione**: il prodotto è l'immagine. Ogni modifica è un cambio di runtime per
tutte le pipeline TeamCity che la usano.

Questo file definisce le regole operative per gli agent (Claude, Copilot, altri tool AI) che lavorano
in questo repository. `CLAUDE.md` ne è la copia per Claude Code: **tenerli allineati**.

## Regole di lavoro (SEMPRE)

- **Ogni commit = release taggata `vX.Y.Z`**: nuova sezione in `CHANGELOG.md` (Keep a Changelog, in
  italiano) + `git tag -a vX.Y.Z -m "Release X.Y.Z"`. Bump `minor` per novità sostanziali (nuovo
  strumento nell'immagine, nuovo Dockerfile/canale, nuovo workflow), `patch` per bump di versione e
  fix. Senza chiederlo. **Esenti**: i commit della PR automatica `chore/teamcity-watch` (il CHANGELOG
  se lo scrive già da sola) e i commit di sola documentazione interna al repo.
- **MAI `git push`**: lo fa sempre l'utente. MAI `Co-Authored-By` nei commit.
- **Il tag è il deploy.** `git push origin vX.Y.Z` fa partire `docker-publish-latest` e
  `docker-publish-2023.11.3` e sovrascrive il tag `latest` su GHCR — cioè il runtime che gli agent
  TeamCity scaricano al prossimo pull. Non taggare "per provare": per provare c'è la build locale.
- **Modifica un Dockerfile → modifica l'altro**, salvo motivo esplicito. I due canali devono divergere
  solo sulla base image e sulle piattaforme; ogni divergenza in più va scritta nel CHANGELOG.
- **Build locale prima di taggare**, sempre, almeno sul canale toccato:
  `docker build -f Dockerfile.latest -t tc-agent:test .` e poi la verifica degli strumenti (sotto).
- **Pin delle versioni**: gli strumenti installati vanno pinnati (`golangci-lint v2.4.0`,
  `build-tools;35.0.0`, `commandlinetools-linux-<build>`), non presi a `latest`. Una build non
  riproducibile rompe le pipeline senza che nessuno abbia cambiato niente.
- **Niente segreti nell'immagine**: no token GitLab, no chiavi, no `.netrc`. I token li inietta
  TeamCity come parametri di build/run.
- **Documentare il perché** di ogni bump: la riga di CHANGELOG dice *cosa serviva*, non solo *cosa è
  cambiato* ("bump build-tools per compileSdk 35 di <progetto>").

## Verifica dell'immagine (dopo ogni build, prima del tag)

```bash
docker run --rm -it tc-agent:test bash -lc '
  go version && mockgen --version && golangci-lint --version &&
  gitlab --version; adb version && sdkmanager --list_installed'
```

Tutti gli strumenti devono rispondere **senza `PATH` aggiuntivi**: se uno serve un `export`, il
Dockerfile è sbagliato, non la verifica.

## Aggiornamento automatico dell'immagine `latest`

Il canale `latest` insegue due cose, non una:

1. le **release TeamCity** pubblicate da JetBrains (`data.services.jetbrains.com`);
2. il **digest della base image** `ghcr.io/hiway-media/teamcity-agent-latest:latest`, che cambia quando
   viene ricostruita nel suo repo — ed è quello che cambia davvero il contenuto della nostra immagine.

Entrambi sono sorvegliati da `scripts/check-teamcity-release.sh` e dal workflow schedulato
`.github/workflows/teamcity-version-watch.yml` (giornaliero, 05:17 UTC). Lo stato tracciato sta in
`teamcity-version.json`: **non modificarlo a mano**, lo aggiorna il check con `--write`.

```
 JetBrains data services ─┐
                          ├─▶ check-teamcity-release.sh ─▶ has_update? ─┬─ no  ─▶ exit 0, niente
 GHCR base image digest ──┘        (exit 0 anche su WARN)               │
                                                                        └─ sì ─▶ PR chore/teamcity-watch
                                                                                  (o, mode=release,
                                                                                   commit + tag vX.Y.Z
                                                                                   ─▶ docker-publish-*)
```

Contratto del check: `--json`, `--write`, `--github-output`, `--state <file>`;
**exit 0 anche quando c'è un aggiornamento** (è un WARN), exit 1 solo per errore sistemico del check.

## Trappole note / regole tecniche

- **Un tag pushato con `GITHUB_TOKEN` non innesca altri workflow.** Per il rilascio automatico serve il
  secret `RELEASE_PAT`; senza, il watcher ripiega sulla PR e lo dichiara nel job summary. Non "sistemare"
  il fallback rimuovendolo.
- **`docker-publish-*.yml` usano `::set-output` e `actions/github-script@v4`**, entrambi deprecati.
  Funzionano ancora ma sono debito: se una build fallisce con un errore di sintassi degli output, è
  quello. Migrarli è un lavoro a sé, non da infilare in un bump di versione.
- **`awk -v` non regge valori multi-riga** (BSD awk li rifiuta): per inserire una sezione nel CHANGELOG
  si fa splice con `head`/`tail` sulla prima riga `^## `. Già inciampato una volta.
- **`ARG ActualGoPath` non fa quello che sembra** (bug latente in entrambi i Dockerfile):
  `RUN ActualGoPath=$(go env GOPATH)` vive solo dentro quella `RUN`, quindi la `ENV PATH=$PATH:$ActualGoPath/bin`
  successiva espande la **ARG vuota** e appende `:/bin`. Conseguenza: `mockgen` potrebbe essere
  raggiungibile solo col path completo (`/root/go/bin/mockgen`). **Verificarlo con il comando di verifica
  qui sopra** prima di dare per scontato il contrario; il fix è `ENV GOPATH=/root/go` +
  `ENV PATH=$PATH:/root/go/bin` espliciti.
- **`RUN . /root/.bashrc` è un no-op** ai fini dell'immagine: la shell muore con la `RUN`. Le variabili
  vanno in `ENV`.
- **`platforms` diverse tra i due canali**: `latest` è solo `linux/amd64`, `2023.11.3` è
  `linux/amd64,linux/arm64`. La build arm64 dell'Android SDK è lenta: non aggiungere arm64 a `latest`
  senza misurare i tempi di build.
- **`yes | sdkmanager --licenses` va tenuto**: senza, la build si pianta in attesa di input.
  `android-accept-licenses.sh` (expect) è l'alternativa per gli scenari locali, non è usato nei Dockerfile.
- **Le versioni Android SDK sono un contratto con i progetti a valle**: alzare `platforms;android-XX` o
  `build-tools;XX.Y.Z` senza avvisare rompe le build Gradle dei client. Prima si verifica chi usa l'immagine.
- **Probe di rete negli script**: `curl --max-time 20 --retry 2` — timeout aggressivi dagli agent
  TeamCity danno falsi positivi.

## Puntatori

- **Intento del repo** (obiettivi, non-obiettivi, principi, confini): `INTENT.md` — leggilo prima di
  aggiungere strumenti, canali o automazioni nuove.
- **Cosa c'è dentro** (Dockerfile, workflow, uso in pipeline): `README.md` e `docs/overview.md`.
- **Storia**: `CHANGELOG.md` + i tag `v0.1.0` → oggi.
- **Base image**: repo `HiWay-Media/teamcity-agent` → `ghcr.io/hiway-media/teamcity-agent-{latest,2023.11.3}`.
- **Chi consuma queste immagini**: `teamcity-ci-cd-hiway` (job spec e pipeline),
  TeamCity su `teamcity.hiwaymedia.dev`.
- **Repo affini**: `devops_hiway` (infrastruttura e monitoring, convenzioni di cui questo file è
  l'adattamento), `teamcity_backup`, `cnf-mng-hiway`.
