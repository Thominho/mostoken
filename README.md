# MostOken

Spojí dva Macy tak, že se chovají jako jeden počítač se dvěma obrazovkami. Okno přetáhneš
přes okraj obrazovky a objeví se na druhém Macu. Tam ho normálně používáš myší i klávesnicí
a stejně snadno ho vrátíš zpátky.

MostOken doplňuje funkci macOS **Univerzální ovládání**: ta převádí mezi Macy myš,
klávesnici a přetahování souborů. MostOken k tomu přidává přesouvání oken.

## Co umí

- **Přetažení okna na druhý Mac.** Okno chytíš za horní lištu, dotáhneš ho k okraji
  obrazovky směrem k druhému Macu a chvilku ho tam podržíš. Objeví se na druhém Macu
  na místě, kde jsi okraj přešel.
- **Plné ovládání** přesunutého okna: klikání, psaní, klávesové zkratky (⌘C, ⌘V…), posouvání
  a změna velikosti.
- **Okno se chová jako místní:** přesouvá se za vlastní lištu, žluté tlačítko ho minimalizuje
  a zelené zvětší na Macu, kde zrovna je. Červené tlačítko okno zavře, stejně jako na jednom počítači.
- **Vrácení okna** přetažením za lištu zpět přes okraj nebo ⌃⌥⌘ + šipkou.
- **Nabídky:** kontextové nabídky (pravé tlačítko) a rozbalovací seznamy se zobrazí na Macu,
  kde okno právě je.
- **Rozložení Maců** vlevo, vpravo, nahoře nebo dole. Nastavuje se přetažením v Nastavení
  a samo se přenese na druhý Mac.
- **Soubory do okna:** soubor puštěný do okna z druhého Macu se přenese na ten Mac a otevře
  se v té aplikaci.
- **Šifrované spojení:** Macy se jednou spárují ověřovacím kódem a pak je všechno šifrované
  (X25519 + ChaCha20-Poly1305).
- **Automatické aktualizace** z GitHub Releases a spouštění po přihlášení.

## Požadavky

- Dva Macy s čipem Apple (M1 a novější) a systémem macOS 13 Ventura nebo novějším.
- Stejná Wi-Fi, případně jen zapnuté Wi-Fi a Macy blízko sebe.
- Pro převádění myši a klávesnice zapnuté Univerzální ovládání: stejné Apple ID a Handoff.

## Instalace

**Nejjednodušší:** řekni AI asistentovi na Macu (třeba Claude Code):

> Nainstaluj mi MostOken podle návodu https://raw.githubusercontent.com/Thominho/mostoken/main/INSTALL_FOR_AI.md a propoj ho s mým druhým Macem.

**Ručně:**

```bash
curl -fsSL https://raw.githubusercontent.com/Thominho/mostoken/main/install.sh -o /tmp/mostoken-install.sh
bash /tmp/mostoken-install.sh
```

Pak povol oprávnění **Záznam obrazovky** a **Zpřístupnění** (Nastavení systému → Soukromí
a zabezpečení) a MostOken spusť znovu. Při prvním spojení oba Macy ukážou stejný ověřovací
kód. Potvrď ho na obou.

## Jak to funguje

Okno ve skutečnosti dál běží na původním Macu. MostOken ho tam zachytává (ScreenCaptureKit),
kóduje hardwarově do H.264 s nízkou latencí a posílá šifrovaně na druhý Mac. Tam se zobrazí
jako normální okno. Kliknutí a klávesy se posílají zpátky a přehrávají se přímo do dané
aplikace. Původní okno se mezitím odsune skoro celé za okraj obrazovky.

## Omezení

- Když se původní Mac uspí nebo spojení spadne, okno se vrátí zpátky na něj.
- Obraz je komprimovaný, takže drobné písmo může být při rychlých změnách chvilku méně ostré.
- Z přesunutého okna zatím nejde přetáhnout soubor ven, funguje jen směr do okna.
- Na obou Macích by mělo být stejné rozložení klávesnice.
- Kliknutí a klávesy se doručují přímo aplikaci na původním Macu, kde se přitom nic nehýbe.
  Kdyby některá aplikace na kliknutí nereagovala, zapni v Nastavení „Klikat přes kurzor“.
- Kurzor nad přeneseným oknem má vždy tvar šipky (nemění se na textový kurzor apod.).

## Vývoj

```bash
./build.sh                                            # sestaví build/MostOken.app
./build/MostOken.app/Contents/MacOS/MostOken --selftest  # test kódování, šifrování a přenosu
```

Nové vydání: zvyš verzi tagem, třeba `git tag v1.0.1 && git push --tags`. GitHub Actions
sestaví a podepíše aplikaci a nainstalované kopie se samy aktualizují. Podpisový certifikát
je v tajemstvích repozitáře. Díky stejnému certifikátu si macOS pamatuje oprávnění i po
aktualizaci.

Log aplikace: `~/Library/Logs/MostOken.log`.
