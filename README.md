# Koda for iPhone

A native SwiftUI port of [Koda](https://github.com/ahmadmdm/Koda) (Android) for iOS 26.1+, built with Liquid Glass:
a glass tab bar that shrinks on scroll, a mini player in the tab bar's bottom accessory, a search tab, glass buttons and
containers, and a zoom transition into the player.

## Build and run

Open `Koda.xcodeproj` in Xcode 26 or newer and run the `Koda` scheme, or:

```bash
xcodebuild -project Koda.xcodeproj -scheme Koda -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

No API key, no account. One Swift package: Google's Cast SDK (`github.com/googlecast/google-cast-ios-sdk`,
`GoogleCastDynamic`, pinned in `Package.resolved`), which Xcode fetches on the first build.

### On an iPhone

The project is set up for team `45N44SDC38` with the identifier prefix `KODA_ID_PREFIX = com.koda.ios.t45n44`
(`com.koda.ios` belongs to another team). The App IDs `com.koda.ios.t45n44` and `.widget` and the App Group
`group.com.koda.ios.t45n44` are registered on developer.apple.com, so choosing the iPhone in Xcode and pressing Run works,
or:

```bash
xcodebuild -project Koda.xcodeproj -scheme Koda -destination 'id=<device UDID>' -derivedDataPath build/device -allowProvisioningUpdates build
xcrun devicectl device install app --device <device UDID> build/device/Build/Products/Debug-iphoneos/Koda.app
```

To install on a friend's iPhone: connect it with a cable, unlock it, tap Trust, turn on Settings › Privacy & Security ›
Developer Mode, then run `./install-on-iphone.sh`. It registers the phone in the developer account (up to 100 iPhones a
membership year), builds, installs and opens Koda.

A development build keeps running until the signing certificate or the provisioning profile expires (each is valid for
a year; Xcode renews them while the membership is active). Then build and install again.

**CarPlay** (`com.apple.developer.carplay-audio`) has to be granted to the team by Apple
(https://developer.apple.com/contact/carplay/). Until then `Koda.entitlements` leaves it out: Koda shows in CarPlay's
Now Playing and answers the car's play, pause, next and previous buttons, but has no CarPlay icon or screens of its own.
Once granted, set `CODE_SIGN_ENTITLEMENTS = KodaCarPlay.entitlements` on the Koda target.

## What's included

**Music:** YouTube Music home with continuation, Quick picks (radio from your last song), Speed dial, Spin, Listen again,
taste onboarding, the Your Mix and Spotlight layouts. Search across songs, videos, albums, artists and playlists, with
suggestions, history and voice search. Album, playlist and artist pages. A shared queue with play next, add to queue, reorder,
swipe to remove, an autoplay radio, and saving the queue as a playlist. Shuffle and repeat that persist, and session restore.
Six player styles (Classic, Hero, Editorial, Canvas, Bento, Dial); long-press the artwork to switch. Double-tap either side
of the artwork to seek. Synced lyrics (LRCLIB, with YouTube Music as the fallback) with timing offset, size control and
right-to-left alignment. Playback speed, sleep timer, volume normalisation, AirPlay, lock-screen and Control Center controls,
and background audio. Likes, device playlists (rename, reorder, sort, cover colour, CSV import and export), saved albums
and followed artists. Ranged downloads for offline playback.

**Statistics:** History, Statistics (charts by hour and by artist) and Recap (minutes, top song, regulars, your hour, and a
record with one ring per day), shareable as an image.

**Video:** a home feed with explore topics (For You is built from related videos of your watch history) and Continue watching.
Search for videos, channels and playlists, with sort options. The watch page uses HLS up to 2160p with a quality cap,
Picture in Picture, AirPlay, speeds, chapters, SponsorBlock, resume positions, autoplay of the next video, comments with
tappable timestamps, and a description with links. Channel pages with search and sort. Local subscriptions with a feed
built from the channels' RSS, filtered by channel and upload age. Watch Later, liked videos, history, "Not interested"
and blocking a channel. Shorts: a shelf on Home and on channel pages, and a full-screen swipe pager (its own looping
AVPlayer per Short, mute, like, subscribe, comments, share) fed by the reel sequence; `youtube.com/shorts/` links open it.
Live chat (and chat replay for finished streams, in step with the video) under the player on the watch page.

**App:** a Music/Video mode switch, light, dark and system themes, eight palettes plus a colour taken from the artwork,
haptic levels, content region and language, searchable settings, backup and restore of the whole library as JSON,
and opening `youtube.com`, `youtu.be`, `music.youtube.com` and `koda://` links.

## Widgets, Control Center and CarPlay

- **Home Screen widget** (`KodaWidget/`): small, medium and large sizes, with artwork, live progress, and play/pause,
  previous, next and like buttons (App Intents, `AudioPlaybackIntent`, run in the app's process). The large size also lists
  Up next. Lock Screen sizes: rectangular, circular and inline. The app shares state with the widget through the App Group
  `group.com.koda.ios` (`Shared/`).
- **Control Center**: a play/pause control (`ControlWidget`).
- **CarPlay** (`Koda/CarPlay/`): an audio app with four tabs. Home: Continue listening (resumes the last song where it
  stopped), For the Drive mixes built on the phone (Drive Mix, a Morning/Afternoon/Evening/Late Night mix from what you
  play at that hour, Fresh Finds without anything already played, artist mixes from your taste artists, and an Offline
  Mix of downloads and songs on the iPhone), Your artists, Speed dial, Quick picks and liked songs. Library (liked
  songs, downloads, On this iPhone, playlists, saved albums and artists), History, and Explore (YouTube Music's Moods &
  genres, Commute first, then its Home shelves). Pages load with a "Loading…" row, and offline show "Try again" and
  "Play your downloads". The Now Playing screen has shuffle, like, radio, a speed button that shows the speed, and a
  sheet with the sleep timer and repeat; plus Up Next and the album or artist of the song. On a real device the
  `com.apple.developer.carplay-audio` entitlement has to be approved by Apple first.
- **Siri** (`KodaPlayMediaHandler`): "Hey Siri, play <song, artist, album or playlist> on Koda", in the car too, through
  `INPlayMediaIntent` handled in the app (`application(_:handlerFor:)`). It needs the Siri capability
  (`com.apple.developer.siri`, already in `KodaCarPlay.entitlements`) on the App ID.

## Video audio tracks and subtitles

Dubbed videos expose every audio language from YouTube's HLS stream. Koda always starts on the **original** track and lists
the dubs in the audio menu on the watch page. Subtitles come from the video's caption tracks (WebVTT), drawn over the
video inline and in fullscreen, with size and background options. The chosen subtitle language is remembered.

## Swift

Swift 6 language mode with main-actor default isolation and approachable concurrency. Models, parsers and the network
client are `nonisolated`; closures that the system calls on other threads are `@Sendable`. Where the iOS 27 SDK adds
APIs, they're used behind `#available` (for example `asyncImageURLSession` for an artwork disk cache).

## Languages

English and Arabic (`Koda/Localizable.xcstrings`, 300 strings). In Arabic the whole interface runs right to left; the
transport controls and progress bar stay left to right, as in Apple Music, and each lyric line aligns by its own script.
YouTube content follows the app language unless a content language is chosen in Settings. Change the app language in
iOS Settings › Koda › Language.

## Google account (optional)

Ported from the Android app (`docs/identity.md` in the Android repo):

- **Sign-in:** Settings › Account › Sign in with Google opens Google's own sign-in page in an embedded browser, with a fresh,
  non-persistent cookie store. When it reaches music.youtube.com, the session is read from the **music.youtube.com** cookie
  jar specifically, never from accounts.google.com's, and it needs SAPISID and SID. Pasting a session `Cookie` header is
  the fallback.
- **Storage:** sessions live in the Keychain (this device only, never in backups), and several accounts can be kept and
  switched between.
- **Signing:** authenticated calls send the cookies, a per-origin `SAPISIDHASH`, `X-Goog-AuthUser` and `X-Origin`. Google's
  rotated session cookies (`*PSIDTS` and friends) are folded back into the stored session; `logged_in=0` or a 401 marks
  the session as expired. Stream resolution stays signed out, because the native player clients refuse signed requests.
- **What signing in adds:** the personal YouTube Music home and YouTube Home; Liked music, and the library's playlists and
  albums; Watch Later, liked videos and watch history; the subscriptions feed, with the account's channels added to the
  device's follows.
- **Sync:** likes, saves, Watch Later and subscriptions are sent back to the account.

## More in this version

- **Chromecast** (`Koda/Cast/`): a Cast button beside AirPlay in the player (and in the watch page's menu on iPhone).
  Songs play on the Default Media Receiver from their m4a stream, with the next three queued there so it carries on
  while the iPhone sleeps; play, pause, seek, next and the lock screen control the receiver, and ending the session
  continues on the iPhone where it was. Videos go through a small HTTP proxy in the app (`CastProxyServer`), because
  googlevideo's HLS has no CORS headers: it rewrites the playlists to H.264 up to 1080p and streams the segments.
  iOS asks for local network access the first time the Cast button is tapped.
- **Live Activity**: the song playing on the Lock Screen and in the Dynamic Island, with play/pause and next
  (Settings › Player › Live Activity).
- **Siri and Shortcuts**: "Play my liked songs in Koda", "Shuffle my library in Koda", "Play ‹playlist› in Koda",
  "Search Koda", "Start radio in Koda", "What's playing in Koda".
- **Shorts**: a vertical pager from the video home's Shorts shelf, channel pages and youtube.com/shorts links.
- **Live chat**: live and replayed chat under the player for live streams.
- **Last.fm**: scrobbling with your own Last.fm API key (Settings › Last.fm), with an offline queue.
- **Music files on this iPhone**: import MP3, M4A, AAC, WAV, FLAC or AIFF (Library › On this iPhone), or drop them in
  the Koda folder with the Files app or Finder.
- **Picture filters** for videos (vivid, warm, cool, mono, sepia, night, cinema, plus brightness, contrast and
  saturation). YouTube's HLS streams don't take video compositions, so these are SwiftUI colour effects on the player.
- **iPad**: sidebar, adaptive grids, and side-by-side player and watch page on wide windows.
- **Diagnostics**: crash and hang reports from MetricKit stay on the device (Settings › About › Diagnostics).
- **Tests**: `KodaTests` (Swift Testing) parses saved YouTube responses offline:
  `xcodebuild test -project Koda.xcodeproj -scheme Koda -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.

## Not ported

- Android Auto (CarPlay instead).
- Discord status: Discord's "listening to" needs its desktop app, which an iPhone can't talk to.
- Frame interpolation, and true sharpening (needs a Metal shader on the system player view).

## Layout

| Folder | Holds |
|---|---|
| `Koda/Core` | InnerTube client (WEB, WEB_REMIX, and visionOS `/player`), music and video parsers, lyrics |
| `Koda/Player` | `MusicPlayer` (queue, AVPlayer, Now Playing), `VideoPlayerModel`, artwork colours |
| `Koda/Store` | `LibraryStore` (one Codable JSON document), `DownloadManager` |
| `Koda/UI` | SwiftUI screens for music, video, library and settings |
