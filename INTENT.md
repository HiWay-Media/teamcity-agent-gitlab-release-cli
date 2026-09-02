# INTENT.md — teamcity-agent-gitlab-release-cli

**Perché questo repository esiste**, cosa si impegna a fare e cosa *deliberatamente* non fa.
È il documento di intento: sopravvive ai singoli task e va letto prima di aggiungere qualcosa qui dentro.

| File | Domanda a cui risponde |
|---|---|
| **`INTENT.md`** (questo) | **Perché** esiste il repo, quali obiettivi serve, cosa è fuori scope |
| [`README.md`](README.md) | **Cosa** c'è dentro (sintesi) |
| [`docs/overview.md`](docs/overview.md) | **Cosa** c'è dentro, nel dettaglio (Dockerfile, workflow, uso) |
| [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) | **Come** si lavora qui (regole per persone e agent AI) |
| [`CHANGELOG.md`](CHANGELOG.md) | **Cosa è cambiato** (ogni commit = release taggata) |
| [`teamcity-version.json`](teamcity-version.json) | **A che punto siamo** rispetto alle uscite TeamCity |

---

## 1. In una riga

Dare alle pipeline TeamCity di HiWay Media **un runtime unico, riproducibile e aggiornato**: un'immagine
Docker di agent che contiene già Go, Android SDK, `gitlab-cli` e le utility di CI, così che nessuna
pipeline debba installarsi le proprie dipendenze a ogni build.

## 2. Il problema che risolve

Prima, ogni build configurata su TeamCity si arrangiava: `apt-get install` nello step di build, SDK
Android scaricati al volo, versioni di `golangci-lint` diverse tra un progetto e l'altro. Le
conseguenze concrete:

- **build lente**: minuti spesi a reinstallare gli stessi strumenti a ogni run;
- **build non riproducibili**: `latest` di uno strumento cambia sotto i piedi e una pipeline che
  funzionava ieri fallisce oggi, senza che nessuno abbia toccato il codice;
- **licenze Android da accettare a mano**, con build che si piantano in attesa di input;
- **deriva tra progetti**: due repo Go con due versioni diverse di linter danno due verdetti diversi
  sullo stesso codice.

L'immagine sposta tutto questo **a monte, una volta sola**, in un artefatto versionato di cui si può
dire esattamente cosa contiene.

## 3. Obiettivi (in ordine di priorità)

1. **Un runtime pronto** — l'agent TeamCity parte con Go, Android SDK (`platform-tools`,
   `platforms;android-35`, `build-tools;35.0.0`), `gitlab-cli`, `mockgen`, `golangci-lint`, `rclone`,
   `rsync` già dentro e già nel `PATH`.
2. **Riproducibilità** — versioni pinnate, non `latest`. La stessa immagine ricostruita deve dare la
   stessa build.
3. **Due canali paralleli** — `latest` (TeamCity corrente) e `2023.11.3` (LTS interno), così un upgrade
   del server non obbliga a migrare tutte le pipeline nello stesso giorno.
4. **Restare al passo con TeamCity senza presidiarlo a mano** — un watcher schedulato sorveglia le
   release JetBrains e il digest della base image, e apre la PR di allineamento da solo.
5. **Tracciabilità** — ogni immagine su GHCR corrisponde a un tag git e a una riga di CHANGELOG che
   dice *perché* è cambiata.

## 4. Non-obiettivi (espliciti)

Ciò che segue **non** è un buco da colmare: è una scelta.

- **Non è un CLI.** Malgrado il nome, qui non c'è nessun binario "gitlab-release": il rilascio su
  GitLab lo fa `gitlab-cli` (pacchetto di terze parti) invocato dagli step TeamCity. Il prodotto di
  questo repo è **l'immagine**.
- **Non è il repo delle pipeline.** Configurazioni TeamCity, job spec e logica di release stanno in
  `teamcity-ci-cd-hiway`. Qui c'è il *contenitore* dentro cui girano.
- **Non costruisce la base image.** `ghcr.io/hiway-media/teamcity-agent-{latest,2023.11.3}` vengono da
  un altro repo. Qui la si consuma e se ne sorveglia il digest.
- **Non è un'immagine general-purpose.** Non si aggiungono strumenti "che potrebbero servire": ogni
  pacchetto in più è peso su ogni pull di ogni agent. Si aggiunge quando una pipeline reale lo chiede.
- **Non custodisce segreti.** Nessun token GitLab, chiave o credenziale nell'immagine: li inietta
  TeamCity a runtime.
- **Non gestisce il ciclo di vita degli agent.** Scale, registrazione, autorizzazione sul server sono
  di TeamCity, non dell'immagine.
- **Non fa multi-arch ovunque.** `latest` resta `linux/amd64` finché non c'è una domanda reale di arm64
  che giustifichi i tempi di build dell'Android SDK.

## 5. Principi (gli invarianti, con il perché)

| Principio | Perché |
|---|---|
| **Il tag è il deploy** | `git push origin vX.Y.Z` riscrive `latest` su GHCR: al pull successivo tutte le pipeline cambiano runtime. Un tag non è mai "una prova". |
| **Versioni pinnate, mai `latest`** | Una build che cambia senza che nessuno abbia committato è il modo più costoso di perdere tempo: fallisce lontano dalla causa. |
| **Ogni commit è una release taggata** | Il CHANGELOG diventa la storia datata del runtime: "da quando l'immagine ha `build-tools;35`?" ha una risposta in `git log`. |
| **I due canali divergono solo dove serve** | Se `latest` e `2023.11.3` derivano, il canale LTS smette di essere un fallback credibile e diventa un secondo runtime da mantenere. |
| **Verificare l'immagine, non il Dockerfile** | Un `RUN` che passa non garantisce che lo strumento sia nel `PATH`. Si controlla eseguendo i comandi nel container finito. |
| **Un WARN non fa fallire il check** | `check-teamcity-release.sh` esce `0` anche quando c'è un aggiornamento: exit `≠0` solo per errore sistemico. Un check che "fallisce" a ogni novità si impara a ignorare. |
| **L'automazione propone, la persona dispone** | Il watcher apre una PR; il rilascio automatico è opt-in esplicito. Un runtime che si aggiorna da solo di notte è un incidente che aspetta. |
| **Le versioni SDK sono un contratto** | Alzare `compileSdk`/`build-tools` rompe le build Gradle a valle: prima si verifica chi usa l'immagine. |

## 6. Confini — cosa vive dove

```
   JetBrains                    HiWay-Media/teamcity-agent
   (release TeamCity)           (base image)
        │                              │
        │  data.services               │  ghcr.io/hiway-media/teamcity-agent-{latest,2023.11.3}
        │                              ▼
        │        ┌──────────────────────────────────────────────────┐
        └───────▶│   teamcity-agent-gitlab-release-cli (questo repo) │
                 │                                                  │
                 │  Dockerfile.latest        Go · Android SDK ·      │
                 │  Dockerfile.2023.11.3     gitlab-cli · rclone     │
                 │                                                  │
                 │  scripts/check-teamcity-release.sh   ◀─ watcher   │
                 │  .github/workflows/  publish · version-watch      │
                 └───────────────────────┬──────────────────────────┘
                                         │ push tag vX.Y.Z
                                         ▼
                 ghcr.io/hiway-media/teamcity-agent-gitlab-release-cli-{latest,2023.11.3}
                                         │
                                         ▼
        ┌────────────────────────────────┴───────────────────────────┐
        ▼                                                            ▼
  teamcity.hiwaymedia.dev                                   teamcity-ci-cd-hiway
  (agent che girano l'immagine)                             (pipeline, job spec, release GitLab)
```

Regola pratica: *"cosa c'è dentro l'agent"* → qui. *"cosa fa la pipeline"* → `teamcity-ci-cd-hiway`.
*"come sta l'infrastruttura"* → `devops_hiway`.

## 7. Come si decide cosa entra

Prima di aggiungere qualcosa, in quest'ordine:

1. **Serve a una pipeline reale?** Se la risposta è "potrebbe servire", non entra: ogni pacchetto è
   peso su ogni pull.
2. **Va nell'immagine o nello step?** Se lo usa un solo progetto ed è leggero, lo installa il suo step.
   Nell'immagine ci va ciò che è **comune e costoso da installare** (SDK, toolchain).
3. **È pinnabile?** Se lo strumento non ha una versione stabile da fissare, si aspetta o si accetta
   scrivendo esplicitamente perché nel CHANGELOG.
4. **Rompe qualcuno a valle?** Cambi di `platforms;android-XX`, `build-tools`, versione Go o del linter
   si verificano con chi usa l'immagine **prima** del tag.
5. **Vale su entrambi i canali?** Se sì, si tocca l'altro Dockerfile nello stesso commit. Se no, la
   divergenza va scritta.

## 8. Come si vede che sta funzionando

- **Nessuna pipeline installa dipendenze a runtime**: gli step di build sono `go test` / `gradlew`, non
  `apt-get`.
- **Il canale `latest` non resta indietro**: `teamcity-version.json` allineato alle uscite JetBrains,
  senza che nessuno se ne sia occupato a mano.
- **Le build non falliscono "da sole"**: nessun incidente causato da una versione di strumento cambiata
  sotto i piedi.
- **Il CHANGELOG spiega i bump**: ogni riga dice quale esigenza reale ha mosso la versione.
- **Il canale LTS resta usabile**: `2023.11.3` continua a costruire e a essere pubblicato, non è
  diventato un ramo morto.

## 9. Chi legge questo repo

Team DevOps HiWay Media (`dev-ops@hiway.media`) e chi debugga una pipeline TeamCity che si comporta
diversamente da come dovrebbe — e gli **agent AI** che lavorano qui, per cui l'intento scritto è
l'unico modo di distinguere "non c'è" da "non lo facciamo apposta".

## 10. Manutenzione di questo file

`INTENT.md` cambia raramente: si aggiorna quando cambia lo **scopo**, non quando cambiano i fatti.
Aggiornalo se: nasce o muore un canale, un non-obiettivo smette di essere tale (es. si decide di
scrivere davvero un CLI di release, o di fare multi-arch su `latest`), cambia un confine tra repo, o un
principio viene rivisto. Lo stato vivo resta `CHANGELOG.md` e `teamcity-version.json`; questo testo è
datato **2026-09-02**.
