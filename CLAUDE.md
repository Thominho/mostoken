# MostOken – poznámky pro AI asistenty

- **Instalace na Mac uživatele:** postupuj přesně podle [INSTALL_FOR_AI.md](INSTALL_FOR_AI.md).
- **Sestavení:** `./build.sh`, potřebuje Xcode Command Line Tools. Výsledek je v `build/MostOken.app`.
- **Test bez oprávnění:** `./build/MostOken.app/Contents/MacOS/MostOken --selftest`
  (kódování videa, šifrování, přenos po TCP, dekódování).
- **Test s okny** (potřebuje oprávnění Záznam obrazovky a Zpřístupnění pro nainstalovanou aplikaci):
  `open -n /Applications/MostOken.app --args --test-source /tmp/zdroj.json`, potom
  `open -n /Applications/MostOken.app --args --autotest "MostOken test" --downloads /tmp/mostoken-test`.
  Výsledek je v `~/Library/Logs/MostOken.log` (řádky `AUTOTEST:`) a v `/tmp/zdroj.json`.
- **Vydání:** zvyš verzi tagem `vX.Y.Z` a pushni ho. `.github/workflows/release.yml` aplikaci sestaví,
  podepíše certifikátem z tajemství `SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD` a vydá ji.
  Nainstalované kopie se samy aktualizují. Certifikát neměň, jinak macOS zapomene udělená oprávnění.
- **Protokol mezi Macy je potřeba udržet zpětně kompatibilní**, protože se Macy aktualizují
  nezávisle. Nová pole přidávej jako nepovinná a nové typy zpráv jako nová čísla v `MsgType`.
- Texty v aplikaci jsou česky.
