# Instalace MostOken – pokyny pro AI asistenta

Tenhle soubor je pro AI asistenta (např. Claude Code), kterého uživatel požádal, ať mu
na Macu nainstaluje MostOken a propojí ho s jeho druhým Macem.

**Jak postupovat:**
- S uživatelem mluv česky, stručně a jednoduše. Veď ho krok za krokem.
- Příkazy v terminálu spouštěj sám. Kliknutí v systémových dialozích a v Nastavení systému
  musí udělat uživatel. Řekni mu přesně, kam má kliknout, a počkej, až to udělá.
- Neměň za uživatele systémová nastavení ani oprávnění. Nevypínej firewall.
- Na druhém Macu už MostOken obvykle běží, protože uživatel ho tam nainstaloval dřív.

## 1. Kontrola Macu

```bash
uname -m              # musí vypsat arm64 (čip Apple M1 nebo novější)
sw_vers -productVersion   # musí být 13 nebo vyšší
```

Pokud jedna z podmínek neplatí, řekni uživateli, že MostOken na tomhle Macu nepoběží, a skonči.

## 2. Instalace

Stáhni instalační skript, přečti si ho a pak ho spusť:

```bash
curl -fsSL https://raw.githubusercontent.com/Thominho/mostoken/main/install.sh -o /tmp/mostoken-install.sh
cat /tmp/mostoken-install.sh
bash /tmp/mostoken-install.sh
```

Skript stáhne nejnovější vydání z GitHubu (`Thominho/mostoken`). Ověří kontrolní součet
i podpis, nainstaluje aplikaci do `/Applications/MostOken.app` a spustí ji. Ikona MostOken
(dvě okna) se objeví v řádku nabídek nahoře vpravo.

## 3. Oprávnění (dělá uživatel)

Řekni uživateli, ať udělá tohle:

1. Dialog **„MostOken chce najít zařízení v místní síti“** → **Povolit**.
2. Uvítací okno MostOken → **Pokračovat**.
3. **Záznam obrazovky:** Nastavení systému → Soukromí a zabezpečení → Záznam obrazovky
   a zvuku systému → zapnout **MostOken**. Pokud tam MostOken chybí, přidá ho tlačítkem +
   ze složky Aplikace.
4. **Zpřístupnění:** Nastavení systému → Soukromí a zabezpečení → Zpřístupnění → zapnout
   **MostOken**.

Pak MostOken restartuj:

```bash
pkill -x MostOken; sleep 2; open /Applications/MostOken.app
```

Kontrola, že jsou obě oprávnění povolená:

```bash
grep "Oprávnění:" ~/Library/Logs/MostOken.log | tail -1
# očekávaný výsledek: Oprávnění: záznam obrazovky=true, zpřístupnění=true
```

## 4. Spárování s druhým Macem

- MostOken musí běžet na obou Macích a oba musí být ve stejné síti (stejná Wi-Fi).
  Případně stačí, že jsou blízko sebe a mají zapnuté Wi-Fi.
- Do minuty se na **obou** Macích objeví okno **„Spárovat s Macem …?“** s šestimístným
  ověřovacím kódem. Uživatel zkontroluje, že je kód na obou Macích stejný, a na obou klikne
  na **Spárovat**.
- Ověření:

```bash
grep -E "Spárováno|Připojeno k:" ~/Library/Logs/MostOken.log | tail -3
```

Když se Macy do dvou minut nenajdou:
- Nastavení systému → Soukromí a zabezpečení → **Místní síť** → zapnout **MostOken**
  (na obou Macích).
- Pokud je zapnutý firewall (Nastavení systému → Síť → Firewall) a ptá se na příchozí
  spojení pro MostOken, má uživatel kliknout na **Povolit**.
- Zkontroluj, že jsou oba Macy ve stejné Wi-Fi.
- Prohlédni si log: `tail -50 ~/Library/Logs/MostOken.log`.

## 5. Rozložení Maců

1. Ikona MostOken v řádku nabídek → **Nastavení…** → v části „Kde stojí druhý Mac“
   přetáhnout druhý Mac na stranu, kde opravdu stojí. Volba je Vlevo, Vpravo, Nahoře
   nebo Dole. Nastavení se samo přenese i na druhý Mac.
2. Myš a klávesnici mezi Macy převádí funkce macOS **Univerzální ovládání**. Na obou
   Macích musí platit:
   - stejné Apple ID, zapnuté Wi-Fi a Bluetooth,
   - Nastavení systému → Obecné → AirDrop a Handoff → zapnutý **Handoff**,
   - Nastavení systému → Monitory → **Pokročilé…** → zapnuté všechny tři volby o
     propojení s Macem nebo iPadem,
   - v Nastavení systému → Monitory jsou Macy rozložené stejně jako v MostOken.

## 6. Hotovo – vysvětli uživateli, jak to používat

- **Poslat okno na druhý Mac:** přetáhnout okno za horní lištu k okraji obrazovky směrem
  k druhému Macu a chvilku ho tam podržet. Nebo stisknout ⌃⌥⌘ + šipku.
- **Vrátit okno:** přetáhnout ho zpět přes okraj, zavřít ho červeným tlačítkem, nebo
  znovu stisknout ⌃⌥⌘ + šipku.
- **Soubory:** mezi plochami a Findery je přetahuje Univerzální ovládání. Soubor puštěný
  do okna, které přišlo z druhého Macu, se zkopíruje na ten Mac do Stažené soubory/MostOken
  a otevře se v dané aplikaci.
- MostOken se spouští po přihlášení a aktualizuje se sám.

## Užitečné

- Log: `~/Library/Logs/MostOken.log`
- Ruční aktualizace: ikona MostOken → Zkontrolovat aktualizace, nebo znovu spustit
  instalační skript.
- Odinstalace: `pkill -x MostOken; rm -rf /Applications/MostOken.app ~/Library/Application\ Support/MostOken`
