# PhotoVault

Private, encrypted Google-Photos-style app for iOS. Originals live only in STRATO HiDrive, encrypted client-side.

**Secrets:** register an app at developer.hidrive.com (redirect `photovault://oauth`), then add repo secrets
`HIDRIVE_CLIENT_ID` and `HIDRIVE_CLIENT_SECRET` (Settings → Secrets and variables → Actions).
If the secrets are missing, the app asks for the credentials during onboarding instead.

**IPA:** GitHub Actions → "Build unsigned IPA" → artifact `PhotoVault-unsigned.ipa` (30-day retention).
Sign and install with AltStore or Sideloadly. Recovery tooling: `tools/pv_decrypt.py`.
