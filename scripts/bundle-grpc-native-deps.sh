#!/usr/bin/env bash
# Bundle grpc.so / grpc.dylib plus transitive Homebrew-linked shared libs into DESTDIR
# for a self-contained OCI native/ overlay (no host grpc install required).
set -euo pipefail

main_lib=${1:?path to grpc.so or grpc.dylib}
destdir=${2:?output directory}

real_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1" 2>/dev/null || echo "$1"
  fi
}

brewish() {
  # Order matters for shellcheck (specific paths before broad *brew* matches).
  case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
    */cellar/* | */.linuxbrew/* | */opt/grpc/lib/*) return 0 ;;
    *linuxbrew*) return 0 ;;
    *homebrew*) return 0 ;;
    *) return 1 ;;
  esac
}

seen_line() { grep -Fxq "$1" "$seen" 2>/dev/null; }
add_seen() { printf '%s\n' "$1" >>"$seen"; }

mkdir -p "$destdir"
main_real=$(real_path "$main_lib")
cp -f "$main_real" "$destdir/$(basename "$main_lib")"

seen=$(mktemp)
queue=$(mktemp)
trap 'rm -f "$seen" "$queue"' EXIT
touch "$seen"
printf '%s\n' "$main_real" >>"$queue"

bundle_linux() {
  while [ -s "$queue" ]; do
    current=$(head -n1 "$queue")
    tail -n +2 "$queue" >"${queue}.tmp" && mv "${queue}.tmp" "$queue"
    [ -f "$current" ] || continue
    seen_line "$current" && continue
    add_seen "$current"

    while IFS= read -r line; do
      dep=$(printf '%s' "$line" | awk '$2 == "=>" { print $3; exit }')
      [ -z "$dep" ] || [ "$dep" = "not" ] && continue
      [ -f "$dep" ] || continue
      dreal=$(real_path "$dep")
      brewish "$dreal" || continue
      base=$(basename "$dreal")
      [ -f "$destdir/$base" ] || cp -f "$dreal" "$destdir/$base"
      seen_line "$dreal" || printf '%s\n' "$dreal" >>"$queue"
    done < <(ldd "$current" 2>/dev/null || true)
  done
}

darwin_otool_deps() {
  local lib=$1
  local first=1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -z "$line" ] && continue
    if [ "$first" -eq 1 ]; then
      first=0
      continue
    fi
    dep=${line%%[[:space:]]*}
    case $dep in
      @*) continue ;;
      /*) ;;
      *) continue ;;
    esac
    [ -f "$dep" ] || continue
    real_path "$dep"
  done < <(otool -L "$lib" 2>/dev/null || true)
}

bundle_darwin() {
  while [ -s "$queue" ]; do
    current=$(head -n1 "$queue")
    tail -n +2 "$queue" >"${queue}.tmp" && mv "${queue}.tmp" "$queue"
    [ -f "$current" ] || continue
    seen_line "$current" && continue
    add_seen "$current"

    while IFS= read -r dreal; do
      [ -n "$dreal" ] || continue
      brewish "$dreal" || continue
      base=$(basename "$dreal")
      [ -f "$destdir/$base" ] || cp -f "$dreal" "$destdir/$base"
      seen_line "$dreal" || printf '%s\n' "$dreal" >>"$queue"
    done < <(darwin_otool_deps "$current")
  done

  bundled_list=$(mktemp)
  # shellcheck disable=SC2064
  trap 'rm -f "$seen" "$queue" "$bundled_list"' EXIT

  for f in "$destdir"/*.dylib; do
    [ -f "$f" ] || continue
    basename "$f"
  done | sort -u >"$bundled_list"

  for f in "$destdir"/*.dylib; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    install_name_tool -id "@loader_path/$base" "$f" 2>/dev/null || true
  done

  for f in "$destdir"/*.dylib; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      [ -z "$line" ] && continue
      old=${line%%[[:space:]]*}
      case $old in
        @*) continue ;;
        /*) ;;
        *) continue ;;
      esac
      brewish "$old" || continue
      b=$(basename "$old")
      grep -Fxq "$b" "$bundled_list" 2>/dev/null || continue
      new="@loader_path/$b"
      [ "$old" = "$new" ] || install_name_tool -change "$old" "$new" "$f"
    done < <(otool -L "$f" 2>/dev/null | tail -n +2)
  done

  rm -f "$bundled_list"
  trap 'rm -f "$seen" "$queue"' EXIT
}

case $(uname -s) in
  Darwin) bundle_darwin ;;
  *) bundle_linux ;;
esac

printf 'Bundled into %s:\n' "$destdir"
ls -la "$destdir"
