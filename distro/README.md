# innoqtech.com distro bootstrap

This distro is prepared to support creating new sample designs using:
- the same source content from the current innoqtech.com website
- the same page/subpage structure
- a future new logo (to be added later)

## Current status

Network access to `innoqtech.com` was attempted from this environment, but DNS resolution failed.
Because of that, this distro includes:
- a ready folder structure
- machine-readable archive files/schemas
- fetch attempt logs and source targets
- starter templates for content/tree reuse

## Folders

- `archive/content/` — extracted page text/content records
- `archive/structure/` — page tree and layout structure records
- `archive/metadata/` — crawl metadata and extraction status
- `assets/logo/` — placeholder for the upcoming new logo
- `templates/` — starter template files for new design prep
- `source-links/` — source URLs to retry when network is available

## Next step (when network is available)

1. Re-fetch the URLs in `source-links/targets.txt` (including `https://innoqtech.com/_2026_new/` paths).
2. Fill `archive/content/pages.json` with page text/sections.
3. Fill `archive/structure/site-tree.json` with complete page hierarchy.
4. Place the new logo file in `assets/logo/` and update metadata.
