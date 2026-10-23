# Atlas

Native macOS desktop app for managing AWS resources, written in **Swift + SwiftUI** (macOS 14+).

## Repository layout

| Path | Contents |
|------|----------|
| [`AtlasMac/`](AtlasMac/) | The macOS app (Swift Package) — see [AtlasMac/README.md](AtlasMac/README.md) |
| [`cloud-atlas.io/`](cloud-atlas.io/) | Marketing website, deployed by `.github/workflows/deploy-site.yml` |

## Quick start

```bash
cd AtlasMac
swift run                    # development
./scripts/build-app.sh       # creates dist/Atlas.app
./scripts/test.sh            # unit tests
```
