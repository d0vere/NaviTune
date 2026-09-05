# NaviTune

Native iOS app for synchronizing music from a Navidrome/OpenSubsonic server to an iPhone, with the long-term goal of injecting downloaded tracks into the system Music library for Honda RoadSync compatibility.

## Current MVP

- Native SwiftUI app (iOS 16+)
- Navidrome/OpenSubsonic login and ping
- Fetches newest albums and starred songs
- Downloads tracks to the app Documents directory
- GitHub Actions workflow **Build unsigned iOS IPA**
- No Mac or local Xcode required

## Important status

The OpenSubsonic/Navidrome side is implemented. Direct injection into the native iOS Music library is intentionally isolated behind `SystemMusicInjector`; the first build ships with a safe placeholder while the ByeTunes/`idevice` pairing transport is integrated and tested separately.

This separation is deliberate: media-database injection uses private/internal iOS services and can break across iOS releases. Do not treat an untested injector as production-safe. Back up your music library before enabling it.

## Build an unsigned IPA

1. Open **Actions** in this repository.
2. Select **Build unsigned iOS IPA**.
3. Choose **Run workflow**.
4. Download the `NavidromeMusicSync-unsigned` artifact.
5. Extract it and install/sign the `.ipa` with SideStore/AltStore or another compatible signer.

Every push to `main` also runs the build automatically.

## Navidrome authentication

The client uses the standard Subsonic token authentication scheme (`u`, `t`, `s`, `v`, `c`, `f=json`) and does not store a plaintext password after creating the in-memory client for the current app session.

Prefer HTTPS for remote Navidrome servers.

## Roadmap

- [x] GitHub-only unsigned IPA build
- [x] OpenSubsonic authentication and browsing
- [x] App-local downloads
- [ ] Persistent credentials in Keychain
- [ ] Playlist / album sync rules
- [ ] Pairing-file import
- [ ] Build and link `idevice-ffi` in CI
- [ ] Native Music-library injection based on the ByeTunes approach
- [ ] Incremental de-duplication using Navidrome song IDs
- [ ] Playlist mapping (e.g. `Moto` -> Music.app)

## Credits / research

The native-library injection work is inspired by the open-source [ByeTunes](https://github.com/EduAlexxis/ByeTunes) project by EduAlexxis and the [idevice](https://github.com/jkcoxson/idevice) project. If code is later incorporated from those projects, their licenses and attribution will be retained in the repository.

## License

MIT. See `LICENSE`.
