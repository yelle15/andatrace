# AndaTrace

**AndaTrace: An Edge-Optimized Nursing Notes Digitalization System Using On-Device Handwritten Text Recognition and Clinical Named Entity Extraction for Anda Riverview Medical Center, Inc.**

* **Authors:** Arielle Eliza Denise R. Aventura, Dreame Adelaine M. Baculio, Sam Adrianne R. Tesoro
* **Institution:** Ateneo de Davao University — School of Arts and Sciences (Computer Studies Cluster)
* **Target Environment:** Anda Riverview Medical Center, Inc. (Davao City, Philippines)

---

## 📌 Repository Information
- **GitHub Repository:** [https://github.com/yelle15/andatrace](https://github.com/yelle15/andatrace)
- **Framework & Libraries:** Flutter (Mobile App UI), LiteRT / TensorFlow Lite (On-device ML), OpenCV (Image Preprocessing), SQLite + PowerSync (Local-first & CRDT Data Sync)

---

## 🔬 System Architecture Overview

AndaTrace is designed as a four-layer local-first pipeline to digitize semi-structured FDAR (Focus, Data, Action, Response) handwritten nursing notes without requiring continuous internet connectivity:

1. **User Interface (UI) Layer (Flutter):** Provides **Capture Path** (camera input) and **Type Path** (manual text/vital entry).
2. **Image Processing Layer (OpenCV):** Cleans scanned images, handles deskewing, lighting adjustment, and tabular grid segmentation.
3. **Local Processing Layer (On-Device AI via LiteRT):**
   - **Seq2Seq HTR Module:** Sequence-to-Sequence model with attention mechanism for transcribing handwritten FDAR notes.
   - **Fine-Tuned BioBERT CNER Module:** Distilled BioBERT model fine-tuned for clinical named entity recognition (medications, dosages, vital signs, intake/output).
   - **Local SQLite Database:** ACID-compliant local storage ensuring zero data loss offline.
4. **Synchronization Layer (PowerSync):** Background Delta-Sync engine that automatically synchronizes local SQLite records with the central backend (Supabase) once internet connectivity is restored.

---

## 🛠️ Prerequisites & Requirements

Before running or building the project, ensure your environment meets the following requirements:

- **Flutter SDK:** `>=3.12.2` (or Dart SDK compatible with Flutter 3.27+)
- **Android SDK:** API Level 24+ (Android 7.0 or higher) / **iOS:** iOS 13+
- **Git**
- **Android Studio** or **VS Code** with Flutter and Dart plugins installed.

To verify your environment setup, run:
```bash
flutter doctor
```

---

## 🚀 Installation & Setup

1. **Clone the Repository:**
   ```bash
   git clone https://github.com/yelle15/andatrace.git
   cd andatrace
   ```

2. **Install Dependencies:**
   ```bash
   flutter pub get
   ```

---

## 💻 Minimal Working Example (MWE) & Reproducibility

### Option 1: Running Automated Unit & Model Interface Tests
To test the core app features, layout parsing, and mock model pipelines without needing a physical device or emulator:
```bash
flutter test
```

### Option 2: Running the Application Locally
To launch the AndaTrace application on a connected Android/iOS device, emulator, or desktop browser:

1. **List Available Target Devices:**
   ```bash
   flutter devices
   ```

2. **Run the App:**
   ```bash
   flutter run -d <device_id>
   ```
   *(Example: `flutter run -d chrome` or `flutter run -d emulator-5554`)*

---

## 📁 Repository Structure

```text
andatrace/
├── android/              # Native Android configurations & LiteRT bindings
├── ios/                  # Native iOS configurations
├── lib/                  # Flutter application source code
│   ├── main.dart         # Entry point
│   ├── processing/       # OpenCV & LiteRT model integration
│   ├── database/         # Local SQLite & PowerSync sync logic
│   └── ui/               # Image Capture & FDAR entry views
├── test/                 # Unit tests & reproducibility verification scripts
├── pubspec.yaml          # Project dependencies
└── README.md             # Project documentation & instructions
```

---

## 📊 Evaluation & Metrics (Thesis Objectives)
- **HTR Accuracy:** Evaluated using Character Error Rate (CER) and Word Error Rate (WER).
- **CNER Performance:** Measured via Precision, Recall, and F1-Score on localized clinical entities.
- **Latency & Model Efficiency:** On-device end-to-end inference latency (seconds/note) and TFLite quantized model size (MB).
- **System Quality:** Assessed using the FURPS model (System Usability Scale and Task Success Rate).
