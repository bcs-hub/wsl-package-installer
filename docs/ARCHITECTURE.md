# Arhitektuur ja disainiotsused

See dokument fikseerib IT Crafters Installeri arhitektuuri ja otsuste
põhjendused. Kinnitatud 2026-07-15.

## Suur pilt: kaks kihti

```
  ÕPILANE
    │  PowerShell (admin), üks rida:
    │  irm https://raw.githubusercontent.com/<org>/itcrafters-installer/main/setup.ps1 | iex
    ▼
┌─────────────────────────────────────────────┐
│  KIHT 1: setup.ps1  (Windows)               │
│  WSL2 + Ubuntu valmis, kasutaja loodud,     │
│  paroolita sudo, repo tõmmatud distrosse    │
└─────────────────────────────────────────────┘
    │  wsl -d <distro> -- ./install.sh --all
    ▼
┌─────────────────────────────────────────────┐
│  KIHT 2: install.sh + scripts/ + lib/       │
│  (Ubuntu sees) paigaldab → kontrollib       │
└─────────────────────────────────────────────┘
```

Kihid on lõdvalt seotud: kiht 2 ei tea kihi 1 olemasolust midagi ja
töötab iseseisvalt (menüü, Docker-konteiner, päris-Ubuntu). See teeb
Linuxi poole testitavaks ilma Windowsita.

## Kesksed otsused

| Otsus | Põhjendus |
|---|---|
| Docker on skoobist väljas | WSL2 systemd/Docker Desktopi keerukus; tehakse eraldi projektina |
| Installer jookseb tavakasutajana, mitte root'ina | NVM, Node ja Claude Code peavad minema õpilase kodukausta; `sudo` ainult apt-käskudel. `install.sh` keeldub root'ina käivitumast |
| Paroolita sudo (`/etc/sudoers.d/itcrafters`) | Null küsimust paigalduse ajal; WSL-is pole Linuxi parool nagunii turvapiir (`wsl -u root` on Windowsi poolelt alati avatud) |
| Vea korral menüü jätkab | Üks ebaõnnestunud samm raporteeritakse eestikeelselt; sammud jooksevad alamprotsessidena (`run_step`) |
| Olemasolevat distrot EI kustutata kunagi | Automaatika ei tohi kellegi andmeid hävitada; katkise distro puhul suuname õpetaja juurde |
| Olemasolev 22.04/24.04 võetakse kasutusele | Sellepärast toetabki installer mõlemat versiooni; mõlema olemasolul küsitakse (24.04 soovitatud), `-Distro` parameeter valib käsitsi |
| setup.ps1 on jätkatav olekumasin | Iga samm: "kas juba tehtud? → jäta vahele". Taaskäivituse järel sama käsk jätkab; korduvkäivitus on ohutu |
| Kood tõmmatakse Windowsi poolel (tarball) | Värskes distros pole git/curl garanteeritud; `tar` on alati olemas |
| Tehniline väljund logifaili `~/.itcrafters/install.log` | Ekraanil ainult puhas eestikeelne progress; vea korral saadab õpilane logifaili õpetajale |
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
| `lib/colors.sh` | värvid ja sümbolid ([x] ⚠ ✗); väljas, kui väljund pole terminal |
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

1. **Uus apt-pakett** → üks rida `config/packages.conf`-i.
2. **Uus eriloogikaga tööriist** (Maven, Ollama, AWS CLI, ...) → rida
   `config/ai-tools.conf`-i + funktsioon `install_tool_<id>`.
3. **Uus samm** (nt git-i seadistus, SSH-võtmed) → uus õhuke
   `scripts/04-*.sh` + menüürida `install.sh`-is.

Kõik spekis loetletud tulevikuplaanid mahuvad nendesse mustritesse ilma
refaktoorimiseta.

## Testimine

- **CI (iga push/PR):** ShellCheck, PSScriptAnalyzer, smoke-test
  `ubuntu:22.04` ja `ubuntu:24.04` konteinerites (`install.sh --all`
  kaks korda järjest + verify) — idempotentsus on testiga jõustatud.
- **Käsitsi (WSL-i eripärad, mida konteiner ei kata):** värske masin,
  olemasolev distro parooliga kasutajaga, mõlemad distrod, katkestatud
  paigalduse jätkamine. Puhta seisu saab
  `wsl --unregister Ubuntu-22.04; wsl --install -d Ubuntu-22.04` abil.
