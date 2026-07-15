# IT Crafters Installer

Paigaldab ja seadistab täieliku Java-arenduskeskkonna Ubuntu jaoks, mis
töötab WSL2 sees Windows 10/11 peal. Mõeldud programmeerimiskursuse
õpilastele, kes pole varem Linuxit kasutanud.

## Õpilasele: kiirstart

1. Ava **PowerShell administraatorina** (paremklõps Start-nupul → *Terminal (Admin)*).
2. Kleebi terminali see rida ja vajuta Enter:

   ```powershell
   irm https://raw.githubusercontent.com/it-crafters/itcrafters-installer/main/setup.ps1 | iex
   ```

3. Kui skript palub arvuti **taaskäivitada**, tee seda ja käivita pärast
   sama käsk uuesti — paigaldus jätkub sealt, kus see pooleli jäi.

Kõik muu käib automaatselt: WSL2, Ubuntu, kasutaja loomine ja kõigi
tööriistade paigaldus. Lõpus kuvatakse kontrolli kokkuvõte.

## Mida paigaldatakse?

| Tööriist | Milleks |
|---|---|
| OpenJDK 21 | Java arenduskeskkond |
| git, GitHub CLI | versioonihaldus |
| Node.js LTS (NVM kaudu) | JavaScripti käivituskeskkond |
| Claude Code | AI-abiline terminalis |
| Python 3, pip3 | skriptimine |
| curl, unzip, tree, jq, ripgrep, poppler-utils | käsurea tööriistad |
| postgresql-client | andmebaasiklient (psql) |

Täpne nimekiri: [`config/packages.conf`](config/packages.conf) ja
[`config/ai-tools.conf`](config/ai-tools.conf).

## Kasutamine Ubuntu sees

Installer jääb kausta `~/itcrafters-installer` ja seda võib alati
uuesti käivitada — juba paigaldatud asju ei paigaldata topelt:

```bash
cd ~/itcrafters-installer
./install.sh            # interaktiivne menüü
./install.sh --all      # paigalda kõik ilma menüüta
./install.sh --verify   # ainult kontroll (ei paigalda midagi)
```

## Toetatud versioonid

- Ubuntu 22.04 LTS ja 24.04 LTS (WSL2, Windows 10 build 19041+ või Windows 11)
- Olemasolevat Ubuntut ei kustutata ega lähtestata kunagi: kui 22.04 või
  24.04 on juba olemas, kasutatakse seda. Kui olemas on mõlemad, saab
  valida.

## Hooldajale

### Projekti struktuur

```
setup.ps1            Windowsi bootstrap (õpilase sissepääs)
install.sh           Linuxi peaskript (menüü / --all / --verify)
scripts/             sammud: 01-system, 02-ai-tools, 03-verify
lib/                 jagatud moodulid (ui, logger, checks, installer, verify, ...)
config/              paigaldatavate tööriistade nimekirjad
docs/ARCHITECTURE.md arhitektuur ja disainiotsused
```

### Uue apt-paketi lisamine

Lisa üks rida faili `config/packages.conf`:

```
pakett | kontrollkäsk | eestikeelne kirjeldus
```

Paigaldus ja kontroll hakkavad automaatselt tööle.

### Uue eriloogikaga tööriista lisamine

1. Lisa rida faili `config/ai-tools.conf` (nt `maven | mvn | Maven`).
2. Lisa funktsioon `install_tool_maven` faili `lib/installer.sh`.

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

## Tõrkeotsing

- **Midagi ebaõnnestus?** Käivita sama käsk lihtsalt uuesti — installer
  jätkab poolelijäänud kohast.
- **Tehniline logi** on Ubuntu sees failis `~/.itcrafters/install.log`.
  Vea kordumisel saada see fail õpetajale.
- **Kontroll ilma paigaldamata:** `./install.sh --verify` ütleb iga
  puuduva tööriista kohta, kuidas seda parandada.
- **Olemasolev Ubuntu ei käivitu?** Ära kustuta seda ise — pöördu
  õpetaja poole.

## Litsents

MIT — vt [LICENSE](LICENSE).
