# CLAUDE.md — teamcity-agent-gitlab-release-cli

Repo che costruisce le **immagini Docker degli agent TeamCity di HiWay Media**
(`github.com/HiWay-Media/teamcity-agent-gitlab-release-cli`): due Dockerfile che partono dalle base
image `ghcr.io/hiway-media/teamcity-agent-{latest,2023.11.3}` e ci aggiungono toolchain Go, Android
SDK command-line tools, `gitlab-cli` e utility di pipeline. Le immagini finite escono su GHCR come
`ghcr.io/hiway-media/teamcity-agent-gitlab-release-cli-{latest,2023.11.3}`.

Qui **non c'è un'applicazione**: il prodotto è l'immagine. Ogni modifica è un cambio di runtime per
tutte le pipeline TeamCity che la usano.

Regole operative per Claude Code in questo repository. `AGENTS.md` è lo stesso contenuto per gli altri
tool AI (Copilot & co.): **se modifichi uno, allinea l'altro nello stesso commit**.

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

Il canale `latest` insegue **il digest della base image**, non l'annuncio JetBrains. Motivo:
`Dockerfile.latest` fa `FROM ghcr.io/hiway-media/teamcity-agent-latest` senza pin, e quella base vive
in `HiWay-Media/teamcity-agent`. Finché non viene ricostruita là, una release qui pubblicherebbe byte
identici con un numero nuovo.

```
 JetBrains data services ──┐
 (release TeamCity)        │
                           ├──▶ scripts/check-teamcity-release.sh ──▶ action=
 GHCR base image           │      (confronto contro shipped.digest,
 (digest + label + build) ──┘       exit 0 anche su WARN)
                                        │
      ┌─────────────────────────────────┼──────────────────────────────────┐
      ▼                                 ▼                                  ▼
  release                            notify                               none
  base ricostruita                   TeamCity avanti, base ferma          niente di nuovo
      │                                 │                                  │
  bump minor se TeamCity cambia,    nessun tag (byte identici):        summary e stop
  patch se no                       issue verso il repo della base
      │                             + recap Slack
  commit + tag + GitHub Release      + nudge repository_dispatch
  + dispatch docker-publish-*          (se BASE_REPO_PAT)
```

Stato in `teamcity-version.json` (schema 2), **da non modificare a mano**:

| Campo | Cos'è |
|---|---|
| `teamcity` | ultima release vista su JetBrains (osservazione) |
| `base_image` | ultimo digest/versione/data osservati della base (osservazione) |
| `shipped` | cosa abbiamo **davvero** pubblicato: è l'ancora del confronto |
| `pending` | TeamCity avanti + base ferma; `since` = data della release TeamCity |
| `policy.stale_after_days` | dopo quanti giorni di `pending` si apre la issue (default 7) |

Il confronto è `base_image.digest != shipped.digest`, non contro l'osservazione precedente: così i run
di sola segnalazione non consumano il segnale di release.

Contratto del check: `--json`, `--write`, `--mark-shipped TAG`, `--github-output`, `--state FILE`.
**Exit 0 anche con `action=release`/`notify`** (sono WARN), exit 1 solo per errore sistemico.

**Stato della catena al 2026-09-02**: base image `v1.9.0` del **2025-09-18** (349 giorni), TeamCity a
**2026.1.3** (uscita 37 giorni fa) → `action=notify`. Il canale `latest` gira su un agent di settembre
2025: sbloccarlo richiede un rebuild in `HiWay-Media/teamcity-agent`, non un tag qui.

## Trappole note / regole tecniche

- **Un tag pushato con `GITHUB_TOKEN` non innesca `on: push`.** Ma `workflow_dispatch` e
  `repository_dispatch` sono le due eccezioni alla regola: percio' il watcher crea il tag col
  `GITHUB_TOKEN` e poi lancia i publish con `gh workflow run --ref <tag>`. Niente PAT. **Il ref del
  dispatch DEVE essere il tag**: lo step `Prepare` dei publish calcola `VERSION` da `GITHUB_REF`, e su
  un ref di branch pubblicherebbe `latest` al posto di `vX.Y.Z`.
- **`printf` con format che inizia per `-`** lo interpreta come opzione e il job muore
  (`printf: - : invalid option`): serve `printf -- '- ...'`. Le righe di bullet di CHANGELOG, release
  notes e issue body sono tutte in questa condizione.
- **In `jq`, un campo che valuta a stream vuoto annulla l'intero oggetto**: `{a: ("" | tonumber?)}`
  non produce `null`, non produce *niente* — `jq -n` esce 0 con output vuoto e il chiamante si ritrova
  con JSON invalido. Serve `(("" | tonumber?) // null)`.
- **`--mark-shipped` va per ultimo** nello step di prep: marcare lo stato prima dei passi che possono
  fallire lasciava `shipped` aggiornato senza tag né release, e il run dopo diceva "allineato".
- **Il `env` context in un `if:` di step non vede l'env dello step stesso**: per condizionare uno step
  alla presenza di un secret, quel secret va nell'`env` del job.
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

## Nota per Claude Code

- La documentazione lunga (Dockerfile riga per riga, workflow, esempi d'uso in pipeline) sta in
  `docs/overview.md` — era questo file prima dell'adozione della convenzione `devops_hiway`. Leggila
  quando serve il dettaglio, non tenerla in contesto per default.
- Prima di proporre un bump di versione degli strumenti: `./scripts/check-teamcity-release.sh` per
  sapere se il canale `latest` è già disallineato, e `git log --oneline -- Dockerfile.latest` per vedere
  la cadenza reale dei bump.
- Le build Docker qui sono lunghe (Android SDK). Se lanci una build locale, mandala in background e
  riprendi il log, non bloccare la sessione.
