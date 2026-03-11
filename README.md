<div align="center">

<br/>

```
 ██████╗  █████╗ ████████╗███████╗██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗
██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║
██║  ███╗███████║   ██║   █████╗  ██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║
██║   ██║██╔══██║   ██║   ██╔══╝  ╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║
╚██████╔╝██║  ██║   ██║   ███████╗ ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║
 ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝  ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝
```

**Rozpoznawanie tablic rejestracyjnych i kontrola bramy — iOS + Web Panel**

[![iOS](https://img.shields.io/badge/iOS-16%2B-black?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.9-FA7343?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-✓-blue?style=flat-square)](https://developer.apple.com/swiftui/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square)](CONTRIBUTING.md)

<br/>

<img src="https://img.shields.io/badge/Apple%20Vision-Neural%20Engine-purple?style=for-the-badge&logo=apple" />
<img src="https://img.shields.io/badge/Web%20Panel-port%206600-00D4FF?style=for-the-badge&logo=googlechrome&logoColor=white" />
<img src="https://img.shields.io/badge/OCR-8--20%20FPS-B8FF35?style=for-the-badge&logoColor=black" />

</div>

---

## Czym jest ten projekt?

**GateVision** to system automatycznej kontroli bramy wjazdowej przeznaczony dla firm. Docelowym urządzeniem jest Raspberry Pi, natomiast aplikacja na iOS służy jako proof of concept. Kamera w czasie rzeczywistym rozpoznaje tablice rejestracyjne używając **Apple Vision Framework** (Neural Engine), porównuje je z bazą danych i automatycznie otwiera/zamyka bramę przez GPIO.

W tle jest uruchomiony **serwer HTTP** (domyślnie na porcie 6600) — na którym znajduje się panel webowy dostępny do zarządzania.

```
iPhone z GateVision
      │
      ├── 📷  Kamera → Apple Vision OCR → Rozpoznanie tablicy
      │
      ├── 🔌  GPIO/przekaźnik → Sterowanie bramą fizycznie
      │
      └── 🌐  HTTP :6600 → Panel web (dokładnie ten sam co w wersji na Raspberry Pi)
```

---

## ✨ Funkcje

| Kategoria | Opis |
|-----------|------|
| 🔍 **OCR w czasie rzeczywistym** | Apple Vision + Neural Engine, 8–20 FPS od iPhone 12+ |
| 🚗 **Tryb detekcji tablic** | Regex filtruje europejskie tablice, system "głosowania", cooldown |
| 📋 **Tryb detekcji wszystkiego** | Wyświetla każdy rozpoznany token — do kalibracji i debugowania |
| 🔦 **Wybór obiektywu** | 0.5×, 1×, 2× — live switch, również przez panel web |
| 🌐 **Panel Web** | Dashboard do zarządzania |
| 🗄️ **SQLite** | Lokalna baza danych tablic i logów dostępów wbudowana w aplikację - failover / resilience|
| 🔒 **Blokowanie** | Możliwość zablokowania konkretnych tablic bez konieczności usuwania z systemu |
| 👥 **Flota i AD** | Oznaczanie pojazdów flotowych i przypisywanie pojazdów do userów na domenie |
| 📊 **Logi** | Historia wszystkich detekcji z filtrowaniem i wyszukiwaniem i klatką z momentu wjazdu (detekcji) poprawnej rejestracji|
| ⚡ **Liquid Glass UI** | Natywny design iOS z `.ultraThinMaterial` i glow effects |

---

## 📱 Zrzuty ekranu

<div align="center">

| Status | Logi | Tablice | Ustawienia |
|--------|------|---------|------------|
| Podgląd kamery + stan bramy | Historia detekcji | Zarządzanie bazą | Web server + konfiguracja |

> *Ciemny theme, efekty Liquid Glass, ambient glow na gradientowym tle*

</div>

---

## 🌐 Panel Web

Panel webowy jest **identyczny w wyglądzie** z wersją na Raspberry Pi — ten sam CSS, ta sama logika JavaScript, te same API endpoints.

```
http://<IP-iPhone>:6600
```

> IP i status serwera są zawsze widoczne w zakładce **Ustawienia** aplikacji.

### Zakładki panelu

- **Status** — stan bramy na żywo, metryki OCR, przyciski ręcznego sterowania, symulacja statusów realnej bramy (bez implementacji automatyki)
- **Logi** — tabela wszystkich detekcji z wyszukiwarką  
- **Tablice** — CRUD: dodawanie, edycja, blokowanie tablic  
- **Ustawienia** — tryb OCR, czasy bramy, "głosowanie"

### REST API

| Metoda | Endpoint | Opis |
|--------|----------|------|
| `GET` | `/api/status` | Stan bramy, FPS, ostatnia tablica |
| `GET` | `/api/live_log` | Ostatnie 60 detekcji na żywo |
| `GET` | `/api/log?q=` | Historia z wyszukiwaniem |
| `GET/POST` | `/api/plates` | Lista / dodaj tablicę |
| `PUT/DELETE` | `/api/plates/:id` | Edytuj / usuń |
| `POST` | `/api/plates/:id/toggle_block` | Przełącz blokadę |
| `POST` | `/api/gate/open` | Otwórz bramę |
| `POST` | `/api/gate/close` | Zamknij bramę |
| `GET/POST` | `/api/settings` | Odczyt / zapis ustawień |

---

## 🚀 Instalacja

### Wymagania

- Xcode 15+  
- iPhone z iOS 16+
- (Opcjonalnie) Raspberry Pi jako endpoint kamery USB (testowane na Logitech C922) - iPhone służy do procesingu detekcji


## ⚙️ Konfiguracja

### Tryby OCR

| Tryb | Kiedy używać |
|------|-------------|
| **🔍 Tablica** | Produkcja — filtruje europejskie tablice, otwiera bramę |
| **📋 Wolny** | Kalibracja — pokazuje każdy token z confidence |

### System "głosowania"

Przed otwarciem bramy aplikacja zbiera `minVotes` detekcji tej samej tablicy w oknie `voteWindowSize` klatek. Eliminuje fałszywe odczyty.

```
Domyślnie: 2 głosy w oknie 6 klatek
```

### Czasy bramy

```
ZAMKNIETA → [openingTime]s → OTWARTA → [openDuration]s → [closingTime]s → ZAMKNIETA
Domyślnie:      2s               10s                            3s
```

### Format tablic (regex)

```regexp
[A-Z]{1,3}\d{3,5}[A-Z]{0,2}
```

Obsługuje: `WA12345`, `KR999`, `PO55123AB`, `GD00001` itd.

+ TODO: Obsługa customowych tablic

---

## 🔌 Raspberry Pi — wersja backendowa

GateVision to projekt dual-platform. Wersja na **Raspberry Pi** (Python + Flask + RapidOCR) jest dostępna w katalogu [`gate-app/`](gate-app/).

```bash
# Raspberry Pi setup
sudo apt install -y tesseract-ocr libgl1 libglib2.0-0
pip install flask opencv-python-headless numpy rapidocr-onnxruntime --break-system-packages

cd gate-app
python3 app.py  # → http://<PI-IP>:6600
```

| | iOS App | Raspberry Pi |
|--|---------|-------------|
| **OCR Engine** | Apple Vision (Neural Engine) | RapidOCR (ONNX) |
| **FPS** | 8–20 | 1–3 |
| **GPU/NPU** | ✅ Neural Engine | ❌ (CPU) / ✅ NPU na OPi5 |
| **Web panel** | ✅ Wbudowany :6600 | ✅ Flask :6600 |
| **GPIO** | ❌ | ✅ Pin 17 BCM |
| **Bez zasilania** | ✅ Bateria | ❌ Wymaga prądu |

---

## 📁 Struktura projektu

```
GateVision/
├── GateVisionApp.swift        # Cała aplikacja iOS (single file)
│   ├── Models                 # GateState, PlateEntry, LogEntry, OCRMode, LensType
│   ├── Database               # SQLite wrapper (plates + access_log)
│   ├── WebServer              # NWListener HTTP server + HTML dashboard
│   ├── CameraEngine           # AVFoundation + Vision OCR + gate state machine
│   ├── RootView               # TabView z Liquid Glass background
│   ├── StatusTab              # Kamera + GateCard + MetricTiles
│   ├── LogTab                 # Live log + historia SQLite
│   ├── PlatesTab              # CRUD lista tablic
│   └── SettingsTab            # Web server status + konfiguracja
│
├── gate-app/                  # Raspberry Pi backend
│   ├── app.py                 # Flask + RapidOCR
│   ├── templates/index.html   # Web dashboard
│   ├── requirements.txt
│   └── README.md
│
└── README.md
```

---

## 🛠️ Architektura

```
┌─────────────────────────────────────────────────────┐
│                   iPhone                            │
│                                                     │
│  ┌──────────────┐    ┌─────────────────────────┐    │
│  │ AVFoundation │───▶│    CameraEngine          │   │
│  │  (kamera)    │    │  • VNRecognizeTextReq    │   │
│  └──────────────┘    │  • Vote buffer           │   │
│                      │  • Gate state machine    │   │
│  ┌──────────────┐    │  • SQLite logging        │   │
│  │   SwiftUI    │◀───│                          │   │
│  │  (Liquid     │    └──────────┬──────────────┘    │
│  │   Glass UI)  │               │                   │
│  └──────────────┘    ┌──────────▼──────────────┐    │
│                      │      WebServer          │    │
│  WiFi ─────────────▶ │  NWListener :6600        │   │ 
│                      │  • REST API             │    │ 
│                      │  • HTML dashboard       │    │
│                      └─────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

## 🤝 Contributing

Pull requesty mile widziane! W szczególności:

- Ulepszenia regex dla niestandardowych formatów tablic
- Implementacja GPIO przez network relay (dla iOS → Pi bridge)
- Internacjonalizacja (tablice z innych krajów)
- Obsługa zewnętrznych kamer IP (RTSP stream)
- Optymalizacja wersji Pi

---

## 📄 Licencja

MIT — szczegóły w pliku [LICENSE](LICENSE).

---

<div align="center">

**Made with ❤️ for smart gate automation**

*GateVision używa Apple Vision Framework i nie przesyła żadnych danych poza urządzenie.*

</div>
