# LevelUP

An installable iPhone web app for the Distinguished Engineer Knowledge Library, a feed of AI blogs, and a Read Later list.

- **Library**: 22 volumes in 5 parts (`content/vol-NN.md`, listed in `content/catalog.json`). Reader with text size, serif/sans, light/sepia/dark, saved reading position, tappable review checklists, and a Design Principles deck pulled from every volume.
- **Search**: full-text across volumes, principles, saved articles and Read Later, offline.
- **AI Feeds**: blogs in `feeds.config.json` plus hot AI stories from Hacker News, fetched every 3 hours. "Save" keeps the full text on the phone.
- **Read Later**: an iOS Shortcut on Safari's share sheet files the page as a `read-later` issue; the workflow extracts a readable copy and the app keeps it offline. Setup steps are in the app (Read Later → Set up the Shortcut).

## Install on iPhone
Open the Pages URL in Safari → Share → **Add to Home Screen**.

## Add or edit a volume
Write `content/vol-NN.md` using the same H2 sections as the existing volumes (Overview, Core Concepts, Design Principles, Trade-offs and Decision Frameworks, Failure Modes and War Stories, What a DE Probes, Review Checklist, Further Reading) and push. The workflow rebuilds and republishes.

## Local
```
npm install
npm run build      # content -> app/data/library.json
npm run feeds      # app/data/feeds.json
npm run serve      # http://localhost:8080
```

## One-time GitHub setup
Settings → Pages → Source: **GitHub Actions**. Every issue in this repo that contains a link is treated as a Read Later item.
