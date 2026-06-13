# ManualCam — Install Guide (Windows, No Mac, No $99)

## What you need
- A Windows PC
- An iPhone
- A free Apple ID (apple.com)
- A USB cable

---

## Overview

```
Step 1: Push code to GitHub
Step 2: GitHub Actions builds unsigned .ipa (free, automatic)
Step 3: AltServer on Windows signs it with your Apple ID
Step 4: AltStore on iPhone installs it
```

---

## Step 1 — Create GitHub repository

1. Go to github.com → sign in (or create free account)
2. Click **New repository**
   - Name: `ManualCam`
   - Visibility: **Private**
   - Click **Create repository**
3. On the next page click **uploading an existing file**
4. Drag ALL files from this folder into the upload area
   - Make sure `.github/workflows/build.yml` is included
   - (enable "show hidden files" in Windows Explorer: View → Hidden items)
5. Click **Commit changes**

The build starts automatically. Skip to Step 2.

---

## Step 2 — Wait for the build (~10 minutes)

1. In your GitHub repo click the **Actions** tab
2. You'll see "Build iOS IPA (Unsigned)" running (yellow circle)
3. Wait for it to turn green ✅
4. Click the completed run
5. Scroll to the bottom → **Artifacts** → click **ManualCam-Unsigned-IPA**
6. A zip downloads — unzip it to get `ManualCam-unsigned.ipa`

If the build fails (red ✗), click it and read the error log —
most common cause is Xcode version mismatch, which I can fix.

---

## Step 3 — Install AltServer on Windows

AltServer signs and installs the app using your Apple ID for free.

1. Go to **altstore.io** → Download AltServer for Windows
2. Install it (requires iTunes and iCloud — it will prompt you)
3. If you don't have iTunes: download from **apple.com/itunes**
   ⚠️ Use the apple.com version, NOT the Microsoft Store version
4. If you don't have iCloud: download from **apple.com/icloud/icloud-for-windows**
5. Restart Windows after installing iTunes and iCloud

---

## Step 4 — Install AltStore on iPhone

1. Plug your iPhone into your Windows PC via USB
2. On iPhone: tap **Trust** when asked, enter your passcode
3. Open AltServer from the system tray (bottom-right, small diamond icon)
4. Click AltServer icon → **Install AltStore** → select your iPhone
5. Enter your Apple ID email and password when prompted
   (AltServer never stores these — they go directly to Apple)
6. On iPhone: **Settings → General → VPN & Device Management
   → [your Apple ID] → Trust**
7. AltStore app now appears on your iPhone home screen

---

## Step 5 — Install ManualCam via AltStore

### Option A — via AltServer on PC (easiest)
1. Make sure iPhone is connected via USB (or on same Wi-Fi after first setup)
2. Click AltServer tray icon → **Sideload .ipa**
3. Select `ManualCam-unsigned.ipa`
4. Done — ManualCam appears on your iPhone

### Option B — via AltStore on iPhone directly
1. Open AltStore on iPhone → **My Apps** tab → **+** button
2. You need the .ipa accessible from your iPhone
   (AirDrop it from a Mac, or use a cloud service like iCloud/Dropbox)

---

## Keeping the app alive (important!)

Apple's free tier expires apps every **7 days**.
AltStore re-signs automatically when:
- Your iPhone and PC are on the **same Wi-Fi**
- AltServer is running in the background on your PC

To force a refresh: open AltStore on iPhone → My Apps → swipe down to refresh.

---

## Troubleshooting

**"Maximum number of app IDs reached"**
Free Apple ID is limited to 10 app IDs per 7 days.
Go to developer.apple.com → Certificates → Identifiers → delete old ones.

**Build failed in GitHub Actions**
Click the failed run → expand the "Build unsigned .app" step → read the error.
Common fixes:
- Wrong scheme name → check ManualCam.xcodeproj is in the root folder
- Xcode version → edit build.yml, change `Xcode_15.4` to `Xcode_15.2`

**AltStore says "Could not find AltServer"**
- Make sure AltServer is running (check system tray)
- Try USB instead of Wi-Fi
- Restart AltServer

**App crashes on launch**
This usually means a code signing issue.
Re-sideload the .ipa through AltServer.
