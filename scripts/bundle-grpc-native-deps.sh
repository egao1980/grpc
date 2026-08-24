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
      # "libfoo.so.1 => /path/libfoo.so.1 (0x...)": $1 is the soname the
      # dynamic linker looks up (bundle under this name), $3 is the file.
      soname=$(printf '%s' "$line" | awk '$2 == "=>" { print $1; exit }')
      dep=$(printf '%s' "$line" | awk '$2 == "=>" { print $3; exit }')
      [ -n "$soname" ] && [ -n "$dep" ] && [ "$dep" != "not" ] || continue
      [ -f "$dep" ] || continue
      dreal=$(real_path "$dep")
      brewish "$dreal" || continue
      if [ ! -f "$destdir/$soname" ]; then
        cp -f "$dreal" "$destdir/$soname"
        chmod 644 "$destdir/$soname"
      fi
      seen_line "$destdir/$soname" || printf '%s\n' "$destdir/$soname" >>"$queue"
    done < <(ldd "$current" 2>/dev/null || true)
  done

  # Brewish libs resolve siblings via their own RUNPATH ($ORIGIN first);
  # ensure the main lib also searches its own directory.
  if command -v patchelf >/dev/null 2>&1; then
    patchelf --force-rpath --set-rpath '$ORIGIN' "$destdir/$(basename "$main_lib")"
  fi
}

# Print resolved deps of $1 as "REFNAME|REALPATH" pairs.
# REFNAME is the name used in the load command (what dyld looks up, and
# therefore the filename we must bundle under); REALPATH is the file on disk.
# @rpath/NAME entries are resolved against the real directory of the
# referencing lib and the brew lib dir (brew libs reference siblings
# like libupb_*.dylib and libgpr.dylib via @rpath).
darwin_otool_deps() {
  local lib=$1
  local libdir
  libdir=$(dirname "$(real_path "$lib")")
  local brew_lib=""
  command -v brew >/dev/null 2>&1 && brew_lib="$(brew --prefix)/lib"
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
      @rpath/*)
        base=${dep#@rpath/}
        for dir in "$libdir" "$brew_lib"; do
          [ -n "$dir" ] && [ -f "$dir/$base" ] || continue
          printf '%s|%s\n' "$base" "$(real_path "$dir/$base")"
          break
        done
        ;;
      @*) ;;
      /*) [ -f "$dep" ] && printf '%s|%s\n' "$(basename "$dep")" "$(real_path "$dep")" ;;
      *) ;;
    esac
  done < <(otool -L "$lib" 2>/dev/null || true)
}

bundle_darwin() {
  while [ -s "$queue" ]; do
    current=$(head -n1 "$queue")
    tail -n +2 "$queue" >"${queue}.tmp" && mv "${queue}.tmp" "$queue"
    [ -f "$current" ] || continue
    seen_line "$current" && continue
    add_seen "$current"

    while IFS='|' read -r refname dreal; do
      [ -n "$refname" ] && [ -n "$dreal" ] || continue
      brewish "$dreal" || continue
      if [ ! -f "$destdir/$refname" ]; then
        cp -f "$dreal" "$destdir/$refname"
        chmod 644 "$destdir/$refname"   # Cellar files are 444; install_name_tool needs write
      fi
      seen_line "$destdir/$refname" || printf '%s\n' "$destdir/$refname" >>"$queue"
    done < <(darwin_otool_deps "$current")
  done

  for f in "$destdir"/*.dylib; do
    [ -f "$f" ] || continue
    install_name_tool -id "@loader_path/$(basename "$f")" "$f"
  done

  # Rewrite load commands: any dep bundled under its referenced name now
  # resolves via @loader_path in the same directory.
  for f in "$destdir"/*; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      [ -z "$line" ] && continue
      old=${line%%[[:space:]]*}
      case $old in
        @rpath/*) b=${old#@rpath/} ;;
        @*) continue ;;
        /*) brewish "$old" || continue; b=$(basename "$old") ;;
        *) continue ;;
      esac
      [ -f "$destdir/$b" ] || continue
      new="@loader_path/$b"
      [ "$old" = "$new" ] || install_name_tool -change "$old" "$new" "$f"
    done < <(otool -L "$f" 2>/dev/null | tail -n +2)
    # install_name_tool invalidates the ad-hoc signature; arm64 kills
    # binaries with broken signatures at dlopen time.
    codesign --force -s - "$f" 2>/dev/null || true
  done
}

case $(uname -s) in
  Darwin) bundle_darwin ;;
  *) bundle_linux ;;
esac

printf 'Bundled into %s:\n' "$destdir"
ls -la "$destdir"
