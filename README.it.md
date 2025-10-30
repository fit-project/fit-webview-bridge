# FIT WebView Bridge

[🇬🇧 English](README.md) | [🇮🇹 Italiano](README.it.md)

### Descrizione

**FIT WebView Bridge** è un widget Qt multipiattaforma (C++/Objective-C++) con binding **PySide6** che incapsula i motori web nativi del sistema:
- **Windows →** Edge WebView2
- **macOS →** WKWebView
- **Linux →** WebKitGTK (con **GStreamer** per i codec)

Espone una **API Python unificata** per controllare il browser ed abilita la **visualizzazione/acquisizione forense** di contenuti, inclusi quelli che richiedono codec proprietari (es. **H.264/AAC**), **senza** build personalizzate di QtWebEngine né oneri di redistribuzione dei codec (si usano quelli del sistema operativo). I **controlli** (UI e logica applicativa) sono **demandati alla finestra PySide**.

### Perché questo progetto
QtWebEngine (Chromium) di default **non abilita i codec proprietari** e la loro distribuzione richiede **licenza**. Le alternative considerate (compilare QtWebEngine con codec o usare QtWebView/QML) presentano limiti di portabilità/controllo. La via scelta è **incapsulare i motori di sistema**, ottenendo compatibilità con i codec e **massimo controllo** via API Python.

### Struttura del repository
```
fit-webview-bridge/
├─ CMakeLists.txt
├─ cmake/                   # Find*.cmake, toolchain, helper
├─ include/fitwvb/          # Header pubblici (API)
├─ src/
│  ├─ core/                 # Facade / interfacce comuni
│  ├─ win/                  # Backend Edge WebView2 (C++)
│  ├─ macos/                # Backend WKWebView (Obj-C++)
│  └─ linux/                # Backend WebKitGTK (C++)
├─ bindings/pyside6/        # Shiboken6: typesystem e config
├─ tests/                   # Unit / integration
└─ examples/                # Mini app PySide6 dimostrativa
```

### Interfaccia (metodi/slot + segnali)
**Metodi / slot**
- `load(url)`
- `back()`
- `forward()`
- `reload()`
- `stop()`
- `setHtml(html, baseUrl)`
- `evalJs(script, callback)`

**Segnali**
- `urlChanged(QUrl)`
- `titleChanged(QString)`
- `loadProgress(int)`
- `loadFinished(bool)`
- `consoleMessage(QString)`

> Nota: l’API è esposta in modo **uniforme** su tutti gli OS; l’implementazione delega al motore nativo.

### Prerequisiti
**Comuni**
- **CMake** (>= 3.24 consigliato)
- **Ninja** (generator)
- **Python** 3.9+
- **PySide6** e **Shiboken6** (per i binding Python)
- Strumenti di build della piattaforma

**Windows**
- **MSVC** (Visual Studio 2022 o Build Tools) e Windows SDK
- **Microsoft Edge WebView2 Runtime**
- **WebView2 SDK** (NuGet/vcpkg)

**macOS**
- **Xcode** + Command Line Tools
- Linguaggio **Objective-C++** abilitato (.mm)
- Framework: `WebKit`, `Cocoa`

**Linux**
- **GCC/Clang**, `pkg-config`
- **WebKitGTK** dev (es. `webkit2gtk-4.1` o equivalente della distro)
- **GStreamer** (base + plugin necessari per i codec)

### Compilazione (indicativa)
```bash
git clone https://github.com/fit-project/fit-webview-bridge.git
cd fit-webview-bridge
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PYSIDE6_BINDINGS=ON
cmake --build build
# (opzionale) ctest --test-dir build
```

### Esempi
Gli esempi PySide6 si trovano in `examples/` e mostrano caricamento URL, iniezione JS e ascolto dei segnali.

### Considerazioni su codec e licenze
Il progetto **non** ridistribuisce codec proprietari: sfrutta i codec **già presenti nel sistema operativo**. L’uso finale dei contenuti è responsabilità dell’utente in base alle rispettive licenze/formati.

### Stato del progetto
Iniziale/alpha (API soggetta a modifiche).

---

 Fit Web — Motivazioni del progetto e opzioni per i codec proprietari

**Fit Web** è il modulo *scraper* del progetto FIT pensato per **acquisire e cristallizzare, con modalità forensi, contenuti web**: <https://github.com/fit-project/fit-web>.

Come gli altri moduli, **Fit Web** si basa su **PySide** (Qt per Python). Attualmente utilizza **QtWebEngine**, che è un *wrapper* di **Chromium**.

## Il problema
Chromium, di default, **non abilita i codec audio/video proprietari**, in particolare **H.264** e **AAC**.

## Soluzioni considerate

### 1) Compilare QtWebEngine con codec proprietari
Abilitare l’opzione `-webengine-proprietary-codecs`.  
Documentazione: <https://doc.qt.io/qt-6/qtwebengine-overview.html>

**Criticità**
- Va eseguito per **tutti i sistemi operativi** supportati.
- La compilazione richiede **macchine molto performanti** (es.: difficoltà su MacBook Air M2 con 16 GB di RAM).
- **Licenze**: la **distribuzione** di H.264 e AAC **richiede una licenza**.

### 2) Usare QtWebView
QtWebView utilizza **le API web native del sistema operativo**; per i contenuti con codec proprietari sfrutta **i codec del sistema**.  
**Vantaggi**: niente compilazioni personalizzate, niente gestione diretta delle licenze.  
**Limiti**: l’interfaccia è in **QML**, pensata per UI leggere (spesso mobile), e **non offre il controllo completo** sul browser rispetto a QtWebEngine.

Documentazione: <https://doc.qt.io/qt-6/qtwebview-index.html>

### 3) Scrivere un widget Qt nativo (C/C++) per ogni OS
Creare un widget Qt (usabile da **PySide6**) che *embedda* il motore web di sistema:

- **Windows →** Edge WebView2
- **macOS →** WKWebView
- **Linux →** WebKitGTK (con **GStreamer** per i codec)

**Vantaggi**
- **Nessuna licenza da redistribuire**: si usano i codec già forniti dal sistema.
- Possibilità di **un’API comune** da esporre a PySide6.
- **Maggiore controllo** rispetto a QtWebView, senza i limiti imposti da QML.

**Svantaggi**
- **Complessità medio‑alta** di implementazione.
- Richiede **C++** e, su macOS, anche **Objective‑C++**.
- Necessità di **CMake** ad hoc per includere librerie e collegamenti.

---