# PhotoVault

Private, encrypted Google-Photos-style iOS app. Originals live only in STRATO HiDrive, encrypted client-side.

**HiDrive app:** register one at developer.hidrive.com as type "native" with redirect URI "oob". On first launch PhotoVault asks for its client id and secret (change them later under Settings → API credentials); they stay in the iPhone's Keychain and are never part of a build.
**Sign-in:** after you log in and allow access, HiDrive shows a short code. Copy it and paste it into the app within 5 minutes.
**Backup:** automatic backup is off by default. When on, it only considers photos taken after the cutoff date (Settings → Backup rules). Back up other items by hand with a day header's "Back up" button or from multi-select.
**Rebuild local index** (Settings → Maintenance): wipes the local index and thumbnail cache on the phone and re-downloads the journal; key, sign-in and settings are kept.
**Diagnostics** (Settings): asset and section counts, thumbnail cache fill, last sync time, queue sizes and index/timeline build times, refreshed when the screen appears.
**IPA:** GitHub Actions → "Build unsigned IPA" → artifact `PhotoVault-unsigned.ipa` (kept 30 days). Sign and install it with AltStore or Sideloadly. Decrypt blobs offline with `tools/pv_decrypt.py`.
