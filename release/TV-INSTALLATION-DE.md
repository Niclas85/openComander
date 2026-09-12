# OpenCommander auf Android TV / Philips TV installieren

Die fertige TV-APK liegt neben dieser Anleitung als `OpenCommander-1.3-tv-universal.apk`.

## Variante A: USB-Stick

1. Kopiere `OpenCommander-1.3-tv-universal.apk` auf einen USB-Stick.
2. Stecke den USB-Stick am Fernseher ein und oeffne ihn mit einem vertrauenswuerdigen Dateimanager.
3. Falls Android die Installation blockiert, oeffne auf dem Fernseher `Einstellungen > Apps > Spezieller App-Zugriff > Unbekannte Apps installieren` und erlaube sie nur fuer den verwendeten Dateimanager. Der genaue Menuepfad kann je nach Philips-Modell und Android-Version abweichen.
4. Oeffne die APK und bestaetige den Android-Installationsdialog.
5. Starte OpenCommander aus der App-Uebersicht und erlaube den benoetigten Dateizugriff.
6. Deaktiviere danach die Freigabe fuer unbekannte Apps wieder.

## Variante B: Installation vom Mac ueber ADB

1. Fernseher und Mac mit demselben vertrauenswuerdigen Netzwerk verbinden.
2. Auf dem Fernseher die Entwickleroptionen aktivieren: Unter `Einstellungen > System > Info` den Eintrag `Build` bzw. `Android TV OS-Build` siebenmal mit OK auswaehlen.
3. In den Entwickleroptionen `USB-Debugging`, `Netzwerk-Debugging` oder `Drahtloses Debugging` aktivieren. Welche Bezeichnung angeboten wird, haengt von der Android-TV-Version ab.
4. Bei einer Kopplungsanzeige zuerst im Terminal `adb pair IP:PAIRING_PORT` ausfuehren und den Code des Fernsehers eingeben.
5. Danach im Repository ausfuehren:

   ```bash
   ./release/install-on-tv.sh ADB_SERIAL_ODER_IP:PORT
   ```

   Bei aelteren Fernsehern ist der Port haeufig `5555`, zum Beispiel:

   ```bash
   ./release/install-on-tv.sh 192.168.1.50:5555
   ```

6. Die RSA-Abfrage auf dem Fernseher bestaetigen. Das Skript installiert die APK, prueft den TV-Launcher und startet OpenCommander.

## Hinweise

- Nur auf einem Android-TV- oder Google-TV-Modell installieren. Philips-Fernseher mit Saphi oder Titan OS koennen Android-APKs nicht ausfuehren.
- APKs nur aus vertrauenswuerdigen Quellen installieren und Google Play Protect aktiviert lassen.
- Fuer ein spaeteres Update kann dasselbe Skript erneut verwendet werden; vorhandene App-Daten bleiben bei `adb install -r` erhalten.
