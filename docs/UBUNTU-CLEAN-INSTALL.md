# Ubuntu puhas taaspaigaldus (WSL)

Juhend testijale/hooldajale: kuidas WSL-i Ubuntu täielikult kustutada ja
puhtalt uuesti paigaldada — näiteks installeri testimiseks "värske
õpilase masina" seisus. Näited on Ubuntu 22.04 kohta; 24.04 puhul asenda
lihtsalt versiooninumber.

> **NB!** `wsl --unregister` kustutab distro **koos kõigi failidega**
> pöördumatult. Teised distrod (nt Ubuntu-24.04) jäävad puutumata — iga
> distro on täiesti eraldi.

## 1. Vaata, mis on paigaldatud

```powershell
wsl --list --verbose
```

## 2. Kustuta vana Ubuntu

```powershell
wsl --unregister Ubuntu-22.04
```

Kui tahad ka Store'i rakenduse (launcheri) eemaldada — testimiseks pole
vaja, `--unregister` kustutab kõik andmed:

```powershell
winget uninstall Canonical.Ubuntu.2204
```

## 3. Paigalda Ubuntu uuesti

```powershell
wsl --install -d Ubuntu-22.04
```

Lõpus avaneb Ubuntu aken, mis küsib kasutajanime ja parooli — täida ära
(parool ei paista trükkides, see on normaalne). Pärast võid akna sulgeda.

See on sama tee, mida käib õpilane, kellel on Ubuntu juba ees. Kui tahad
testida hoopis haru, kus **installer ise distro paigaldab ja kasutaja
loob**, jäta see samm vahele — setup.ps1 teeb kõik ise.

## 4. Käivita installer

Administraatori PowerShellis:

```powershell
$env:ITC_DISTRO = 'Ubuntu-22.04'
irm https://raw.githubusercontent.com/bcs-hub/vali-it-installer/main/setup.ps1 | iex
```

`$env:ITC_DISTRO` hoiab ära valikuküsimuse, kui masinas on ka teine
Ubuntu. Ilma selleta küsib skript, kumba kasutada.

## 5. Kontrolli tulemust

```powershell
wsl -d Ubuntu-22.04 -- bash -lc "which claude && claude --version"
```

Tee peab olema `/home/<kasutaja>/.nvm/...` — kui näed `/mnt/c/...`, on
tööriist ainult Windowsi poolel, mitte distro sees.

Täieliku kontrolli saab distro seest:

```bash
cd ~/vali-it-installer && ./install.sh --verify
```

## Kiire testitsükkel ühe reana

```powershell
wsl --unregister Ubuntu-22.04; wsl --install -d Ubuntu-22.04
```

...täida kasutajaviisard, siis samm 4.

## Alternatiiv: hetktõmmis kiireks taastamiseks

Kui testid mitu korda järjest, on eksport/import kiirem kui täispaigaldus:

```powershell
# enne testi: salvesta puhas seis
wsl --export Ubuntu-22.04 C:\WSL\ubuntu22-puhas.tar

# pärast testi: taasta puhas seis
wsl --unregister Ubuntu-22.04
wsl --import Ubuntu-22.04 C:\WSL\ubuntu22 C:\WSL\ubuntu22-puhas.tar
```

NB! `--import`-itud distro vaikekasutaja on root, kuni setup.ps1 (või
`/etc/wsl.conf`) selle uuesti paika paneb — installer käsitleb seda ise.
