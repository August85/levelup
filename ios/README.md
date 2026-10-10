# LevelUP for iPhone (native)

A SwiftUI app with the same content as the web app: the Library (volumes plus companion notes),
Design Principles, Algorithms, Review Mode, offline search, AI Feeds with Save, and Read Later.
A Safari share extension ("LevelUP" in the share sheet) files any page into Read Later and the app
keeps an offline copy of it.

Content comes from `app/data/*.json`. A copy ships inside the app, and on launch the app fetches
the latest from https://august85.github.io/levelup/data/ (feeds refresh there every 3 hours).

## Build on your Mac

1. Install Xcode 16 or later and XcodeGen: `brew install xcodegen`
2. Generate the project: `cd ios && xcodegen` then `open LevelUP.xcodeproj`
3. In Xcode, select each target (LevelUP and ShareExtension), open **Signing & Capabilities**,
   and choose your team. Keep "Automatically manage signing" on. Xcode registers both bundle IDs
   (`com.august85.levelup`, `com.august85.levelup.share`) and the App Group
   `group.com.august85.levelup` for you. If an ID is taken, change the prefix in `project.yml`
   and in `Shared/SharedQueue.swift` (`groupID`), then run `xcodegen` again.
4. Plug in your iPhone, pick it as the run destination, and press Run.

## TestFlight and the App Store

1. In App Store Connect, create a new app with bundle ID `com.august85.levelup`.
2. In Xcode choose **Any iOS Device**, then **Product > Archive**.
3. In the Organizer, **Distribute App > App Store Connect > Upload**.
4. The build appears in TestFlight after processing; add yourself as an internal tester and
   install it with the TestFlight app. For the App Store, fill in the listing, screenshots and
   privacy details (the app collects no data), then submit for review.

Bump `CURRENT_PROJECT_VERSION` in `project.yml` for each upload.

## CI

`.github/workflows/ios.yml` builds the app for the simulator on every change under `ios/`,
without signing, so compile errors show up before you open Xcode.
