#!/bin/bash
# Download and independently verify a Draft before its authorized publication.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=""; build_number=""; publish=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--build)
      [[ $# -ge 2 ]] || exit 64
      if [[ "$1" == --version ]]; then version="$2"; else build_number="$2"; fi
      shift 2 ;;
    --publish) publish=1; shift ;;
    --help|-h)
      echo 'Usage: scripts/publish-release.sh --version VERSION --build BUILD [--publish]'
      echo 'Default: validate only. --publish requires explicit release authorization.'
      exit 0 ;;
    *) echo 'Unknown release publication argument' >&2; exit 64 ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || exit 64
cd "$project_dir"
[[ -z "$(git status --porcelain)" && "$(git branch --show-current)" == main ]] || {
  echo 'Publication requires clean main' >&2; exit 65;
}
git fetch --quiet origin main --tags
head_sha="$(git rev-parse HEAD)"
[[ "$head_sha" == "$(git rev-parse origin/main)" ]] || exit 65
mkdir -p build
evidence_dir="$(mktemp -d "$project_dir/build/publication-$version-$build_number.XXXXXX")"
mkdir "$evidence_dir/assets"
tag="v$version"
metadata() {
  ./scripts/project-gh.sh api --method GET "repos/crazy01100/myterm/releases/tags/$tag" \
    --jq '{id,draft,prerelease,tag_name,target_commitish,assets:[.assets[]|{id,name,size,digest,updated_at}]}'
}
metadata > "$evidence_dir/release-before.json"
./scripts/project-python.sh - "$evidence_dir/release-before.json" "$tag" "$head_sha" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r['draft'] is not True or r['tag_name'] != sys.argv[2] or r['target_commitish'] != sys.argv[3]:
    raise SystemExit('Expected exact-commit Draft release')
PY
./scripts/project-gh.sh release download "$tag" --repo crazy01100/myterm \
  --dir "$evidence_dir/assets" --pattern 'MyTerm-*-arm64.zip' --pattern appcast.xml \
  --pattern release-notes.html --pattern CHECKSUMS.txt --pattern release-manifest.json
./scripts/verify-release-assets.sh --assets "$evidence_dir/assets" --version "$version" --build "$build_number"
./scripts/project-python.sh scripts/security-audit.py --release-stage publish \
  --version "$version" --build "$build_number" --assets "$evidence_dir/assets" \
  --output "$evidence_dir/security-report.json"
metadata > "$evidence_dir/release-after.json"
cmp "$evidence_dir/release-before.json" "$evidence_dir/release-after.json"
[[ "$head_sha" == "$(git rev-parse HEAD)" && -z "$(git status --porcelain)" ]] || exit 65
remote_sha="$(./scripts/project-gh.sh api --method GET repos/crazy01100/myterm/commits/main --jq .sha)"
[[ "$remote_sha" == "$head_sha" ]] || { echo 'main changed during validation' >&2; exit 65; }
if [[ "$publish" == 1 ]]; then
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ./scripts/project-gh.sh release edit "$tag" --repo crazy01100/myterm --draft=false --prerelease=false --latest
  else
    ./scripts/project-gh.sh release edit "$tag" --repo crazy01100/myterm --draft=false --prerelease
  fi
  echo 'Published; deployment and user update acceptance remain pending.'
else
  echo 'Draft validated; nothing published.'
fi
echo "Evidence: $evidence_dir"
