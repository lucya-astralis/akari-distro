# akari-distro

Was aus einem Debian 13 (trixie) ein **Akari OS** macht, außer Akari selbst
(das liegt im Repo [akari](https://github.com/lucya-astralis/akari) und
bringt die Pakete `akari`, `akari-shell`, `akari-desktop`):

| Paket | Inhalt |
|---|---|
| `akari-base` | Systemidentität: `/usr/lib/os-release` mit `ID=akari`, `ID_LIKE=debian` (Debians Fassung per `dpkg-divert` beiseite), Begrüßung an der Konsole (agetty liest Akaris issue, `/etc/issue` bleibt Debians), dpkg-Herkunft `akari` |
| `akari-archive-keyring` | der öffentliche Schlüssel der Paketquelle, für `Signed-By:` |

Dazu das **Installer-ISO** (`iso/`) und die **Paketquelle**
[apt.lucya.systems](https://apt.lucya.systems) (GitHub Pages, `tools/ci-archive.sh`).

## Das ISO

`iso/build-iso.sh OUT` nimmt Debians offizielles Netinst (geprüft gegen
Debians signierte Prüfsummen) und legt Akaris Vorbelegung, den
Archiv-Schlüssel und den Booteintrag „Akari OS installieren“ dazu. Der
Installer fragt nur Sprache, Tastatur, Netz, Rechnername, Platte und das
erste Konto; das Konto verwaltet (sudo), root bleibt ohne Passwort. Nach dem
Neustart zeigt die Konsole die Adresse, unter der Akari im Browser läuft.

`iso/test/smoke.sh ISO` installiert es unbeaufsichtigt in QEMU und prüft das
Ergebnis von außen. Beides läuft im Workflow `iso`; das ISO liegt als
Artefakt am Lauf.

## Bauen

Auf einem Debian 13 (die Entwicklungs-VM aus dem Repo akari):

```bash
tools/build.sh                     # Pakete nach build/, dazu lintian.txt
tools/archive.sh DIR KEY-ID stable build/*.deb …   # signierte Paketquelle (reprepro)
```

Der Schlüssel der Paketquelle kommt nach `keys/akari-archive.asc` (nur der
öffentliche). Zum Testen baut `AKARI_ARCHIVE_KEY=<datei.asc> tools/build.sh`
den Keyring mit einem Entwicklungsschlüssel; aus dem Repo akari erledigt
`tools/devvm.sh archive` das alles in der VM.

## Eine Quelle einbinden

```
Types: deb
URIs: https://apt.lucya.systems
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/akari-archive-keyring.gpg
```

Dann `apt install akari-desktop akari-base`.

## Lizenz

AGPL-3.0-or-later, wie Akari OS (siehe LICENSE und NOTICE im Repo akari).
