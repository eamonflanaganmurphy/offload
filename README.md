# Offload

An iPhone app that uploads photos and videos from a camera's SD card, plugged into the phone, straight to
[Immich](https://immich.app). Nothing goes into the photo library and nothing stays on the phone.

- **What's new:** every file on the card is hashed and checked against Immich, newest first, so each
  thumbnail shows whether Immich already has it, whether it came from this phone, the card reader at home or
  anywhere else. Hashes are kept, so a card that's been checked before is done in a second.
- **Pick or take everything:** tap photos, or a day's **Select**, to send just those. With nothing picked,
  **Upload New** sends everything Immich doesn't have. Long-press a photo to preview it. RAW files and videos are
  badged.
- **In the background:** uploads go through iOS's background transfer service, so they carry on with the phone
  locked or Offload closed. A background upload has to come from a file, so Offload copies each file off the card
  first, hashing it on the way. It only copies 1.5 GB ahead of the uploads, and deletes each copy once Immich
  has the file. If iOS stops Offload, the rest of the queue carries on when you open it again with the card
  still plugged in.
- **Albums:** a card's shoot goes into an album named after its dates, e.g. `SD import 2026-09-28` or
  `SD import 2026-09-28 to 2026-10-02`. That's the name the homelab's `sdcard-import` pipeline gives it, so a card
  started on the phone and finished at home ends up in one album. Files in the card's `.Trashes` (photos
  deleted on a Mac but never emptied) are shown separately, aren't in Upload New, and never go in the album.
  To put every card in one album of your own instead, type its name under **Album Name** in Settings (it's made in
  Immich if there isn't one); clear the name to go back to the dates. **Add to an Album** turns albums off.
- **Wi-Fi only:** turn on **Wi-Fi Only** in Settings and uploads wait for Wi-Fi instead of using mobile data,
  then carry on by themselves, in the background too, once there's Wi-Fi again. Uploads already under way when
  it's switched start again under the new rule.
- **Nothing is deleted:** Offload only reads the card. Wipe it with the camera, or put it in the card reader at
  home, which backs it up and checks it before it deletes anything.

It skips the same junk as the pipeline (`.Spotlight-V100`, `.fseventsd`, `._*` files and the like) and
asks Immich which file types it accepts, so RAW formats and video containers stay in step with the server.

## Install with SideStore

[SideStore](https://sidestore.io) re-signs apps with your Apple ID and refreshes them from the phone.

1. In SideStore, open **Sources** → **+** and add
   `https://github.com/eamonflanaganmurphy/offload/releases/latest/download/source.json`
2. Open the Offload source and tap **Get**.

Every push to `main` that builds and passes the tests is released as a new version, and SideStore offers it
under **My Apps** → **Updates**. A free Apple ID allows 3 sideloaded apps at once, and SideStore itself uses one
of them.

To install a local build instead, run `./scripts/build-ipa.sh` on a Mac, AirDrop `build/Offload.ipa` to the
iPhone, and pick it in SideStore under **My Apps** → **+**.

## Set up

Offload needs the server's address and an API key. Make the key in Immich under **Account Settings → API Keys →
New API Key**, with these permissions:

- `asset.upload`
- `album.read`
- `album.create`
- `albumAsset.create`

Then either type both into Offload's Settings (the gear), or open a setup link on the phone, which fills them in:

```
offload://setup?server=https://photos.example.com&key=YOUR_KEY
```

**Test Connection** checks the key has every permission it needs.

## Use

1. Plug the card reader into the iPhone and open Offload.
2. Tap **Choose Card**. The card is under **Locations** in the Files browser: open it and tap **Open**. Offload
   reopens the same card by itself next time it's plugged in.
3. Wait for the check, or don't: files not yet checked are checked just before they're sent.
4. Tap **Upload New**, or pick photos first and tap **Upload Selected**.

The screen stays on while uploading (turn that off in Settings). That's the quickest way: with the screen off,
the uploads already copied off the card carry on, and the rest waits for Offload to be opened again.

## Building

`project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. On a Mac:

```sh
brew install xcodegen
xcodegen
open Offload.xcodeproj
```

Everything that isn't UI or the background session (scanning the card, hashing, the upload body and the Immich
API) is in the `OffloadCore` package, which builds and tests on Linux too:

```sh
cd Packages/OffloadCore
swift test
```

`offloadcheck` runs the same code against a folder, a card or a copy of one, and can upload from it, with the
exact request the app sends:

```sh
IMMICH_URL=https://photos.example.com IMMICH_API_KEY=... \
  swift run offloadcheck /Volumes/CARD [--upload N] [--album]
```

CI (`.github/workflows/build.yml`) runs the tests and builds the unsigned IPA on a macOS runner on every push to
`main`. The logs are also pushed to the `ci-logs` branch.
