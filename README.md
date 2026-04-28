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
[![CoreML](https://img.shields.io/badge/CoreML-YOLO-purple?style=flat-square&logo=apple)](https://developer.apple.com/machine-learning/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

<br/>

<img src="https://img.shields.io/badge/Apple%20Vision-Neural%20Engine-purple?style=for-the-badge&logo=apple" />
<img src="https://img.shields.io/badge/CoreML-YOLO%20Detection-9B4DFF?style=for-the-badge&logo=apple" />
<img src="https://img.shields.io/badge/Web%20Panel-port%206600-00D4FF?style=for-the-badge&logo=googlechrome&logoColor=white" />

</div>

---

## Czym jest GateVision?

**GateVision** to system automatycznej kontroli bramy wjazdowej. Aplikacja iOS w czasie rzeczywistym rozpoznaje tablice rejestracyjne, porównuje je z bazą danych i automatycznie steruje bramą. Wykorzystuje **CoreML** (model YOLO wytrenowany na tablicach) do detekcji regionów tablic oraz **Apple Vision Framework** do odczytu tekstu (OCR).

W tle działa **serwer HTTP** (port 6600) z pełnym panelem webowym do zarządzania systemem z dowolnego urządzenia w sieci lokalnej.

```
Źródło obrazu (iPhone / Raspberry Pi / 70mai)
      │
      ├── 🧠  CoreML YOLO → Detekcja regionu tablicy → Crop → Vision OCR → Odczyt tekstu
      │
      ├── 🗄️  SQLite → Sprawdzenie tablicy w bazie → Otwarcie/blokada bramy
      │
      └── 🌐  HTTP :6600 → Panel webowy (status, logi, zarządzanie, debug)
```

---

## Tryby detekcji

GateVision oferuje trzy tryby rozpoznawania tablic:

| Tryb | Silnik | Opis |
|------|--------|------|
| **Pełna klatka** | Apple Vision OCR | OCR na całym obrazie — prosty, bez ML, dobre na krótki dystans |
| **YOLO ML** | CoreML + Vision wrapper | Model YOLO wykrywa region tablicy, obraz jest wycinany i wysyłany do OCR — lepsza skuteczność na dalszy dystans |
| **CoreML Direct** | CoreML bezpośrednio | Ten sam model YOLO, ale z ręcznym preprocessingiem (resize 640×640, CVPixelBuffer) i bezpośrednim `MLModel.prediction()` — pełna kontrola, przydatne do debugowania |

### Pipeline detekcji (tryby ML)

```
Klatka z kamery (portrait)
    │
    ├── CoreML YOLO → bounding boxy tablic (normalized coords)
    │
    ├── Crop + padding + upscale (min 150px) → wycięty region tablicy
    │
    ├── Apple Vision OCR (.accurate) → tekst tablicy + confidence
    │
    ├── Regex filter → [A-Z]{1,3}\d{3,5}[A-Z]{0,2}
    │
    └── System głosowania (N detekcji w oknie M klatek) → decyzja o otwarciu bramy
```

---

## Funkcje

### Detekcja i OCR
- **3 tryby detekcji** — Pełna klatka, YOLO ML, CoreML Direct
- **2 tryby OCR** — Tablica (filtruje rejestracje, steruje bramą) / Wszystko (wyświetla cały tekst — do kalibracji)
- **System głosowania** — wymaga N powtórzeń tej samej tablicy w oknie M klatek przed otwarciem bramy
- **Cooldown** — zapobiega wielokrotnemu otwarciu na tę samą tablicę

### Źródła kamery
- **iPhone** — wbudowana kamera z wyborem obiektywu (0.5×, 1×, 5×)
- **Raspberry Pi** — MJPEG stream po HTTP z kamery USB podłączonej do Pi
- **70mai** — dashcam przez RTSP stream

### Rozdzielczość kamery
- **720p** (1280×720) — niska latencja, mniejsze zużycie baterii
- **1080p** (1920×1080) — balans jakości i wydajności
- **4K** (3840×2160) — maksymalny zasięg detekcji

### Baza danych (SQLite)
- Lista autoryzowanych tablic z danymi właścicieli
- Oznaczanie pojazdów flotowych i przypisywanie do użytkowników (AD)
- Blokowanie/odblokowywanie tablic bez usuwania z systemu
- Pełna historia detekcji z klatką z momentu rozpoznania (JPEG snapshot)

### Sterowanie bramą
- Automat stanowy: ZAMKNIĘTA → OTWIERANIE → OTWARTA → ZAMYKANIE → ZAMKNIĘTA
- Konfigurowalne czasy otwierania, otwarcia i zamykania
- Ręczne sterowanie z aplikacji i panelu web

### Panel webowy (port 6600)
- **Status** — stan bramy, metryki OCR, podgląd kamery live (MJPEG stream), przyciski sterowania
- **Logi** — tabela detekcji z wyszukiwarką i podglądem zdjęć
- **Tablice** — dodawanie, edycja, blokowanie, usuwanie tablic
- **Ustawienia** — tryb OCR, tryb detekcji, źródło kamery, rozdzielczość
- **Debug** — diagnostyka OCR, info o kamerze, baza danych, logi ML z toggle/clear/copy

### Debug i diagnostyka
- **MLLogger** — szczegółowe logi pipeline'u ML w czasie rzeczywistym
- **Debug ML** — przechwytywanie wyciętych regionów tablic ze wszystkich detekcji ML (nie tylko zmatchowanych)
- **Debug tab** — diagnostyka OCR, parametry kamery, stany bramy, testy sterowania
- **Loading screen** — wizualizacja inicjalizacji (baza, model ML, kamera, serwer)

---

## Panel Web — REST API

```
http://<IP-iPhone>:6600
```

| Metoda | Endpoint | Opis |
|--------|----------|------|
| `GET` | `/` | Dashboard HTML |
| `GET` | `/api/status` | Stan bramy, FPS, ostatnia tablica, źródło kamery |
| `GET` | `/api/snapshot` | Aktualna klatka JPEG |
| `GET` | `/api/stream` | MJPEG stream (podgląd live) |
| `GET` | `/api/live_log` | Ostatnie 60 detekcji na żywo |
| `GET` | `/api/log?q=` | Historia detekcji z wyszukiwaniem |
| `GET` | `/api/log/:id/snapshot` | Klatka JPEG z danego logu |
| `GET/POST` | `/api/plates` | Lista / dodaj tablicę |
| `PUT/DELETE` | `/api/plates/:id` | Edytuj / usuń tablicę |
| `POST` | `/api/plates/:id/toggle_block` | Przełącz blokadę |
| `POST` | `/api/gate/open` | Otwórz bramę |
| `POST` | `/api/gate/close` | Zamknij bramę |
| `GET/POST` | `/api/settings` | Odczyt / zapis ustawień (tryb OCR, detekcja, kamera, rozdzielczość) |
| `GET` | `/api/debug` | Pełna diagnostyka (OCR, kamera, brama, ML logi, baza) |
| `POST` | `/api/ml_log/toggle` | Włącz/wyłącz logowanie ML |
| `POST` | `/api/ml_log/clear` | Wyczyść logi ML |

---

## Instalacja

### Wymagania

- Xcode 15+
- iPhone z iOS 16+ (zalecany iPhone 12+ dla Neural Engine)

### Build

1. Sklonuj repo
2. Otwórz `Gatevision.xcodeproj` w Xcode
3. Build & Run (Cmd+R) na urządzeniu fizycznym (kamera nie działa w symulatorze)

Model ML (`trained_plates_detection.mlpackage`) jest dołączony do repo — Xcode kompiluje go automatycznie do `.mlmodelc` przy buildzie.

---

## Konfiguracja

### Tryby OCR

| Tryb | Kiedy używać |
|------|-------------|
| **Tablica** | Produkcja — filtruje europejskie tablice, steruje bramą |
| **Wszystko** | Kalibracja — pokazuje każdy rozpoznany tekst z confidence |

### System głosowania

Przed otwarciem bramy aplikacja zbiera `minVotes` detekcji tej samej tablicy w oknie `voteWindowSize` klatek. Eliminuje fałszywe odczyty.

```
Domyślnie: 2 głosy w oknie 6 klatek
```

### Czasy bramy

```
ZAMKNIĘTA → [openingTime]s → OTWARTA → [openDuration]s → [closingTime]s → ZAMKNIĘTA
Domyślnie:       2s               10s                          3s
```

### Format tablic (regex)

```regexp
[A-Z]{1,3}\d{3,5}[A-Z]{0,2}
```

Obsługuje: `WA12345`, `KR999`, `PO55123AB`, `GD00001` itd.

---

## Architektura

Cała aplikacja iOS mieści się w jednym pliku (`GateVisionApp.swift`) — single-file architecture.

```
┌──────────────────────────────────────────────────────────────┐
│                        iPhone                                │
│                                                              │
│  ┌─────────────────┐     ┌────────────────────────────────┐  │
│  │  Źródło kamery   │────▶│         CameraEngine          │  │
│  │  • iPhone cam    │     │  • CoreML YOLO detekcja       │  │
│  │  • Raspberry Pi  │     │  • Apple Vision OCR           │  │
│  │  • 70mai RTSP    │     │  • System głosowania          │  │
│  └─────────────────┘     │  • Automat stanowy bramy      │  │
│                           │  • SQLite logging             │  │
│  ┌─────────────────┐     │                                │  │
│  │    SwiftUI UI    │◀────│  @Published properties        │  │
│  │  • Status tab    │     └───────────────┬───────────────┘  │
│  │  • Logi tab      │                     │                  │
│  │  • Tablice tab   │     ┌───────────────▼───────────────┐  │
│  │  • Settings tab  │     │          WebServer            │  │
│  │  • Debug tab     │     │  NWListener :6600             │  │
│  └─────────────────┘     │  • REST API (JSON)            │  │
│                           │  • HTML dashboard             │  │
│  WiFi ──────────────────▶│  • MJPEG stream               │  │
│                           └───────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Struktura plików

```
Gatevision/
├── GateVisionApp.swift                    # Cała aplikacja iOS (single file)
│   ├── Enums                              # GateState, DetectionMode, OCRMode, CameraSource,
│   │                                      #   LensType, CameraResolution, LoadStep
│   ├── DebugMLEntry                       # Model danych debug ML
│   ├── Design System (GV)                 # Kolory, Liquid Glass modifiers
│   ├── Database                           # SQLite wrapper (plates + access_log + snapshots)
│   ├── MLLogger                           # Logger pipeline'u ML
│   ├── WebServer                          # NWListener HTTP + REST API + dashboard
│   ├── CameraEngine                       # AVFoundation + CoreML + Vision OCR + gate FSM
│   │   ├── captureOutput                  # Przetwarzanie klatek z iPhone
│   │   ├── handleExternalFrame            # Przetwarzanie klatek z Pi/70mai
│   │   ├── runCoreMLDetection             # YOLO ML (via Vision wrapper)
│   │   ├── runDirectCoreMLDetection       # CoreML Direct (manual preprocessing)
│   │   └── ocrCroppedRegions              # Crop + OCR na wyciętych regionach
│   ├── SplashScreen                       # Loading screen z progress bar
│   ├── RootView                           # TabView z 5 zakładkami
│   ├── StatusTab                          # Kamera live + GateCard + metryki
│   ├── LogTab                             # Aktualna sesja + Historia + Debug ML
│   ├── PlatesTab                          # CRUD lista tablic
│   ├── SettingsTab                        # Konfiguracja + Debug nawigacja
│   ├── DebugTab                           # Diagnostyka, czasy bramy, ML logi, testy
│   └── MLLogView                          # Przeglądarka logów ML
│
├── dashboard.html                         # Panel webowy (HTML/CSS/JS)
├── trained_plates_detection.mlpackage     # Model CoreML YOLO (detekcja tablic)
└── trained_plates_detection.pt            # Model PyTorch (źródło)
```

---

## Licencja

MIT — szczegóły w pliku [LICENSE](LICENSE).

---

<div align="center">

**Made with ❤️ for smart gate automation**

*GateVision przetwarza wszystko lokalnie na urządzeniu — żadne dane nie są wysyłane na zewnątrz.*

</div>
