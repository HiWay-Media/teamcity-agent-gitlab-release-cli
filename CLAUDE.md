# TeamCity Agent GitLab Release CLI - Documentazione dettagliata

## Introduzione

Questo repository non contiene un'applicazione tradizionale, ma fornisce l'infrastruttura e l'ambiente Docker per eseguire pipeline TeamCity integrate con GitLab e Android. Lo scopo principale è creare immagini agent TeamCity pronte all'uso che includono:

- strumenti per interagire con GitLab (`gitlab-cli`),
- un ambiente Go già configurato,
- Android SDK command-line tools,
- utilities aggiuntive utili per pipeline CI/CD.

Il progetto è organizzato attorno a due Dockerfile e a workflow GitHub Actions che costruiscono e pubblicano immagini container.

## Obiettivo del progetto

L'obiettivo è semplificare la configurazione di un agent TeamCity per progetti che necessitano di:

- creazione automatica di release GitLab,
- gestione di tag e pubblicazioni GitLab all'interno della pipeline,
- compilazione o test di applicazioni Android,
- compilazione e test di codice Go.

In un ambiente TeamCity, l'immagine Docker rappresenta il runtime dell'agente: un container che include tutti gli strumenti richiesti dalla pipeline.

## Struttura del repository

Il repository contiene i seguenti elementi principali:

- `README.md`: descrizione sintetica del progetto.
- `claude.md`: documentazione dettagliata (questo file).
- `Dockerfile.latest`: definisce l'immagine basata sull'agente TeamCity "latest".
- `Dockerfile.2023.11.3`: definisce l'immagine basata sull'agente TeamCity 2023.11.3.
- `.github/workflows/docker-publish-latest.yml`: workflow per build e push dell'immagine `-latest`.
- `.github/workflows/docker-publish-2023.11.3.yml`: workflow per build e push dell'immagine `-2023.11.3`.
- `android-accept-licenses.sh`: script di supporto per accettare le licenze Android, utile in scenari locali o custom.

## Dettaglio dei Dockerfile

I due Dockerfile sono molto simili e differiscono principalmente nella base image utilizzata.

### Base image

- `Dockerfile.latest` parte da `ghcr.io/hiway-media/teamcity-agent-latest`.
- `Dockerfile.2023.11.3` parte da `ghcr.io/hiway-media/teamcity-agent-2023.11.3`.

Questo significa che l'immagine eredità già l'ambiente TeamCity agent appropriato, mentre il repository aggiunge strumenti e configurazioni specifiche.

### Utente e permessi

Entrambi i Dockerfile eseguono le installazioni come utente `root`:

- `USER root`

Questo è necessario per eseguire `apt-get install`, creare directory sotto `/root`, modificare variabili d'ambiente e installare strumenti globali.

### Pacchetti installati

Il comando `apt-get -y install` installa:

- `gitlab-cli`: client per interagire con GitLab da linea di comando.
- `unzip`, `wget`, `curl`: strumenti di download e gestione di archivi.
- `rsync`: sincronizzazione file efficiente.
- `sudo`: esecuzione di comandi con privilegi elevati.
- `rclone`: sincronizzazione con storage cloud.
- `build-essential`: compilatori e strumenti di build base.
- `golang`: runtime Go e toolchain.

Questi strumenti sono utili per pipeline che devono eseguire build, scaricare artefatti, gestire release e interagire con servizi esterni.

### Strumenti Go aggiuntivi

Dopo l'installazione di Go, i Dockerfile installano:

- `go install go.uber.org/mock/mockgen@latest`: generator di mock per test Go.
- `golangci-lint`: uno strumento comune di linting per Go. Viene installato scaricando lo script ufficiale dal repository GitHub.

Questi strumenti sono utili nei workflow di sviluppo Go ma possono anche essere usati in pipeline di test statici o generazione automatica di mock.

### Android SDK command-line tools

I Dockerfile scaricano e installano gli Android SDK command-line tools:

- `wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip`
- `unzip commandlinetools.zip -d ~/Android/Sdk/cmdline-tools`
- `mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest`

Successivamente impostano le variabili d'ambiente:

- `ANDROID_SDK_ROOT=/root/Android/Sdk`
- `PATH` include il binario `cmdline-tools/latest/bin` e `platform-tools`.

### Android license acceptance e componenti

I Dockerfile eseguono:

- `yes | /root/Android/Sdk/cmdline-tools/latest/bin/sdkmanager --licenses`

Questo accetta automaticamente tutte le licenze Android richieste.

I componenti installati sono:

- `platform-tools`
- `platforms;android-35`
- `build-tools;35.0.0`

Questi componenti permettono di eseguire comandi Android comuni come `adb`, compilare progetti Android e utilizzare strumenti di build moderni.

### Configurazione del PATH e del GOPATH

Nel Dockerfile è impostato il percorso Go e il PATH utente:

- `ActualGoPath=$(go env GOPATH) && echo "GOPATH è $ActualGoPath"`
- `ENV PATH=$PATH:$ActualGoPath/bin`

Questo garantisce che gli eseguibili installati tramite `go install` siano disponibili nel PATH.

### Note sul Dockerfile

- Vengono eseguite verifiche informative come `echo $PATH`, `cat ~/.bashrc` e `ls -l` per diagnostica dell'immagine.
- La presenza di `RUN . /root/.bashrc` indica l'intenzione di caricare la configurazione shell dell'utente root all'interno del build, ma in Dockerfile questo source è eseguito solo nel contesto di quell'istruzione.

## Dettaglio dei workflow GitHub Actions

Il repository include due workflow che pubblicano immagini Docker su GitHub Container Registry.

### Trigger e strategia di tagging

Entrambi i workflow si attivano su push di tag:

```yaml
on:
  push:
    tags:
      - '*'
```

Il passo di preparazione (`Prepare`) calcola:

- `DOCKER_IMAGE`: nome dell'immagine GHCR basato sul repository.
- `VERSION`: un tag dinamico basato su ref GitHub:
  - `nightly` per cron job,
  - il tag git stesso per `refs/tags/*`,
  - `latest` per il branch di default,
  - `pr-<numero>` per pull request,
  - nome branch per altri branch.

Se `VERSION` corrisponde al pattern semantico `vX.Y.Z`, il workflow aggiunge tag supplementari:

- `vX.Y.Z`
- `vX.Y`
- `vX`
- `latest`

Questo consente versioni parallele e alias utili per fallback e test.

### Build e push Docker

I workflow usano `docker/build-push-action@v4` con le seguenti impostazioni:

- `context: .`
- `file`: il Dockerfile appropriato (`Dockerfile.latest` o `Dockerfile.2023.11.3`)
- `platforms`: `linux/amd64` per `latest`, `linux/amd64,linux/arm64` per `2023.11.3`.
- `push: true`
- `tags`: le immagini calcolate nel passo `Prepare`.

Inoltre impostano le etichette OCI standard con metadata repository.

### Differenze tra i workflow

- `docker-publish-latest.yml`: pubblica l'immagine `-latest` usando la base `teamcity-agent-latest`.
- `docker-publish-2023.11.3.yml`: pubblica l'immagine `-2023.11.3` usando la base `teamcity-agent-2023.11.3` e abilitando architetture `amd64` e `arm64`.

## Come usare le immagini Docker

### Costruzione locale

Per costruire l'immagine `latest`:

```powershell
cd C:\Users\allan\projects\teamcity-agent-gitlab-release-cli

docker build -f Dockerfile.latest -t teamcity-agent-gitlab-release-cli:latest .
```

Per costruire la versione basata su TeamCity 2023.11.3:

```powershell
docker build -f Dockerfile.2023.11.3 -t teamcity-agent-gitlab-release-cli:2023.11.3 .
```

### Test dell'immagine

Esegui il container in interattivo per verificare strumenti e variabili d'ambiente:

```powershell
docker run --rm -it teamcity-agent-gitlab-release-cli:latest bash
```

All'interno del container puoi verificare:

- `gitlab --version`
- `go version`
- `mockgen --version`
- `golangci-lint --version`
- `sdkmanager --list`
- `adb version`

### Uso in pipeline TeamCity

Queste immagini sono pensate per essere usate come agent TeamCity container-based. In una configurazione TeamCity, si può utilizzare l'immagine Docker come base per il worker che esegue i job.

Un esempio di step TeamCity potrebbe includere:

- esecuzione di script shell per installare dipendenze e build,
- utilizzo di `gitlab-cli` per creare tag e release GitLab,
- esecuzione di build Android via Gradle,
- esecuzione di test Go e linting.

## Componenti e strumenti principali

### GitLab CLI

L'immagine include `gitlab-cli`, che fornisce comandi per interagire con repository GitLab. Questo strumento può essere usato per:

- creare release,
- gestire tag,
- interrogare progetti e pipeline.

### Android SDK e Android command-line tools

L'ambiente è preparato per utilizzare gli strumenti di sviluppo Android:

- `sdkmanager` per gestire componenti SDK,
- `adb` dalle platform-tools,
- build tools per compilare APK/AAB.

### Go e strumenti Go

L'immagine include la toolchain Go e strumenti utili per lo sviluppo Go:

- `mockgen` per generare mock nei test,
- `golangci-lint` per analisi statica.

### Utility generiche per pipeline

Strumenti come `wget`, `curl`, `unzip`, `rsync`, `rclone` e `sudo` sono utili nei flussi di integrazione continua per:

- recuperare artefatti,
- decomprimere file,
- sincronizzare cartelle,
- eseguire comandi con privilegi,
- interagire con storage esterni.

## Esempi di utilizzo

### Creare una release GitLab da TeamCity

Un esempio di comando che un job TeamCity potrebbe eseguire dentro il container è:

```bash
export GITLAB_TOKEN="..."

gitlab release create --tag-name "$TAG" --name "Release $TAG" --description "Release generata da TeamCity"
```

Nota: la sintassi dipende dal client `gitlab-cli` installato e dalla configurazione del progetto.

### Compilare un progetto Android

Dentro il container, un job potrebbe eseguire:

```bash
cd /path/to/android/project
./gradlew assembleRelease
```

Oppure utilizzare direttamente gli strumenti SDK per validazioni e test.

### Analisi e test Go

Un job Go potrebbe eseguire:

```bash
go test ./...
golangci-lint run
```

## Suggerimenti per l'estensione

### Aggiungere uno script di rilascio

Il repository può essere esteso con uno script shell o Go che:

- legge le variabili di ambiente TeamCity,
- crea tag Git,
- invia release su GitLab,
- allega asset di build.

### Personalizzare versioni Android/Go

Per aggiornare l'ambiente, modifica i percorsi e le versioni nel Dockerfile:

- `commandlinetools-linux-11076708_latest.zip`
- `platforms;android-35`
- `build-tools;35.0.0`

Aggiorna anche il pacchetto `golang` installato tramite apt se necessario.

### Migliorare i workflow CI/CD

Potresti aggiungere:

- trigger su `push` su branch oltre ai tag,
- build multi-arch per `latest`,
- verifica di immagini con `docker build --target` o test di integrazione,
- caching di layer Docker per velocizzare la pipeline.

## Note finali

Attualmente il repository fornisce l'ambiente container e i workflow per pubblicare immagini, ma non include un'applicazione di rilascio GitLab completamente sviluppata. Il valore principale sta nella base Docker dell'agente TeamCity con strumenti preinstallati.

Per usare al meglio questo progetto:

- definisci i job TeamCity che eseguono la logica di rilascio,
- usa le immagini Docker come runtime per i job,
- mantieni aggiornate le versioni degli SDK e degli strumenti installati.

---

Questa documentazione è pensata per spiegare in dettaglio la struttura del repository, il contenuto dei Dockerfile, il funzionamento dei workflow GitHub Actions e gli scenari di utilizzo principali.