# Vali-IT Installer

Paigaldab ja seadistab täieliku Java-arenduskeskkonna: Windowsi rakendused
(IntelliJ IDEA, PostgreSQL, Docker Desktop jt) ning Ubuntu WSL2 keskkonna
koos kõigi käsurea-tööriistadega. Mõeldud programmeerimiskursuse
õpilastele, kes pole varem Linuxit kasutanud.

## Õpilasele: kiirstart

1. Ava **PowerShell administraatorina** (paremklõps Start-nupul → *Terminal (Admin)*).
2. Kleebi terminali see rida ja vajuta Enter:

   ```powershell
   irm https://raw.githubusercontent.com/bcs-hub/vali-it-installer/main/setup.ps1 | iex
   ```

3. Kui skript palub arvuti **taaskäivitada**, tee seda ja käivita pärast
   sama käsk uuesti — paigaldus jätkub sealt, kus see pooleli jäi.

Lõpus kuvatakse kokkuvõte kolmes osas: mis õnnestus, mis ebaõnnestus
(koos juhendiga, kuidas käsitsi teha) ja mida pead ise läbi tegema.
Sama kokkuvõte salvestatakse töölauale failina **Vali-IT-kokkuvote.html**
(avaneb ise brauseris) — sealt leiad klikitavad juhendid, andmebaasi
ühendusandmed ja saad selle vajadusel õpetajale saata.

## Mida paigaldatakse?

**Windowsi poolel** (loend: [`config/windows-apps.conf`](config/windows-apps.conf)):

| Rakendus | Milleks |
|---|---|
| Git | versioonihaldus |
| Node.js LTS | JavaScripti käivituskeskkond |
| PostgreSQL 17 | andmebaasiserver (+ kursuse andmebaas `vali_it`) |
| Java 21 (Temurin JDK) | Java arenduskeskkond (Gradle ja IntelliJ jaoks) |
| IntelliJ IDEA | arenduskeskkond (+ pluginad ja seaded) |
| Docker Desktop | konteinerid |
| Slack | kursuse suhtlus |
| Zoom | videoloengud |

**Ubuntu (WSL2) poolel** (loendid: [`config/packages.conf`](config/packages.conf),
[`config/ai-tools.conf`](config/ai-tools.conf)):

OpenJDK 21, git, GitHub CLI, NVM + Node.js LTS, Claude Code, Python 3,
curl, unzip, tree, jq, ripgrep, poppler-utils, postgresql-client.

### Andmebaas

Värskel paigaldusel luuakse kursuse andmebaas järgmiste andmetega
(needsamad kuvatakse õpilasele HTML-kokkuvõttes):

| | |
|---|---|
| Host / port | `localhost:5432` |
| Andmebaas | `vali_it` |
| Kasutaja / parool | `postgres` / `student123` |
| IntelliJ andmeallika URL | `jdbc:postgresql://localhost:5432/vali_it` |

Olemasolevat PostgreSQL-i serverit ei muudeta — sel juhul jääb
andmebaasi loomine käsitsi sammuks (juhend kokkuvõttes).

### Kursuse projekt

Kõige lõpus kloonib installer kursuse projekti (loend:
[`config/course.conf`](config/course.conf)) kausta
`%USERPROFILE%\vali-it\` ja laadib sõltuvused ette (frontend: `npm ci`,
backend: `gradlew dependencies`), et klassis ei ootaks keegi
allalaadimisi. Servereid installer ei käivita — seda teeb õpilane ise
IntelliJ-s. Olemasolevat projektikausta ei puututa kunagi. Kokkuvõttes
sõltub tulemus jooksust: kui projekt on kettal, on "Tee ise läbi"
nimekirjas serverite käivitamise samm koos kaustateega (juhend
[025](docs/install/025-Serverite-kaivitamine-IntelliJ.pdf)); kui
allalaadimine ebaõnnestus, viitab punane kirje käsitsi allalaadimise
juhendile ([023](docs/install/023-Kursuse-projekti-allalaadimine-ja-avamine.pdf))
koos repo lingiga. Uue kursuse jaoks piisab repo-URL-i muutmisest
`course.conf`-is (bank41 → bank42 → ...).

## Käsitsi sammud pärast paigaldust

Neid ei saa automatiseerida; installer kuvab sama nimekirja kokkuvõttes
(loend: [`config/manual-steps.conf`](config/manual-steps.conf)):

1. [IntelliJ litsentsi aktiveerimine](docs/install/020-IntelliJ-litsentsi-aktiveerimine.pdf)
2. [Docker Desktopi esmane käivitamine](docs/install/019-Docker-Desktopi-esmane-kaivitamine.pdf)
3. [GitHubi konto ja gh sisselogimine](docs/install/021-GitHub-konto-ja-gh-sisselogimine.pdf)
4. [Claude Code'i esimene käivitamine](docs/install/022-Claude-Code-esimene-kaivitamine.pdf)
5. [Terminali vaikeshelli määramine](docs/install/014-Terminali-default-shell-i-maaramine-WSL-Ubuntu.pdf) (soovi korral)

Lisaks lisandub nimekirja [serverite käivitamise samm](docs/install/025-Serverite-kaivitamine-IntelliJ.pdf),
kui kursuse projekt on arvutis olemas (vt "Kursuse projekt" ülal).

Kõik sammsammulised juhendid on kaustas [`docs/install/`](docs/install/).

## Kasutamine Ubuntu sees

Installer jääb kausta `~/vali-it-installer` ja seda võib alati uuesti
käivitada — juba paigaldatud asju ei paigaldata topelt:

```bash
cd ~/vali-it-installer
./install.sh            # interaktiivne menüü
./install.sh --all      # paigalda kõik ilma menüüta
./install.sh --verify   # ainult kontroll (ei paigalda midagi)
```

## Toetatud versioonid

- Windows 10 (build 19041+, uuendatud) või Windows 11
- Ubuntu 22.04 LTS ja 24.04 LTS (WSL2)
- Olemasolevat Ubuntut ega Windowsi rakendusi ei kustutata ega uuendata
  kunagi: mis on olemas, jääb puutumata. Kui olemas on mõlemad Ubuntu
  versioonid, saab valida; versiooni saab ette anda ka käsitsi:
  `$env:ITC_DISTRO = 'Ubuntu-22.04'` enne skripti käivitamist.

## Hooldajale

### Projekti struktuur

```
setup.ps1            Windowsi bootstrap (õpilase sissepääs): winget-rakendused,
                     PostgreSQL, IntelliJ seadistus, WSL2 + Ubuntu, kokkuvõte
uninstall.ps1        eemaldaja: võtab maha selle, mille installer ise paigaldas
install.sh           Linuxi peaskript (menüü / --all / --verify)
scripts/             sammud: 01-system, 02-ai-tools, 03-verify
lib/                 jagatud moodulid (ui, logger, checks, installer, verify, ...)
config/              paigaldatavate tööriistade/rakenduste/sammude nimekirjad
docs/install/        õpilase PDF-juhendid (installer viitab neile kokkuvõttes)
docs/IntelliJ/       settings.zip — IDEA eksporditud seaded
docs/ARCHITECTURE.md arhitektuur ja disainiotsused
```

### Uue asja lisamine

- **apt-pakett (Ubuntu):** üks rida faili `config/packages.conf`
- **eriloogikaga tööriist (Ubuntu):** rida faili `config/ai-tools.conf` +
  funktsioon `install_tool_<id>` failis `lib/installer.sh`
- **Windowsi rakendus:** üks rida faili `config/windows-apps.conf`
  (winget-id + kontrollkäsk + PDF-viide käsitsi varuteeks)
- **IntelliJ plugin:** üks rida faili `config/intellij-plugins.conf`
- **käsitsi samm:** üks rida faili `config/manual-steps.conf`
- **kursuse repo vahetus:** muuda URL-i failis `config/course.conf`

### Testimine

```bash
# ShellCheck (sama, mida jooksutab CI)
shellcheck -x install.sh scripts/*.sh lib/*.sh

# Täielik smoke-test puhtas konteineris (mõlemad versioonid)
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl ca-certificates >/dev/null &&
  useradd -m student && echo "student ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/student &&
  cp -r /src /home/student/app && chown -R student:student /home/student/app &&
  su - student -c "cd ~/app && ./install.sh --all"'
```

CI (GitHub Actions) jooksutab iga muudatuse peale ShellChecki,
PSScriptAnalyzeri ja smoke-testi Ubuntu 22.04 ja 24.04 konteinerites,
sealhulgas idempotentsustesti (paigaldus kaks korda järjest).
Windowsi-poolset (winget, PostgreSQL, IntelliJ) osa CI ei kata — seda
testitakse päris masinal.

WSL-i eripärade testimiseks päris masinal ("värske õpilase" seis) vt
[docs/UBUNTU-CLEAN-INSTALL.md](docs/UBUNTU-CLEAN-INSTALL.md) — Ubuntu
puhas kustutamine ja taaspaigaldus.

### Eemaldamine (testmasina lähtestamine)

Installer peab manifesti (`%LOCALAPPDATA%\vali-it\installed.txt`) sellest,
mille ta **ise** paigaldas — mis oli masinas juba enne, sinna ei kuulu.
Eemaldaja võtab vaikimisi maha ainult manifestis oleva:

```powershell
irm https://raw.githubusercontent.com/bcs-hub/vali-it-installer/main/uninstall.ps1 | iex
```

Enne kustutamist näidatakse nimekirja ja küsitakse kinnitust (`jah`,
suur- või väiketähtedega). Kursuse projektikausta kohta küsitakse eraldi —
vaikimisi (Enter) jääb see alles, sest seal võib olla õpilase oma töö.
Valikud keskkonnamuutujatega enne käivitamist:

```powershell
$env:ITC_YES = '1'     # ära küsi kinnitust
$env:ITC_PURGE = '1'   # TÄIELIK lähtestamine: eemalda ka kõik manifestist
                       # puuduv — kursuse rakendused (config/windows-apps.conf),
                       # kõik toetatud Ubuntu distrod, kursuse kaust
                       # (config/course.conf), JetBrains-i seadetekaustad ja
                       # PostgreSQL-i jääkandmed. Kasuta testmasinas, kus
                       # paigaldus tehti enne manifesti olemasolu.
```

NB! Ubuntu distro ja kursuse projektikausta kustutamine hävitab kõik neis
olevad failid — eemaldaja hoiatab selle eest nimekirjas eraldi.

## Tõrkeotsing

- **Midagi ebaõnnestus?** Käivita sama käsk lihtsalt uuesti — installer
  jätkab poolelijäänud kohast. Kokkuvõtte punane nimekiri viitab iga
  ebaõnnestunud asja juures PDF-juhendile, millega saab sama teha käsitsi.
- **Tehniline logi** on Ubuntu sees failis `~/.vali-it/install.log`.
  Vea kordumisel saada see fail õpetajale.
- **Kontroll ilma paigaldamata:** `./install.sh --verify` ütleb iga
  puuduva tööriista kohta, kuidas seda parandada.
- **Olemasolev Ubuntu ei käivitu?** Ära kustuta seda ise — pöördu
  õpetaja poole.

## Litsents

MIT — vt [LICENSE](LICENSE).
