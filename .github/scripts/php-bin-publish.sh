#!/usr/bin/env bash
# php-bin-publish.sh - merge this run artifacts, generate metadata and upload one combination directory.
#
# Called by the publish job of v3-php-bin-unix.yml / v3-php-bin-windows.yml (matrix: combination).
# Inputs (environment variables):
#   WORKFLOW_KIND  unix | windows
#   COMBO          combination name (minimal/bulk/common/gnu-bulk or spc-min/spc-max)
#   OSS_BASE       https://dl.static-php.dev/v3/php-bin
#   PHP_MINORS     "8.2 8.3 8.4 8.5"
#   STATE          state JSON emitted by the plan job (single line)
#   LABEL          optional note recorded in the metadata of a forced republish
#   FORCE          true | false      this run asked for a forced republish (revision + 1)
#   TARGET_REVISION optional integer  this run asked to finish one specific revision
#   STALE_FILE     optional override for the list of platforms left on their previous revision
#   STAGE          defaults to stage (merged download-artifact directory)
#   DEST           defaults to dist (this whole directory is uploaded to v3/php-bin/<combo>/)
#   FAKE_OSS_DIR   optional, local tests
#
# Produces, inside DEST:
#   php-<ver>[-N]-<sapi>-<suffix>.<ext> + .sha256   immutable artifacts built in this run
#   version_<MM>.json                               latest patch of this minor line and its artifacts per platform
#   versions.json                                  index of the minor lines
#   README.txt                                     human readable summary
set -euo pipefail

: "${WORKFLOW_KIND:?WORKFLOW_KIND required}"
: "${COMBO:?COMBO required}"
: "${OSS_BASE:?OSS_BASE required}"
: "${PHP_MINORS:?PHP_MINORS required}"
: "${STATE:?STATE required}"
LABEL="${LABEL:-}"
STAGE="${STAGE:-stage}"
DEST="${DEST:-dist}"
FORCE="${FORCE:-false}"
TARGET_REVISION="${TARGET_REVISION:-}"

# A run that explicitly asked to republish (force=true or a targeted revision) must never silently
# keep a platform on its previous revision: collect those platforms so the workflow can fail the job
# after the metadata that is still truthful has been uploaded.
EXPLICIT_REPUBLISH=0
if [ "$FORCE" = true ] || [ -n "$TARGET_REVISION" ]; then
  EXPLICIT_REPUBLISH=1
fi
STALE_FILE="${STALE_FILE:-${RUNNER_TEMP:-/tmp}/publish-stale-${COMBO}.txt}"
: >"$STALE_FILE"
export LC_ALL=C

case "$WORKFLOW_KIND" in
  unix) EXT=tar.gz ;;
  windows) EXT=zip ;;
  *) echo "::error::unknown WORKFLOW_KIND $WORKFLOW_KIND" >&2; exit 1 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_name() { # ver rev suffix sapi
  local ver=$1 rev=$2 sfx=$3 sapi=$4 base="php-$ver"
  [ "$rev" -gt 0 ] && base="$base-$rev"
  printf '%s-%s-%s.%s' "$base" "$sapi" "$sfx" "$EXT"
}

fetch_meta() { # mm -> body, or empty when absent
  local mm=$1 url tmp code p
  url="$OSS_BASE/$COMBO/version_$mm.json"
  if [ -n "${FAKE_OSS_DIR:-}" ]; then
    p="$FAKE_OSS_DIR/$COMBO/version_$mm.json"
    [ -f "$p" ] && cat "$p"
    return 0
  fi
  tmp=$(mktemp)
  code=$(curl -sSL -o "$tmp" -w '%{http_code}' --retry 3 --retry-all-errors "$url" 2>/dev/null || true)
  case "$code" in
    200) cat "$tmp" ;;
    404) : ;;
    *) echo "::error::cannot fetch $url (HTTP $code)" >&2; exit 1 ;;
  esac
  rm -f "$tmp"
}

# Used to backfill already published artifacts: read the first column of the remote <archive>.sha256
remote_sha256() { # ver rev sfx sapi -> hash, or empty when absent
  local ver=$1 rev=$2 sfx=$3 sapi=$4 f url tmp code p
  f=$(file_name "$ver" "$rev" "$sfx" "$sapi")
  if [ -n "${FAKE_OSS_DIR:-}" ]; then
    p="$FAKE_OSS_DIR/$COMBO/$f.sha256"
    [ -f "$p" ] && awk '{print $1}' "$p"
    return 0
  fi
  url="$OSS_BASE/$COMBO/$f.sha256"
  tmp=$(mktemp)
  code=$(curl -sSL -o "$tmp" -w '%{http_code}' --retry 3 --retry-all-errors "$url" 2>/dev/null || true)
  case "$code" in
    200) awk '{print $1}' "$tmp" ;;
    404) : ;;
    *) echo "::error::cannot fetch $url (HTTP $code)" >&2; exit 1 ;;
  esac
  rm -f "$tmp"
}

mkdir -p "$DEST"

# Filled in once a version_<MM>.json is written; referenced by the README block below.
build_command=""

# 1) This run artifacts go into DEST; only archives and .sha256 files are published, info-*.json stays in STAGE
if [ -d "$STAGE" ]; then
  find "$STAGE" -maxdepth 1 -type f \( -name "*.$EXT" -o -name "*.$EXT.sha256" \) -exec cp {} "$DEST/" \;
fi

# Bundled licenses and the build manifest are rolling docs (not immutable artifacts):
# they are copied from the build job when present and republished with the newest build.
if [ -d "$STAGE" ]; then
  if [ -d "$STAGE/license" ]; then
    cp -r "$STAGE/license" "$DEST/"
  fi
  if [ -f "$STAGE/build-manifest.json" ]; then
    cp "$STAGE/build-manifest.json" "$DEST/"
  fi
fi

echo "staged archives in $DEST: $(find "$DEST" -maxdepth 1 -name "*.$EXT" | wc -l | tr -d ' ')"

index='[]'

for minor in $PHP_MINORS; do
  mm=${minor/./}
  ver=$(printf '%s' "$STATE" | jq -r --arg c "$COMBO" --arg m "$minor" \
    '[.[] | select(.combination == $c) | select(.["php-version"] | startswith($m + ".")) | .["php-version"]] | first // empty')
  [ -n "$ver" ] || continue

  old=$(fetch_meta "$mm" || true)
  [ -n "$old" ] || old='{}'
  # Metadata is keyed by minor line, so it may still describe the previous patch version.
  # Inheriting from a different patch would relabel old artifacts as the new PHP version,
  # so only reuse platform entries whose document carries the patch planned for this run.
  old_ver=$(printf '%s' "$old" | jq -r '.["php-version"] // empty')

  platforms=$(printf '%s' "$STATE" | jq -r --arg c "$COMBO" --arg v "$ver" \
    '.[] | select(.combination == $c) | select(.["php-version"] == $v) | .platform')

  entries=$(mktemp)
  : >"$entries"
  info_file=""

  for platform in $platforms; do
    st=$(printf '%s' "$STATE" | jq -c --arg c "$COMBO" --arg v "$ver" --arg p "$platform" \
      '.[] | select(.combination == $c) | select(.["php-version"] == $v) | select(.platform == $p)')
    [ -n "$st" ] || continue

    sfx=$(printf '%s' "$st" | jq -r '.["archive-suffix"]')
    rev=$(printf '%s' "$st" | jq -r '.revision')
    action=$(printf '%s' "$st" | jq -r '.action')
    spctarget=$(printf '%s' "$st" | jq -r '.["spc-target"] // empty')
    sapis=$(printf '%s' "$st" | jq -r '.sapis | join(" ")')

    have_all=1
    for sapi in $sapis; do
      [ -f "$DEST/$(file_name "$ver" "$rev" "$sfx" "$sapi")" ] || have_all=0
    done

    if [ "$have_all" = 1 ]; then
      arts='{}'
      for sapi in $sapis; do
        f=$(file_name "$ver" "$rev" "$sfx" "$sapi")
        actual=$(sha256_of "$DEST/$f")
        expected=""
        [ -f "$DEST/$f.sha256" ] && expected=$(awk '{print $1}' "$DEST/$f.sha256")
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
          echo "::error::sha256 mismatch for $f (sidecar=$expected actual=$actual)" >&2
          exit 1
        fi
        printf '%s  %s\n' "$actual" "$f" >"$DEST/$f.sha256"
        size=$(wc -c <"$DEST/$f" | tr -d ' ')
        arts=$(jq --arg sapi "$sapi" --arg f "$f" --arg sha "$actual" --argjson size "$size" \
          '. + {($sapi): {file: $f, size: $size, sha256: $sha}}' <<<"$arts")
      done

      info="$STAGE/info-$ver-$platform.json"
      [ -f "$info" ] && info_file="$info"

      jq -n --arg platform "$platform" --arg spctarget "$spctarget" --argjson rev "$rev" --argjson arts "$arts" \
        '{($platform): ({revision: $rev, "spc-target": (if $spctarget == "" then null else $spctarget end)} + $arts)}' >>"$entries"
      continue
    fi

    prev=""
    if [ "$old_ver" = "$ver" ]; then
      prev=$(printf '%s' "$old" | jq -c --arg p "$platform" '.artifacts[$p] // empty' 2>/dev/null || true)
    fi
    prev_rev=0
    if [ -n "$prev" ]; then
      prev_rev=$(printf '%s' "$prev" | jq -r '.revision // 0' 2>/dev/null || echo 0)
      case "$prev_rev" in '' | *[!0-9]*) prev_rev=0 ;; esac
    fi

    # Cheap no-op path: the published metadata already describes the planned revision.
    if [ -n "$prev" ] && [ "$prev_rev" -eq "$rev" ]; then
      jq -n --arg platform "$platform" --argjson prev "$prev" '{($platform): $prev}' >>"$entries"
      continue
    fi

    if [ "$action" = skip ]; then
      arts='{}'
      backfilled=1
      for sapi in $sapis; do
        sha=$(remote_sha256 "$ver" "$rev" "$sfx" "$sapi")
        [ -n "$sha" ] || { backfilled=0; break; }
        f=$(file_name "$ver" "$rev" "$sfx" "$sapi")
        arts=$(jq --arg sapi "$sapi" --arg f "$f" --arg sha "$sha" \
          '. + {($sapi): {file: $f, sha256: $sha}}' <<<"$arts")
      done
      if [ "$backfilled" = 1 ]; then
        echo "backfilled metadata for php-$ver $platform (rev $rev) from its .sha256 sidecars"
        jq -n --arg platform "$platform" --arg spctarget "$spctarget" --argjson rev "$rev" --argjson arts "$arts" \
          '{($platform): ({revision: $rev, "spc-target": (if $spctarget == "" then null else $spctarget end)} + $arts)}' >>"$entries"
        continue
      fi
      if [ -z "$prev" ]; then
        echo "::warning::php-$ver $platform is marked as published at rev $rev but its sidecars are incomplete" >&2
      fi
    fi

    if [ -n "$prev" ]; then
      # The planned revision was not built (its build job failed): keep the last known good entry, but
      # never let the run look as if the republish had covered this platform.
      jq -n --arg platform "$platform" --argjson prev "$prev" '{($platform): $prev}' >>"$entries"
      echo "::warning::php-$ver $platform: planned rev $rev is not available (no build in this run, or its sidecars are missing); metadata keeps rev $prev_rev" >&2
      if [ "$EXPLICIT_REPUBLISH" = 1 ]; then
        printf '%s: planned rev %s not built, still serving rev %s\n' "php-$ver $platform" "$rev" "$prev_rev" >>"$STALE_FILE"
      fi
      continue
    fi

    echo "::warning::php-$ver $platform is partially published and has no metadata yet; omitted from version_$mm.json" >&2
  done

  arts_map=$(jq -s 'add // {}' <"$entries")
  rm -f "$entries"

  if [ "$arts_map" = "{}" ]; then
    echo "no complete artifact set for PHP $minor in $COMBO, skipping version_$mm.json"
    continue
  fi

  # Derive the revision from the merged map, including platforms inherited from the previous
  # metadata: a no-op publish must keep reporting the newest revision, not reset it to 0.
  max_rev=$(printf '%s' "$arts_map" | jq -r '[.[].revision] | max // 0')

  revisions=$(printf '%s' "$arts_map" | jq -c '[.[].revision] | unique')
  old_revisions=$(printf '%s' "$old" | jq -c '.revisions // []')
  all_revisions=$(jq -cn --argjson a "$old_revisions" --argjson b "$revisions" '$a + $b | unique')

  spc_version=""; spc_ref=""; built_at=""
  if [ -n "$info_file" ] && [ -f "$info_file" ]; then
    spc_version=$(jq -r '.["spc-version"] // empty' "$info_file")
    spc_ref=$(jq -r '.["spc-ref"] // empty' "$info_file")
    built_at=$(jq -r '.["built-at"] // empty' "$info_file")
  fi
  [ -n "$spc_version" ] || spc_version=$(printf '%s' "$old" | jq -r '.["spc-version"] // empty' 2>/dev/null || true)
  [ -n "$spc_ref" ] || spc_ref=$(printf '%s' "$old" | jq -r '.["spc-ref"] // empty' 2>/dev/null || true)
  [ -n "$built_at" ] || built_at=$(printf '%s' "$old" | jq -r '.["built-at"] // empty' 2>/dev/null || true)

  first=$(printf '%s' "$STATE" | jq -c --arg c "$COMBO" --arg v "$ver" \
    '[.[] | select(.combination == $c) | select(.["php-version"] == $v)] | first')
  exts=$(printf '%s' "$first" | jq -r '.extensions // ""')
  extra=$(printf '%s' "$first" | jq -r '.extra // ""')
  suggest=$(printf '%s' "$first" | jq -r '.suggest // ""')
  if [ "$WORKFLOW_KIND" = windows ]; then
    build_command="bin/spc build --build-cli --build-micro \"$exts\" --debug $extra --dl-with-php=\"$ver\" --dl-retry=5"
  else
    build_command="bin/spc build --build-cli --build-micro --build-fpm \"$exts\" --debug $extra $suggest --dl-with-php=\"$ver\" --dl-retry=5 --dl-prefer-binary --dl-ignore-cache=php-src"
  fi

  label_json=null
  [ -n "$LABEL" ] && label_json=$(jq -Rn --arg l "$LABEL" '$l')

  jq -n \
    --arg combination "$COMBO" --arg minor "$minor" --arg mm "$mm" --arg ver "$ver" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson revision "$max_rev" --argjson revisions "$all_revisions" --argjson label "$label_json" \
    --arg spc_version "$spc_version" --arg spc_ref "$spc_ref" --arg built_at "$built_at" \
    --arg build_command "$build_command" --argjson artifacts "$arts_map" \
    '{
      "schema-version": 1,
      combination: $combination,
      minor: $minor,
      "php-version": $ver,
      "updated-at": $updated,
      revision: $revision,
      "revision-label": $label,
      revisions: $revisions,
      "spc-version": (if $spc_version == "" then null else $spc_version end),
      "spc-ref": (if $spc_ref == "" then null else $spc_ref end),
      "built-at": (if $built_at == "" then null else $built_at end),
      "build-command": $build_command,
      artifacts: $artifacts
    }' >"$DEST/version_$mm.json"

  echo "wrote version_$mm.json for PHP $ver (revision $max_rev, revisions $all_revisions)"
  index=$(jq -cn --argjson idx "$index" --arg minor "$minor" --arg ver "$ver" --arg f "version_$mm.json" \
    '$idx + [{minor: $minor, "php-version": $ver, file: $f}]')
done

# 2) Index: which minor lines have metadata, and which patch each of them points at.
jq -n --arg combination "$COMBO" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson idx "$index" \
  '{
    "schema-version": 1,
    combination: $combination,
    "updated-at": $updated,
    latest: ($idx | map({(.minor): .["php-version"]}) | add // {}),
    "version-files": ($idx | map({(.minor): .file}) | add // {})
  }' >"$DEST/versions.json"

# 3) Human-readable summary for whoever browses the directory by hand.
{
  echo "# StaticPHP prebuilt PHP binaries ($COMBO)"
  echo
  echo "Published archives are immutable: a URL always keeps its bytes."
  echo "  rev 0: php-<ver>-<sapi>-<os>-<arch>.<ext>"
  echo "  rev N: php-<ver>-N-<sapi>-<os>-<arch>.<ext>   (forced or targeted republish)"
  echo
  echo "Revisions are tracked per platform: a republish whose build failed leaves that platform on"
  echo "its previous revision. Always take the file name from artifacts.<platform>.<sapi>.file in"
  echo "version_<MM>.json; the top level \"revision\" is the newest revision of the combination and"
  echo "is not guaranteed to exist for every platform."
  echo
  echo "Machine-readable pointers, rewritten on every publish:"
  echo "  versions.json       latest PHP patch version per minor line"
  echo "  version_<MM>.json   per-platform file name, size and sha256 of the newest revision"
  echo
  echo "## Current state"
  echo
  printf '| %-8s | %-10s | %s\n' "minor" "php" "file"
  printf '| %-8s | %-10s | %s\n' "-------" "----------" "----"
  printf '%s' "$index" | jq -r '.[] | "| \(.minor) | \(.["php-version"]) | \(.file) |"'
  echo
  echo "Build command of the last write (PHP $ver):"
  echo
  echo "    $(printf '%s' "$build_command")"
} >"$DEST/README.txt"

if [ -s "$STALE_FILE" ]; then
  if [ "$EXPLICIT_REPUBLISH" = 1 ]; then
    echo "::error::explicit republish is incomplete; these platforms keep their previous revision:" >&2
  else
    echo "::warning::these platforms keep their previous revision:" >&2
  fi
  sed 's/^/  /' "$STALE_FILE" >&2
fi

echo "publish staging for $COMBO:"
ls -1 "$DEST" | sed 's/^/  /'
