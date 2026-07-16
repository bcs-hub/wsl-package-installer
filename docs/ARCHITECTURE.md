# Arhitektuur ja disainiotsused

See dokument fikseerib Vali-IT Installeri arhitektuuri ja otsuste
põhjendused. Kinnitatud 2026-07-15.

## Suur pilt: kaks kihti

```
  ÕPILANE
    │  PowerShell (admin), üks rida:
    │  irm https://raw.githubusercontent.com/bcs-hub/wsl-package-installer/main/setup.ps1 | iex
    ▼
┌─────────────────────────────────────────────┐
│  KIHT 1: setup.ps1  (Windows)               │
│  1. Windowsi rakendused (winget):           │
│     Git, Node, PostgreSQL(+vali_it DB),     │
│     IntelliJ (+pluginad+seaded), Docker,    │
│     Slack, Zoom                             │
│  2. WSL2 + Ubuntu, kasutaja, paroolita sudo │
│  3. Kokkuvõte (✓ / ✗+PDF / käsitsi+PDF):    │
│     ekraanil + HTML-failina töölaual        │
└─────────────────────────────────────────────┘
    │  wsl -d <distro> -- ./install.sh --all
    ▼
┌─────────────────────────────────────────────┐
│  KIHT 2: install.sh + scripts/ + lib/       │
│  (Ubuntu sees) paigaldab → kontrollib       │
└─────────────────────────────────────────────┘
```

Windowsi rakendused paigaldatakse ENNE WSL-i osa: kui WSL vajab
taaskäivitust, on winget-osa selleks hetkeks juba tehtud ja teine jooks
teeb ainult Ubuntu poole.

Kihid on lõdvalt seotud: kiht 2 ei tea kihi 1 olemasolust midagi ja
töötab iseseisvalt (menüü, Docker-konteiner, päris-Ubuntu). See teeb
Linuxi poole testitavaks ilma Windowsita.

## Kesksed otsused

| Otsus | Põhjendus |
|---|---|
| Docker: Desktop paigaldatakse winget'iga, docker.io WSL-i sisse EI paigaldata | WSL-i sisese Dockeri systemd-keerukus jääb ära; Docker Desktopi esmakäivitus ja WSL-integratsiooni sisselülitamine on õpilase käsitsi samm (PDF 019) |
| Installer jookseb tavakasutajana, mitte root'ina | NVM, Node ja Claude Code peavad minema õpilase kodukausta; `sudo` ainult apt-käskudel. `install.sh` keeldub root'ina käivitumast |
| Paroolita sudo (`/etc/sudoers.d/vali-it`) | Null küsimust paigalduse ajal; WSL-is pole Linuxi parool nagunii turvapiir (`wsl -u root` on Windowsi poolelt alati avatud) |
| Windowsi rakendused winget'iga, ainult puuduv | Olemasolevat paigaldust (mis tahes versioonis) ei puututa ega uuendata — uuendamine keset kursust on teadlik käsitsi tegevus, mitte kõrvalmõju |
| PostgreSQL: superuser'i parool `student123`, kursuse DB `vali_it` | Ühesugune seis igal õpilasel; olemasolevat serverit EI puututa (kui parool ei sobi, läheb DB loomine käsitsi-nimekirja koos PDF-iga) |
| IntelliJ seaded külvatakse enne esmakäivitust | Import ongi lihtsalt zip'i lahtipakkimine config-kausta (`dataDirectoryName` product-info.json-ist); olemasolevat konfiguratsiooni ei kirjutata üle; varutee on PDF 011 |
| Kolme nimekirjaga kokkuvõte, PDF-viited configist | Õnnestunud / ebaõnnestunud (+PDF käsitsi varutee) / käsitsi sammud (+PDF). Iga ebaõnnestumine on taastatav ilma õpetajata. Käsitsi-nimekirja lisanduvad ka jooksu ajal avastatud sammud (nt "IntelliJ oli avatud — sulge ja käivita uuesti") |
| Kokkuvõte salvestatakse ka HTML-ina töölauale (`Vali-IT-kokkuvote.html`) ja avatakse brauseris | Konsool kaob akna sulgemisel ja lingid pole igas konsoolis klõpsatavad; HTML on püsiv, klikitav, õpetajale saadetav ning sisaldab andmebaasi ühendusandmeid |
| PDF-lingid kujul `...pdf?raw=true` | GitHub serveerib faili otse allalaadimisena — õpilane ei pea blob-lehelt nuppu otsima |
| IntelliJ tuvastus `idea64.exe` asukoha järgi (Find-IdeaExe) | Toolboxi paigaldusi winget ID järgi ei näe; otsitakse Program Files + LocalAppData + Toolbox, uusim versioon võidab. Pluginaid ei paigaldata, kui IDE parasjagu töötab (headless-paigaldus ebaõnnestuks) — selle asemel käsitsi-samm |
| Vea korral menüü jätkab | Üks ebaõnnestunud samm raporteeritakse eestikeelselt; sammud jooksevad alamprotsessidena (`run_step`) |
| Olemasolevat distrot EI kustutata kunagi | Automaatika ei tohi kellegi andmeid hävitada; katkise distro puhul suuname õpetaja juurde |
| Olemasolev 22.04/24.04 võetakse kasutusele | Sellepärast toetabki installer mõlemat versiooni; mõlema olemasolul küsitakse (24.04 soovitatud), `$env:ITC_DISTRO` valib käsitsi |
| setup.ps1-s pole tipptaseme `param()` plokki | Windows PowerShell 5.1 ei suuda seda `irm \| iex` kaudu parsida (õpilase tee); valikud tulevad keskkonnamuutujatest `ITC_DISTRO` ja `ITC_BRANCH` |
| setup.ps1 on UTF-8 ILMA BOM-ita | PS 5.1 `iex` näitab BOM-i punase veana; HTTP charset-päis tagab õige dekodeerimise niikuinii. Lokaalselt testi PowerShell 7-ga |
| setup.ps1 on jätkatav olekumasin | Iga samm: "kas juba tehtud? → jäta vahele". Taaskäivituse järel sama käsk jätkab; korduvkäivitus on ohutu |
| Kood tõmmatakse Windowsi poolel (tarball) | Värskes distros pole git/curl garanteeritud; `tar` on alati olemas |
| Tehniline väljund logifaili `~/.vali-it/install.log` | Ekraanil ainult puhas eestikeelne progress; vea korral saadab õpilane logifaili õpetajale |
| Eestikeelsed stringid otse koodis | Ainult üks keel on nõutud; kogu väljund käib läbi `ui.sh` abifunktsioonide, nii et hilisem väljatõstmine on lihtne |
| `main` peab alati töötama | Õpilased tõmbavad otse `main`-ist; CI on värav |

## Kiht 2: moodulid ja andmevoog

```
install.sh ── menüü (ui.sh) ──┬─▶ scripts/01-system.sh ──▶ installer.sh ─▶ packages.conf
                              ├─▶ scripts/02-ai-tools.sh ▶ installer.sh ─▶ ai-tools.conf
                              └─▶ scripts/03-verify.sh ──▶ verify.sh ───▶ (mõlemad confid)

              kõigi all: colors.sh + logger.sh + checks.sh + utils.sh
              (laaditakse ühe käsuga: lib/bootstrap.sh)
```

Sõltuvused käivad ainult ühes suunas: skriptid → lib → config.

| Moodul | Vastutus |
|---|---|
| `lib/bootstrap.sh` | laeb kõik moodulid õiges järjekorras, initsialiseerib logi ja veatrapi |
| `lib/colors.sh` | värvid ja sümbolid (✓ ⚠ ✗); väljas, kui väljund pole terminal |
| `lib/logger.sh` | logifail; `run_logged` suunab käsu väljundi logisse |
| `lib/ui.sh` | KOGU kasutajale nähtav väljund (eesti keeles) |
| `lib/checks.sh` | käskude/pakettide olemasolu, Ubuntu versioon, NVM-i laadimine |
| `lib/utils.sh` | veatrapp, sudo-haldus, root-keeld, config-parser |
| `lib/installer.sh` | paigaldusmootor + `install_tool_<id>` funktsioonid |
| `lib/verify.sh` | kontrollimootor; EI paigalda kunagi midagi |

### Config-formaat

`pakett-või-id | kontrollkäsk | eestikeelne kirjeldus`

Paigaldaja ja verify loevad **sama** faili — uus rida configis annab
automaatselt nii paigalduse kui kontrolli. Eriloogikaga tööriistade
(ai-tools.conf) konventsioon: id `x` → funktsioon `install_tool_x`
failis `lib/installer.sh`.

Windowsi kihi configid (setup.ps1 pakib tarball'i lahti ka Windowsi
poolel, et neid lugeda):

| Fail | Formaat | Kasutus |
|---|---|---|
| `config/windows-apps.conf` | `winget-id \| kontrollkäsk \| kirjeldus \| PDF` | winget-mootor; olemas = winget tunneb ID VÕI kontrollkäsk on PATH-is (katab käsitsi paigaldatud versioonid); PDF on käsitsi varutee kokkuvõttes |
| `config/intellij-plugins.conf` | `plugin-id \| nimi \| PDF` | headless `idea64.exe installPlugins` |
| `config/manual-steps.conf` | `tekst \| PDF` | kokkuvõtte "Tee ise läbi" nimekiri |

### Veakäsitlus

Kõikjal `set -Eeuo pipefail`. `ERR`-trapp (`utils.sh`) asendab Bashi
jälje eestikeelse teatega + viitega logifailile. `install.sh` jooksutab
samme alamprotsessidena, nii et sammu surm ei tapa menüüd.

### NVM-i eripära

NVM on shelli funktsioon, mis laaditakse `~/.bashrc`-st — skriptid seda
ei jooksuta. `checks.sh::load_nvm` source'ib `nvm.sh` ise (strict mode
ajutiselt lõdvendatud, sest nvm pole `set -u` puhas) ja
`tool_available` arvestab sellega. Paigaldaja ja verify kasutavad sama
funktsiooni, nii et nad ei saa omavahel eri meelt olla.

## Laiendusmustrid

1. **Uus apt-pakett (Ubuntu)** → üks rida `config/packages.conf`-i.
2. **Uus eriloogikaga tööriist (Ubuntu)** (Maven, Ollama, AWS CLI, ...) →
   rida `config/ai-tools.conf`-i + funktsioon `install_tool_<id>`.
3. **Uus Linuxi samm** (nt git-i seadistus, SSH-võtmed) → uus õhuke
   `scripts/04-*.sh` + menüürida `install.sh`-is.
4. **Uus Windowsi rakendus** → üks rida `config/windows-apps.conf`-i
   (nii lisandusid nt Slack ja Zoom).
5. **Uus IntelliJ plugin** → üks rida `config/intellij-plugins.conf`-i.
6. **Uus käsitsi samm** → üks rida `config/manual-steps.conf`-i
   (+ PDF-juhend kausta `docs/install/`).

Kõik spekis loetletud tulevikuplaanid mahuvad nendesse mustritesse ilma
refaktoorimiseta.

## Tulevikuplaan: kursuse projekti eellaadimine

Kokku lepitud (2026-07-15), aga veel tegemata — eeldab kursuse repo
olemasolu. Viimase sammuna setup.ps1-s:

1. **JDK Windowsi poolele** — üks rida `windows-apps.conf`-i (Temurin 21,
   sama major kui WSL-is); vajalik nii Gradle'ile kui IntelliJ-le.
2. **Kloonimine** — avalik kursuse repo (kaustad `backend` = Spring Boot
   Gradle, `frontend` = Vue 3 + Vite) standardsesse kohta, nt
   `%USERPROFILE%\vali-it\`. Kui kaust on juba olemas, EI puututa
   (õpilase töö!). Repo URL + sihtkaust lähevad uude confi
   (`config/course.conf`).
3. **Sõltuvuste eellaadimine** — `npm ci` frontend'is (node_modules
   valmis) ja `gradlew.bat dependencies` backend'is (Gradle ise + Maven
   Centrali sõltuvused cache'i). Eesmärk: klassis ei oota keegi
   allalaadimisi. Buildi/teste EI jooksutata.
4. **Servereid EI käivita installer** — õpilane käivitab need ise
   IntelliJ-s esimeses tunnis; juhend on PDF 023
   (`023-Kursuse-projekti-kaivitamine-IntelliJ.pdf`, praegu placeholder)
   ja see läheb siis `manual-steps.conf`-i.

Nõuded kursuse repole: DB-vaba `/hello` endpoint (`http://localhost:8080/hello`),
`server.address=localhost` application.properties'es (väldib Windowsi
tulemüüri dialoogi), `package-lock.json` olemas (`npm ci` jaoks).

## Testimine

- **CI (iga push/PR):** ShellCheck, PSScriptAnalyzer, smoke-test
  `ubuntu:22.04` ja `ubuntu:24.04` konteinerites (`install.sh --all`
  kaks korda järjest + verify) — idempotentsus on testiga jõustatud.
- **Käsitsi (WSL-i eripärad, mida konteiner ei kata):** värske masin,
  olemasolev distro parooliga kasutajaga, mõlemad distrod, katkestatud
  paigalduse jätkamine. Puhta seisu saab
  `wsl --unregister Ubuntu-22.04; wsl --install -d Ubuntu-22.04` abil.
