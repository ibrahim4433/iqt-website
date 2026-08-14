#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/iqt-distro-tool.sh --url <website_url> [options]

Options:
  --url URL               Website root URL to crawl (required)
  --project-root PATH     Repository root to write distro output (default: current directory)
  --workdir PATH          Working directory for crawl artifacts (default: /tmp/iqt-distro-tool)
  --method METHOD         Crawl method: auto|httrack|wget (default: auto)
  --dry-run               Print planned actions without crawling
  --help                  Show this help

What it produces under <project-root>/distro:
  - source-links/targets.txt (updated with URL targets)
  - archive/content/pages.json (extracted text and headings from crawled HTML)
  - archive/structure/site-tree.json (path tree inferred from crawled pages)
  - archive/metadata/fetch-report.json (crawl metadata)
  - archive/metadata/source-bundle.zip (zip package to share/upload)
USAGE
}

log() { printf '[iqt-distro-tool] %s\n' "$*"; }
err() { printf '[iqt-distro-tool][error] %s\n' "$*" >&2; }

URL="www.innoqtech.com"
PROJECT_ROOT="/mnt/c/Documents and Settings/ibrah/Documents/GitHub/iqt-website/"
WORKDIR="/tmp/iqt-distro-tool"
METHOD="auto"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$URL" ]]; then
  err "--url is required"
  usage
  exit 1
fi

if [[ "$METHOD" != "auto" && "$METHOD" != "httrack" && "$METHOD" != "wget" ]]; then
  err "--method must be one of: auto|httrack|wget"
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run enabled"
  log "URL: $URL"
  log "Project root: $PROJECT_ROOT"
  log "Workdir: $WORKDIR"
  log "Method: $METHOD"
  exit 0
fi

mkdir -p "$WORKDIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$WORKDIR/$RUN_ID"
CRAWL_DIR="$RUN_DIR/crawl"
mkdir -p "$CRAWL_DIR"

DISTRO_DIR="$PROJECT_ROOT"
CONTENT_FILE="$DISTRO_DIR/archive/content/pages.json"
TREE_FILE="$DISTRO_DIR/archive/structure/site-tree.json"
META_FILE="$DISTRO_DIR/archive/metadata/fetch-report.json"
TARGETS_FILE="$DISTRO_DIR/source-links/targets.txt"
BUNDLE_FILE="$DISTRO_DIR/archive/metadata/source-bundle.zip"

mkdir -p "$DISTRO_DIR/archive/content" "$DISTRO_DIR/archive/structure" "$DISTRO_DIR/archive/metadata" "$DISTRO_DIR/source-links"

choose_method() {
  if [[ "$METHOD" != "auto" ]]; then
    echo "$METHOD"
    return
  fi
  if command -v httrack >/dev/null 2>&1; then
    echo "httrack"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    echo "wget"
    return
  fi
  err "Neither httrack nor wget is installed"
  exit 1
}

ACTIVE_METHOD="$(choose_method)"
HOST="$(python3 - <<'PY' "$URL"
from urllib.parse import urlparse
import sys
u=urlparse(sys.argv[1])
print(u.netloc)
PY
)"

log "Crawling $URL using $ACTIVE_METHOD"
CRAWL_OK="false"
CRAWL_ERROR=""
if [[ "$ACTIVE_METHOD" == "httrack" ]]; then
  if httrack "$URL" -O "$CRAWL_DIR" "+$HOST/*" -%v >/tmp/iqt-distro-httrack.log 2>&1; then
    CRAWL_OK="true"
  else
    CRAWL_ERROR="$(tail -n 40 /tmp/iqt-distro-httrack.log | tr '\n' ' ' | sed 's/"/\\"/g')"
  fi
else
  if wget --mirror --convert-links --adjust-extension --page-requisites --no-parent --directory-prefix "$CRAWL_DIR" "$URL" >/tmp/iqt-distro-wget.log 2>&1; then
    CRAWL_OK="true"
  else
    CRAWL_ERROR="$(tail -n 40 /tmp/iqt-distro-wget.log | tr '\n' ' ' | sed 's/"/\\"/g')"
  fi
fi

mkdir -p "$RUN_DIR/extras"
for extra in robots.txt sitemap.xml; do
  if curl -fsSL --max-time 20 "$URL/$extra" -o "$RUN_DIR/extras/$extra"; then
    log "Fetched $extra"
  else
    log "Could not fetch $extra"
  fi
done

python3 - <<'PY' "$URL" "$CRAWL_DIR" "$CONTENT_FILE" "$TREE_FILE" "$META_FILE" "$ACTIVE_METHOD" "$CRAWL_OK" "$CRAWL_ERROR"
import json, os, re, sys
from html import unescape
from pathlib import Path
from urllib.parse import urljoin, urlparse
from html.parser import HTMLParser

base_url, crawl_dir, content_file, tree_file, meta_file, method, crawl_ok, crawl_error = sys.argv[1:]
crawl_ok = crawl_ok.lower() == 'true'

class LinkTitleParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_title = False
        self.in_h = None
        self.title = ''
        self.h = {f'h{i}': [] for i in range(1, 7)}
        self.text_parts = []
        self.links = []
        self.current_a = None
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'title':
            self.in_title = True
        if tag in self.h:
            self.in_h = tag
        if tag == 'a':
            self.current_a = attrs.get('href', '')
    def handle_endtag(self, tag):
        if tag == 'title':
            self.in_title = False
        if tag == self.in_h:
            self.in_h = None
        if tag == 'a':
            self.current_a = None
    def handle_data(self, data):
        s = data.strip()
        if not s:
            return
        if self.in_title:
            self.title += (' ' + s)
        if self.in_h:
            self.h[self.in_h].append(s)
        if self.current_a is not None:
            self.links.append((self.current_a, s))
        self.text_parts.append(s)

crawl = Path(crawl_dir)
html_files = sorted([p for p in crawl.rglob('*') if p.suffix.lower() in {'.html', '.htm'}])
pages = []
all_paths = set()
host = urlparse(base_url).netloc

for f in html_files:
    try:
        raw = f.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        continue
    p = LinkTitleParser()
    try:
        p.feed(raw)
    except Exception:
        continue

    rel = '/' + str(f.relative_to(crawl)).replace(os.sep, '/')
    rel = re.sub(r'/index\.html?$', '/', rel)
    rel = re.sub(r'\.html?$', '', rel)
    rel = rel.replace('//','/')
    if rel != '/' and rel.endswith('/'):
        rel = rel[:-1]

    all_paths.add(rel)

    text = ' '.join(p.text_parts)
    text = re.sub(r'\s+', ' ', unescape(text)).strip()
    text_blocks = [text[i:i+1200] for i in range(0, len(text), 1200) if text]

    links = []
    for href, label in p.links[:300]:
        u = urljoin(base_url, href)
        pu = urlparse(u)
        if pu.netloc and pu.netloc != host:
            continue
        links.append({"label": label, "href": pu.path or "/"})

    pages.append({
        "url": urljoin(base_url, rel.lstrip('/')),
        "path": rel,
        "title": p.title.strip() or None,
        "meta": {"description": "", "keywords": []},
        "sections": [{"heading": "Extracted Text", "text_blocks": text_blocks[:6]}] if text_blocks else [],
        "headings": {k: v[:50] for k, v in p.h.items()},
        "links": links[:200]
    })

pages_doc = {
    "site": urlparse(base_url).netloc,
    "extracted_at": __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    "source_status": "extracted" if crawl_ok else "partial_or_failed",
    "pages": pages
}
Path(content_file).write_text(json.dumps(pages_doc, indent=2), encoding='utf-8')

# Build tree from paths
root = {"path": "/", "title": "Home", "children": []}

def add_path(root_node, path):
    if path == '/':
        return
    parts = [p for p in path.split('/') if p]
    node = root_node
    current = ''
    for part in parts:
        current += '/' + part
        found = None
        for child in node["children"]:
            if child["path"] == current:
                found = child
                break
        if not found:
            found = {"path": current, "title": part.replace('-', ' ').replace('_', ' ').title(), "children": []}
            node["children"].append(found)
        node = found

for pth in sorted(all_paths):
    add_path(root, pth)

def sort_tree(node):
    node["children"].sort(key=lambda x: x["path"])
    for c in node["children"]:
        sort_tree(c)
sort_tree(root)

tree_doc = {
    "site": urlparse(base_url).netloc,
    "captured_at": __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    "source_status": "extracted" if crawl_ok else "partial_or_failed",
    "tree": root
}
Path(tree_file).write_text(json.dumps(tree_doc, indent=2), encoding='utf-8')

meta = {
    "site": urlparse(base_url).netloc,
    "generated_at": __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    "status": "success" if crawl_ok else "failed_or_partial",
    "method": method,
    "attempts": [
        {
            "url": base_url,
            "result": "success" if crawl_ok else "failed",
            "error": None if crawl_ok else crawl_error
        }
    ],
    "stats": {
        "html_files": len(html_files),
        "pages_extracted": len(pages)
    }
}
Path(meta_file).write_text(json.dumps(meta, indent=2), encoding='utf-8')
PY

if [[ -f "$TARGETS_FILE" ]]; then
  if ! grep -Fxq "$URL" "$TARGETS_FILE"; then
    printf '%s\n' "$URL" >> "$TARGETS_FILE"
  fi
else
  printf '%s\n' "$URL" > "$TARGETS_FILE"
fi
for extra in robots.txt sitemap.xml; do
  target="$URL/$extra"
  if ! grep -Fxq "$target" "$TARGETS_FILE"; then
    printf '%s\n' "$target" >> "$TARGETS_FILE"
  fi
done

(
  cd "$RUN_DIR"
  zip -qr "$BUNDLE_FILE" crawl extras || true
)

log "Done"
log "Content file: $CONTENT_FILE"
log "Tree file: $TREE_FILE"
log "Metadata file: $META_FILE"
log "Bundle: $BUNDLE_FILE"
