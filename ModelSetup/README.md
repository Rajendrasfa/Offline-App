# AskMe Option 2 Offline Model Setup (`Qwen2.5-1.5B-Instruct`)

AskMe keeps the Android APK lightweight and privacy-strict (zero `INTERNET` permission).  
Use this standalone **Option 2 Model Setup** to prepare a verified Hindi + English GGUF model (`Qwen2.5-1.5B-Instruct`, Apache-2.0) and import it once into the AskMe app.

---

## Option A: Windows 1-Click Setup (PC -> Phone)

1. Double-click **`Download_Option2_Model.bat`** in this folder.
2. Select quantization:
   - **`[1] Q4_K_M` (~1.04 GB)** — Recommended (Best Hindi, Hinglish & English accuracy)
   - **`[2] Q3_K_M` (~824 MB)** — Balanced smaller download
   - **`[3] Q3_K_S` (~761 MB)** — Compact 1.5B option
3. The script downloads the `.gguf` file into `ModelSetup/output/`, verifies its **24-byte GGUF v2/v3 header**, generates a `.sha256` checksum file, and automatically pushes to `/sdcard/Download/` if your Android phone is connected via USB (`adb`).
4. Otherwise, copy the `.gguf` file from `ModelSetup/output/` to your phone's **`Downloads`** folder via USB cable.

---

## Option B: Download Directly on Your Phone

Open Chrome on your Android phone and download the official Apache-2.0 model file:
- **Q4_K_M (~1.04 GB, Recommended):**
  `https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf`

---

## Option C: Download Packaged Artifact via GitHub Actions

1. Open GitHub Actions -> **Build Option 2 Model Package** workflow.
2. Click **Run workflow** and choose `q4_k_m`, `q3_k_m`, or `q3_k_s`.
3. Download **`AskMe-Option2-Model-Package`** from Artifacts, extract the `.gguf` file, and copy it to your phone's `Downloads` folder.

---

## Import into AskMe App

1. Open **AskMe**.
2. Tap **`Import Model`** in the top bar (or **`Import`** in the banner).
3. Browse to **`Downloads`** and select the `.gguf` file.
4. Wait for the progress bar to finish verifying the file (top bar turns green: **`Model Ready`**).
5. Turn on **Airplane Mode** and start chatting or asking about your scanned documents!
