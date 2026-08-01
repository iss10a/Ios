# Git Folder Uploader

A native SwiftUI iPhone and iPad client that uploads entire folders from the
**Files** app to GitHub, preserving the exact directory hierarchy, using the
**GitHub REST API** directly. It never opens github.com's web uploader and it
never shells out to `git`.

Everything is built on Foundation, SwiftUI, CryptoKit and URLSession:
**zero third-party dependencies, no CocoaPods, no Swift packages.** Clone the
repository, open `GitFolderUploader.xcodeproj`, press Run. Codemagic builds the
same project into an unsigned IPA with no Apple Developer account.

---

## Features

**Authentication**
- Personal Access Token sign-in (classic or fine-grained)
- OAuth **device flow** — enter a code on github.com, no client secret shipped
- Token stored in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`)

**Repositories**
- List your repositories with sorting and filtering
- Create repositories (private/public, auto-init, description)
- Global repository search and in-repo file/code search

**Browsing**
- Navigate any repository tree, any depth
- Preview text files with syntax-neutral monospace rendering; preview images
- Pull (refresh) the current directory or the whole tree
- List, create and switch branches

**Uploading**
- Pick a folder in the Files app; the whole subtree is read recursively
- Directory hierarchy is preserved exactly
- **Unchanged files are skipped** — the app computes each file's Git blob SHA-1
  locally and compares it with the remote tree
- Thousands of files land as a **single commit** via the Git Data API
- Live progress: per-file state, bytes transferred, percentage
- Multiple jobs can be queued; they run one at a time, in order
- **Pause, resume, retry and cancel**; interrupted jobs survive app relaunch
- Background execution window plus a `BGProcessingTask` for later resumption

**Editing**
- Create folders (materialised with a `.gitkeep` blob)
- Rename and delete files *and* whole folders — each as one commit
- Download a folder from GitHub to the Files app

**Presentation**
- Light and dark mode, plus an in-app theme override
- Full **English and Arabic** localisation with correct right-to-left layout
- iPhone and iPad layouts

---

## Requirements

| | |
|---|---|
| Xcode | 16.0 or newer |
| iOS deployment target | 16.0 |
| Swift language mode | 5 |
| Dependencies | none |

---

## Getting started

```bash
git clone https://github.com/<you>/GitFolderUploader.git
cd GitFolderUploader
open GitFolderUploader.xcodeproj
```

Select the `GitFolderUploader` scheme and run. Nothing else needs configuring —
no `pod install`, no package resolution, no signing setup for the simulator.

### Signing in with a Personal Access Token

1. Go to **GitHub → Settings → Developer settings → Personal access tokens**.
2. Create a token with the **`repo`** scope (add **`read:user`** so your profile
   and avatar appear). Fine-grained tokens work too — grant *Contents:
   Read and write* and *Metadata: Read* on the repositories you care about.
3. Paste it into the app's **Token** tab.

### Signing in with OAuth (device flow)

The device flow is used because it needs only a client **ID** — no client
secret is compiled into the app, which would be unsafe in a distributed binary.

1. Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Any name and homepage URL will do; the callback URL is unused by the device
   flow, so `https://github.com` is fine.
3. On the app's page, enable **Device flow**.
4. Copy the **Client ID** into the app's **OAuth** tab (it is stored in the
   Keychain and remembered afterwards).
5. Tap *Start*, open the shown URL, enter the code. The app polls until you
   approve, honouring GitHub's `slow_down` responses.

The requested scope is `repo read:user`.

---

## Building an unsigned IPA on Codemagic

1. Push this repository to GitHub.
2. In Codemagic, add the app and choose **codemagic.yaml** as the configuration
   source. The `ios-unsigned-ipa` workflow is picked up automatically.
3. Start a build. No certificates, no provisioning profiles, no App Store
   Connect key are required.

What the workflow does:

- builds with `xcodebuild ... -sdk iphoneos -destination 'generic/platform=iOS'`
  and `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`;
- copies the resulting `.app` into a `Payload/` directory;
- strips `_CodeSignature` and any `embedded.mobileprovision`;
- zips `Payload/` into `artifacts/GitFolderUploader-<version>-unsigned.ipa`.

Because the artifact is unsigned it cannot be installed straight from Xcode or
TestFlight. Install it with a sideloading tool that signs locally — Sideloadly,
AltStore, or a jailbroken device. Signing it yourself later is one command:

```bash
codesign -f -s "Apple Development: you@example.com" \
  --entitlements entitlements.plist Payload/GitFolderUploader.app
```

`xcodebuild archive` is deliberately *not* used: the archive/export path insists
on an export options plist and a signing identity, which is exactly what we are
avoiding.

---

## Architecture

MVVM on top of Clean Architecture. Dependencies point inward — `Features` knows
`Domain`, `Data` knows `Domain`, and `Domain` knows nobody.

```
GitFolderUploader/
├── App/                    Composition root, app entry point, root navigation
│   ├── AppEnvironment      @MainActor singleton wiring every dependency
│   ├── GitFolderUploaderApp
│   └── RootView
├── Core/                   Framework-level concerns, no business rules
│   ├── Networking/         Endpoint, HTTPClient, APIError, Link header parser
│   ├── Security/           KeychainStore
│   ├── Localization/       LocalizationManager, L10n
│   ├── Theme/              AppTheme, design tokens
│   └── Utilities/          GitHash, FileSystemScanner, formatters, logging
├── Domain/                 Pure Swift: no URLSession, no SwiftUI
│   ├── Entities/           Repository, Branch, GitObjects, UploadJob, …
│   ├── Repositories/       Protocols the Data layer implements
│   └── UseCases/           Auth, repositories, branches, contents, search,
│                           UploadFolderUseCase, DownloadFolderUseCase
├── Data/                   GitHub REST implementation
│   ├── DTO/                Codable wire types
│   ├── Remote/             Every endpoint in one file
│   ├── Repositories/       Protocol conformances + tree caching
│   └── Persistence/        UploadJobStore (JSON in Application Support)
├── Features/               SwiftUI views and their view models
│   ├── Auth/ Repositories/ Browser/ Branches/ Search/ Upload/ Settings/ Common/
└── Resources/              Info.plist, Assets.xcassets, en.lproj, ar.lproj
```

### How an upload works

Uploading via the *Contents* API would mean one commit per file — unusable for
a folder with thousands of entries. The app uses the **Git Data API** instead:

1. **Scan** — walk the security-scoped folder recursively, skipping `.git`,
   `node_modules`, `.build`, `DerivedData`, `__pycache__` and `.DS_Store`.
   Files above GitHub's 100 MB blob ceiling are reported, not silently dropped.
2. **Compare** — fetch the remote tree recursively and compute each local
   file's Git blob SHA-1 (`SHA1("blob <length>\0" + bytes)`, streamed in 1 MB
   chunks so memory stays flat). Matching hashes are marked *skipped*.
3. **Upload blobs** — `POST /git/blobs` for the remaining files, four at a
   time, base64-encoded, with retry and exponential backoff.
4. **Build the tree** — `POST /git/trees` in chunks of 300 entries, each chunk
   chaining `base_tree` to the previous result.
5. **Commit and push** — `POST /git/commits`, then `PATCH /git/refs/heads/…`.
   If someone else moved the branch meanwhile, the commit is rebuilt on the new
   head and retried. An empty repository with no parent commit gets its branch
   created instead.

Job state is written to disk after every transition, so quitting mid-upload and
relaunching resumes from the last completed step rather than starting over.

### Why no third-party library

- Working Copy and similar iOS Git clients are closed-source; there is no
  maintained open-source iOS GitHub client suitable as a base.
- libgit2 wrappers (SwiftGit2, ObjectiveGit) ship binary `.xcframework`s and
  require signing/embedding steps that fight an unsigned CI build, and they do
  real Git transport — pointless when the requirement is the REST API.
- Octokit.swift covers repository metadata but has no Git Data API support, so
  the whole upload pipeline would have been written by hand regardless.

Avoiding dependencies keeps the CI configuration trivial and guarantees the
project compiles unchanged after cloning.

---

## Regenerating the Xcode project

`GitFolderUploader.xcodeproj` is committed, so this is only needed after adding
or removing files:

```bash
python3 Scripts/generate_xcodeproj.py     # no tools to install
# or
xcodegen generate                          # brew install xcodegen
```

Object identifiers are hashes of each object's role and path, so regenerating
produces a stable, diffable project file.

---

## Rate limits

Authenticated requests get 5,000 points per hour; the search endpoints have
their own, much lower budget. `HTTPClient` reads `X-RateLimit-*` on every
response and Settings shows the current allowance and reset time. On a 429 or a
secondary-rate-limit response the client honours `Retry-After` and backs off.

## Notes and limits

- Individual files must stay under 100 MB — a GitHub blob limit, not an app one.
- Symlinks and submodules are not followed; they are skipped during the scan.
- Repositories are read through the Git Data API's recursive tree, which GitHub
  truncates past roughly 100,000 entries. Very large repositories will report
  the truncation instead of silently comparing an incomplete index.

## License

MIT.
