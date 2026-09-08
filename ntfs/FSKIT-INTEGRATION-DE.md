# FSKit in OpenCommander

Stand: 8. September 2026.

**Aktualisierung:** Zusätzlich zum unten beschriebenen MIT-Kern gibt es jetzt
eine separate GPL-2.0-or-later-Integration mit NTFS-3G und schreibenden
Image-Tests. FSKit-Dateioperationen auf Testabbildern und unabhängiges erneutes
Lesen mit Apples NTFS-Treiber sind inzwischen bestanden; Oberflächentests und
Produktions-Sicherheitsprüfungen bleiben offen. Aktuelle Details und
Lizenzabgrenzung stehen in [NTFS3G/README.md](NTFS3G/README.md).
Die nachfolgende Dokumentation beschreibt den vorherigen Adapter-Arbeitsschritt.

## Darf OpenCommander FSKit verwenden?

Ja, die Verwendung der öffentlichen FSKit-Schnittstellen für eigene
Dateisystem-Erweiterungen entspricht Apples vorgesehenem Einsatz. Apple
beschreibt ausdrücklich eine mit der App ausgelieferte Erweiterung im
Userspace und die grundsätzliche Kompatibilität mit einer Mac-App-Store-
Verteilung. Das ist keine Zusage einer konkreten App-Store-Zulassung.
Es gelten die jeweils akzeptierten Apple-SDK- und Vertriebsvereinbarungen.

Quellen: [Apple FSKit](https://developer.apple.com/documentation/fskit),
[Apple-Vereinbarungen](https://developer.apple.com/support/terms/).

Wir verwenden das in macOS enthaltene Framework über seine API. Wir kopieren
nicht Apples Framework-Implementierung in unseren MIT-lizenzierten Quelltext.
Der eigene NTFS-Kern und der neu geschriebene Adapter bleiben MIT-lizenziert;
FSKit ist dadurch nicht selbst MIT-lizenziert. In dieser Änderung wurde kein
NTFS-3G-, NTFSKit- oder macFUSE-Code übernommen.

## Voraussetzungen und Grenzen

- FSKit ist laut Apple ab macOS 15.4 verfügbar, nicht für Windows, Android
  oder iOS. Der portable NTFS-Kern ist davon getrennt.
- Das native macOS-Erweiterungsziel `OpenCommanderNTFSModule` ist bereits
  vorhanden. Seine Entitlements enthalten `com.apple.developer.fskit.fsmodule`.
  Die Erweiterung muss korrekt signiert und mit der App ausgeliefert werden.
- Die Anwender aktivieren die Dateisystem-Erweiterung in den Systemeinstellungen
  unter Allgemein → Anmeldeobjekte & Erweiterungen → Dateisystem-Erweiterungen
  (Bezeichnung je nach macOS-Version). Apple dokumentiert dies im Beispiel.
- Eine solche FSKit-Anbindung benötigt kein macFUSE. Sie ersetzt aber nicht
  die Implementierung von NTFS-Verzeichnissen, Dateianlage, Speicherzuweisung,
  Journaling und Wiederherstellung.
- Die Aktivierung ist keine globale Freigabe geschützter Benutzerordner und
  verändert weder Datenschutzfreigaben noch System Integrity Protection.

Quellen: [Apples Erweiterungsbeispiel](https://developer.apple.com/documentation/FSKit/building-a-passthrough-file-system),
[FSKit-Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule).

## Entwicklungsstand und Prüfung

Der neue `SectorAlignedBlockDevice` wird vom FSKit-Adapter verwendet und
verhindert direkte unpassend ausgerichtete Byte-Zugriffe auf Blockressourcen.
Apple verlangt die Einhaltung der Transferanforderungen des Geräts und nennt
hier physische Sektoren, nicht nur logische Blöcke:
[FSBlockDeviceResource](https://developer.apple.com/documentation/fskit/fsblockdeviceresource).

Die Tests verwenden strikte synthetische Blockgeräte, die nicht ausgerichtete
Zugriffe ablehnen. Sie prüfen 512-Byte- und 4-KiB-Sektoren, Sektorgrenzen,
Teil-Schreibzugriffe einschließlich Nachbardaten, Transfergrenzen, leere
Zugriffe, ungültige Geometrie, Bereichsüberschreitungen, Schreibschutz,
kurze Lesezugriffe und weitergereichte Schreib-/Flush-Fehler.
Ein zusätzlicher Paralleltest prüft, dass gleichzeitige Teil-Schreibzugriffe
innerhalb derselben Adapterinstanz keine Nachbaränderungen verlieren.

Testaufruf: `swift test --package-path ntfs/OpenCommanderNTFS`.
Ergebnis dieser Änderung: 31 Tests erfolgreich, davon 13 neue Adaptertests.
Die beiden geänderten FSKit-Swift-Dateien bestehen zusätzlich eine
`swiftc -typecheck`-Prüfung für `arm64-apple-macosx15.4` gegen das lokale SDK.
Es wurde in diesem Schritt kein neues vollständiges App-Paket gebaut.

Die Tests ersetzen keinen End-to-End-Test einer eingebundenen FSKit-Erweiterung.
Der Treiber erkennt NTFS weiterhin nur und lehnt das Einhängen mit `ENOTSUP`
ab. Allgemeines NTFS-Schreiben ist noch nicht freigegeben; siehe
[WRITE-SUPPORT-STATUS.md](WRITE-SUPPORT-STATUS.md).
