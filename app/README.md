# OctoSnap Booth

Professional photobooth app for **live fridge magnets** (Flutter — Android + Windows now, iOS/macOS later).

Operator flow (mirrors LumaBooth): Events → Create event → Welcome screen → Photo layout → Capture settings → Camera settings → Print setup → Launch booth.

* Photo layout editor: paper 4x6, 6x4, 2x6, 4x4, 4x8, 5x7, 6x6, 6x8, 6x9, A6, A5, A4, custom; full-sheet template PNG overlay; photo boxes with drag/resize, W/H/X/Y/rotate and photo numbers (six 2x2 boxes with number 1 = six magnets of one shot); text ({event}, {date}) and logos.
* Booth: welcome → countdown → flash → review (retake/keep) → 300 DPI sheet → print (auto print + copies).
* Everything is saved on the device (events.json + imported assets).

Builds: GitHub Actions (`.github/workflows/build.yml`) produces the Android APK and the Windows app and attaches them to a GitHub Release.

Phase 2: Canon EOS R10 over USB-C (Android USB Host + PTP, Windows Canon EDSDK), GIF/boomerang, QR/WhatsApp sharing.
