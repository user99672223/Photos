# PhotoVault

Private, encrypted Google-Photos-style iOS app. Originals live only in STRATO HiDrive, encrypted client-side.

**HiDrive app:** register one at developer.hidrive.com as type "native" with redirect URI "oob". On first launch PhotoVault asks for its client id and secret (change them later under Settings → API credentials); they stay in the iPhone's Keychain and are never part of a build.
**Sign-in:** after you log in and allow access, HiDrive shows a short code. Copy it and paste it into the app within 5 minutes.
**Backup:** automatic backup is off by default. When on, it only considers photos taken after the cutoff date (Settings → Backup rules). Back up other items by hand with a day header's "Back up" button or from multi-select.
**IPA:** GitHub Actions → "Build unsigned IPA" → artifact `PhotoVault-unsigned.ipa` (kept 30 days). Sign and install it with AltStore or Sideloadly. Decrypt blobs offline with `tools/pv_decrypt.py`.

## Google Takeout import
`tools/pv_import.py` copies a Google Photos Takeout from Google Drive into the vault as one more device; the ZIPs are range-read, never downloaded, and the app merges the result on its next sync.
- **Prereqs (Debian):** `sudo -v; curl https://rclone.org/install.sh | sudo bash`, `sudo apt install ffmpeg`, then `python3 -m venv ~/pv-venv && . ~/pv-venv/bin/activate && pip install -r tools/requirements.txt`.
- **Remotes:** `rclone config` → `gdrive` (Google Drive, scope `drive.readonly`) and `hidrive` (STRATO HiDrive); `hidrive:PhotoVault` is the app's vault folder.
- **1. Plan:** `python tools/pv_import.py plan --source gdrive:Takeout --state ~/pv-import` lists folders, album copies, sidecars and the upload size.
- **2. Trial:** `python tools/pv_import.py run --source gdrive:Takeout --dest hidrive:PhotoVault --state ~/pv-import --limit 20`, then sync the app and check.
- **3. Import:** the same command without `--limit` (resumable; Ctrl-C stops after the current file), then `python tools/pv_import.py verify --dest hidrive:PhotoVault --state ~/pv-import`.
- `~/pv-import` holds `state.sqlite`, `staging/` and `pv_import.log`. The recovery string is prompted for (or `--recovery-file` with mode 600).
