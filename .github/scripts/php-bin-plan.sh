#!/usr/bin/env bash
# php-bin-plan.sh - decide what the v3 php-bin plan job should build and what is already published.
#
# Inputs (environment variables):
#   WORKFLOW_KIND  unix | windows
#   MODE           publish | verify
#   FORCE          true | false          publish only: republish every target with revision + 1
#   PHP_MINORS     space separated, e.g. "8.2 8.3 8.4 8.5"
#   OSS_BASE       https://dl.static-php.dev/v3/php-bin
#   FAKE_OSS_DIR   optional, local tests: emulate the OSS bucket with a local directory, no network
#
# Outputs:
#   matrix.json    targets to build in this run ([] = nothing to build)
#   state.json     publication state of every target (the publish job uses it to write metadata)
#   $GITHUB_OUTPUT matrix / state / mode
#
# Semantics:
#   verify  - do not probe the bucket, matrix = everything (build-only self check, no upload)
#   publish - skip when the full remote set (archive + .sha256) exists; otherwise publish rev 0
#             (never published before) or the next free rev N (partial set or forced republish). Artifacts are never overwritten.
set -euo pipefail

: "${WORKFLOW_KIND:?WORKFLOW_KIND required (unix|windows)}"
: "${MODE:?MODE required (publish|verify)}"
: "${PHP_MINORS:?PHP_MINORS required}"
: "${OSS_BASE:?OSS_BASE required}"
FORCE="${FORCE:-false}"

export LC_ALL=C

# An unknown remote state (000/5xx/429) must not be treated as "missing"; accumulate it here and fail hard at the end.
ERRLOG="$(mktemp)"
: >"$ERRLOG"

# ------------------------------------------------------------------ static tables

extensions_for() {
  case "$1" in
    minimal) printf '%s' 'iconv,pcntl,posix,mbstring,filter,tokenizer,phar' ;;
    common) printf '%s' 'bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,ftp,gd,gmp,iconv,xml,mbstring,mbregex,mysqlnd,openssl,pcntl,pdo,pdo_mysql,pdo_sqlite,pdo_pgsql,pgsql,phar,posix,redis,session,simplexml,soap,sockets,sqlite3,tokenizer,xmlwriter,xmlreader,zlib,zip' ;;
    bulk | gnu-bulk) printf '%s' 'apcu,bcmath,bz2,calendar,ctype,curl,dba,dom,event,exif,fileinfo,filter,ftp,gd,gmp,iconv,imagick,imap,intl,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,opentelemetry,pcntl,pdo,pdo_mysql,pgsql,phar,posix,protobuf,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,swoole,swoole-hook-mysql,swoole-hook-pgsql,swoole-hook-sqlite,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib' ;;
    spc-min) printf '%s' 'ctype,fileinfo,filter,iconv,mbstring,tokenizer,phar' ;;
    spc-max) printf '%s' 'amqp,apcu,bcmath,bz2,calendar,ctype,curl,dba,dom,ds,exif,ffi,fileinfo,filter,ftp,gd,iconv,igbinary,libxml,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,pdo,pdo_mysql,pdo_sqlite,pdo_sqlsrv,phar,rar,redis,session,shmop,simdjson,simplexml,soap,sockets,sqlite3,sqlsrv,ssh2,sysvshm,tokenizer,xml,xmlreader,xmlwriter,yac,yaml,zip,zlib' ;;
    *) return 1 ;;
  esac
}

suggest_for() {
  case "$1" in
    common | bulk | gnu-bulk) printf '%s' '--with-suggests' ;;
    *) printf '' ;;
  esac
}

sapis_for() {
  case "$WORKFLOW_KIND" in
    unix) printf '%s' 'cli micro fpm' ;;
    windows) printf '%s' 'cli micro' ;;
  esac
}

archive_ext() {
  case "$WORKFLOW_KIND" in
    unix) printf '%s' 'tar.gz' ;;
    windows) printf '%s' 'zip' ;;
  esac
}

# combination|platform|runner|os|arch|archive-suffix|spc-target|extra-flag
target_rows() {
  case "$WORKFLOW_KIND" in
    unix)
      cat <<'ROWS'
minimal|linux-x86_64|ubuntu-latest|linux|x86_64|linux-x86_64||--with-upx-pack
minimal|linux-aarch64|ubuntu-24.04-arm|linux|aarch64|linux-aarch64||--with-upx-pack
minimal|macos-x86_64|macos-15-intel|macos|x86_64|macos-x86_64||
minimal|macos-aarch64|macos-15|macos|aarch64|macos-aarch64||
bulk|linux-x86_64|ubuntu-latest|linux|x86_64|linux-x86_64||--with-upx-pack
bulk|linux-aarch64|ubuntu-24.04-arm|linux|aarch64|linux-aarch64||--with-upx-pack
bulk|macos-x86_64|macos-15-intel|macos|x86_64|macos-x86_64||
bulk|macos-aarch64|macos-15|macos|aarch64|macos-aarch64||
common|linux-x86_64|ubuntu-latest|linux|x86_64|linux-x86_64||--with-upx-pack
common|linux-aarch64|ubuntu-24.04-arm|linux|aarch64|linux-aarch64||--with-upx-pack
common|macos-x86_64|macos-15-intel|macos|x86_64|macos-x86_64||
common|macos-aarch64|macos-15|macos|aarch64|macos-aarch64||
gnu-bulk|linux-x86_64-gnu|ubuntu-22.04|linux|x86_64|linux-x86_64|x86_64-linux-gnu.2.17|
gnu-bulk|linux-aarch64-gnu|ubuntu-22.04-arm|linux|aarch64|linux-aarch64|aarch64-linux-gnu.2.17|
ROWS
      ;;
    windows)
      cat <<'ROWS'
spc-min|win|windows-latest|windows|x86_64|win||--with-upx-pack
spc-max|win|windows-latest|windows|x86_64|win||--with-upx-pack
ROWS
      ;;
  esac
}

# ------------------------------------------------------------------ remote probing

http_code() {
  local url=$1
  if [ -n "${FAKE_OSS_DIR:-}" ]; then
    local rel="${url#"$OSS_BASE"/}"
    if [ -f "$FAKE_OSS_DIR/$rel" ]; then printf '200'; else printf '404'; fi
    return 0
  fi
  curl -sIL -o /dev/null -w '%{http_code}' --retry 3 --retry-all-errors --max-time 30 "$url" 2>/dev/null || true
}

# Only 200/404 are trusted. Any other status (000/5xx/429) means "cannot tell": record it in ERRLOG
# and treat it as missing, then abort the whole run if ERRLOG is non-empty (never overwrite on a failed probe).
status() {
  local url=$1 code
  code=$(http_code "$url")
  case "$code" in
    200 | 404) printf '%s' "$code" ;;
    *)
      printf '000'
      echo "::warning::unexpected HTTP status '$code' for $url, cannot tell whether it is published" >&2
      printf '%s\n' "$url" >>"$ERRLOG"
      ;;
  esac
}

file_name() { # ver rev suffix sapi ext
  local ver=$1 rev=$2 sfx=$3 sapi=$4 ext=$5 base="php-$ver"
  [ "$rev" -gt 0 ] && base="$base-$rev"
  printf '%s-%s-%s.%s' "$base" "$sapi" "$sfx" "$ext"
}

url_of() { # combo ver rev suffix sapi ext
  local combo=$1 ver=$2 rev=$3 sfx=$4 sapi=$5 ext=$6
  printf '%s/%s/%s' "$OSS_BASE" "$combo" "$(file_name "$ver" "$rev" "$sfx" "$sapi" "$ext")"
}

# The whole set (archive + .sha256 for every SAPI) exists
set_complete() { # combo ver rev suffix
  local combo=$1 ver=$2 rev=$3 sfx=$4 ext sapi url
  ext=$(archive_ext)
  for sapi in $(sapis_for); do
    url=$(url_of "$combo" "$ver" "$rev" "$sfx" "$sapi" "$ext")
    [ "$(status "$url")" = 200 ] || return 1
    [ "$(status "$url.sha256")" = 200 ] || return 1
  done
  return 0
}

# Whether this revision already has any object (archive or .sha256), used to avoid overwriting
any_object() { # combo ver rev suffix
  local combo=$1 ver=$2 rev=$3 sfx=$4 ext sapi url
  ext=$(archive_ext)
  for sapi in $(sapis_for); do
    url=$(url_of "$combo" "$ver" "$rev" "$sfx" "$sapi" "$ext")
    [ "$(status "$url")" = 200 ] && return 0
    [ "$(status "$url.sha256")" = 200 ] && return 0
  done
  return 1
}

next_free_rev() { # combo ver suffix
  local combo=$1 ver=$2 sfx=$3 n=1
  while [ "$n" -le 50 ]; do
    if ! any_object "$combo" "$ver" "$n" "$sfx"; then
      printf '%s' "$n"
      return 0
    fi
    n=$((n + 1))
  done
  echo "::error::more than 50 revisions for php-$ver-$sfx in $combo" >&2
  printf '%s\n' "too many revisions: $combo php-$ver-$sfx" >>"$ERRLOG"
  printf '0'
}

# ------------------------------------------------------------------ resolve PHP versions

# FAKE_PHP_VERSIONS="8.2=8.2.29 8.3=8.3.26" skips php.net (local tests only)
VERSIONS="${FAKE_PHP_VERSIONS:-}"
if [ -z "$VERSIONS" ]; then
  for minor in $PHP_MINORS; do
    json=$(curl -fsSL --retry 3 --retry-all-errors "https://www.php.net/releases/index.php?json&version=$minor")
# php.net returns a single latest-release object for "?json&version=8.4" (with a version field);
# some mirrors or older behaviour return {8.4.27: {...}, ...}, so fall back to the key names.
    ver=$(printf '%s' "$json" | jq -r '.version // empty')
    if [ -z "$ver" ]; then
      ver=$(printf '%s' "$json" |
        jq -r '[keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] | sort_by(split(".") | map(tonumber)) | last // empty')
    fi
    case "$ver" in
      "$minor".*) : ;;
      *) ver="" ;;
    esac
    if [ -z "$ver" ]; then
      echo "::error::cannot resolve the latest PHP patch for $minor (php.net response: $(printf '%s' "$json" | head -c 200))" >&2
      exit 1
    fi
    VERSIONS="$VERSIONS $minor=$ver"
  done
fi

lookup_ver() {
  printf '%s
' "$VERSIONS" | tr ' ' '
' | sed -n "s/^$1=//p"
}

# ------------------------------------------------------------------ main loop

# Probing is pure network IO (up to 6 HEADs per target). Serially, 56 targets take ~15 minutes behind Cloudflare,
# so probe per target in parallel. Each target writes only its own two result lines (M=matrix / S=state); JSON is assembled afterwards.
matrix="$(mktemp)"
state="$(mktemp)"
all="$(mktemp)"
trap 'rm -f "$matrix" "$state" "$all" "$ERRLOG"' EXIT
: >"$matrix"
: >"$state"
: >"$all"

export OSS_BASE WORKFLOW_KIND MODE FORCE VERSIONS ERRLOG
export -f extensions_for suggest_for sapis_for archive_ext http_code status file_name url_of set_complete any_object next_free_rev

plan_one() {
  local row=$1 combo platform runner os arch sfx spctarget extra minor ver action revision ext sapis
  IFS='|' read -r combo platform runner os arch sfx spctarget extra minor ver <<<"$row"
  ext=$(archive_ext)
  sapis=$(sapis_for)
  action=skip
  revision=0

  if [ "$MODE" = verify ]; then
    action=build
  elif set_complete "$combo" "$ver" 0 "$sfx"; then
    if [ "$FORCE" = true ]; then
      action=publish
      revision=$(next_free_rev "$combo" "$ver" "$sfx")
    fi
  else
    action=publish
    if any_object "$combo" "$ver" 0 "$sfx"; then
      revision=$(next_free_rev "$combo" "$ver" "$sfx")
    fi
  fi

  if [ "$action" != skip ]; then
    printf 'M\t%s\n' "$(jq -cn \
      --arg combination "$combo" --arg php_version "$ver" --arg php_minor "$minor" --arg platform "$platform" \
      --arg archive_suffix "$sfx" --arg runner "$runner" --arg os "$os" --arg arch "$arch" \
      --arg spc_target "$spctarget" --arg extra "$extra" --arg extensions "$(extensions_for "$combo")" \
      --arg suggest "$(suggest_for "$combo")" --arg sapis "$sapis" --arg extension "$ext" \
      --argjson revision "$revision" \
      '{
        combination: $combination,
        "php-version": $php_version,
        "php-minor": $php_minor,
        platform: $platform,
        "archive-suffix": $archive_suffix,
        runner: $runner,
        os: $os,
        arch: $arch,
        "spc-target": $spc_target,
        extra: $extra,
        extensions: $extensions,
        suggest: $suggest,
        sapis: ($sapis | split(" ")),
        revision: $revision,
        extension: $extension
      }')"
  fi

  printf 'S\t%s\n' "$(jq -cn \
    --arg combination "$combo" --arg php_version "$ver" --arg platform "$platform" \
    --arg archive_suffix "$sfx" --arg spc_target "$spctarget" --arg action "$action" \
    --arg os "$os" --arg arch "$arch" --arg extra "$extra" \
    --arg extensions "$(extensions_for "$combo")" --arg suggest "$(suggest_for "$combo")" \
    --arg sapis "$sapis" --argjson revision "$revision" \
    '{
      combination: $combination,
      "php-version": $php_version,
      platform: $platform,
      "archive-suffix": $archive_suffix,
      "spc-target": $spc_target,
      os: $os,
      arch: $arch,
      extra: $extra,
      extensions: $extensions,
      suggest: $suggest,
      sapis: ($sapis | split(" ")),
      revision: $revision,
      action: $action
    }')"
}
export -f plan_one

# Target row: combination|platform|runner|os|arch|suffix|spc-target|extra|minor|patch
target_rows | while IFS='|' read -r combo platform runner os arch sfx spctarget extra; do
  [ -n "$combo" ] || continue
  for minor in $PHP_MINORS; do
    ver=$(lookup_ver "$minor")
    if [ -z "$ver" ]; then
      echo "::error::no resolved PHP version for minor $minor" >&2
      exit 1
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$combo" "$platform" "$runner" "$os" "$arch" "$sfx" "$spctarget" "$extra" "$minor" "$ver"
  done
done >"$matrix.rows"

total=$(wc -l <"$matrix.rows" | tr -d ' ')
echo "planning $total target(s) with parallel probing"
# Concurrency: 12 is enough to bring 56 targets down to 20-40s on a GitHub runner without hammering the CDN.
if [ "$MODE" = verify ]; then
  # verify never probes the bucket, it just expands locally with zero network requests.
  xargs -P 1 -I '{}' bash -c 'plan_one "$@"' _ '{}' <"$matrix.rows" >"$all"
else
  xargs -P 12 -I '{}' bash -c 'plan_one "$@"' _ '{}' <"$matrix.rows" >"$all"
fi
rm -f "$matrix.rows"

if [ -s "$ERRLOG" ]; then
  echo "::error::could not determine the published state of $(wc -l <"$ERRLOG" | tr -d ' ') URL(s); refusing to publish anything this run" >&2
  head -n 5 "$ERRLOG" >&2
  exit 1
fi

awk -F '\t' '$1 == "M" { print $2 }' "$all" >"$matrix"
awk -F '\t' '$1 == "S" { print $2 }' "$all" >"$state"

# Combination list for this workflow kind, so the publish job matrix has a single source of truth.
combinations=$(target_rows | cut -d'|' -f1 | awk 'NF && !seen[$0]++' |
  jq -R -sc 'split("\n") | map(select(length > 0))')

jq -s '.' "$matrix" >matrix.json
jq -s '.' "$state" >state.json

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "matrix=$(jq -c . matrix.json)"
    echo "state=$(jq -c . state.json)"
    echo "mode=$MODE"
    echo "combinations=$combinations"
  } >>"$GITHUB_OUTPUT"
fi

echo "planned $(jq 'length' matrix.json) build(s), $(jq 'length' state.json) target(s)"
jq -r '.[] | "  \(.combination) \(.["php-version"]) \(.platform) rev=\(.revision)"' matrix.json
