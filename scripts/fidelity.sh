#!/bin/sh
# snatch.wezterm fidelity harness.
#
# Screenshots the WezTerm window so the Neovim reproduction can be checked
# against the original terminal by eye. Used by `snatch.action { screenshot =
# true }`; the plugin takes the "before" image and the deployed Neovim config
# takes the "after" one.
#
# macOS only: it relies on screencapture(1). The first run prompts for Screen
# Recording permission (and Accessibility, if the window bounds lookup is to
# work); until both are granted the images will be blank or full-screen.

set -eu

usage() {
  cat >&2 <<'EOF'
usage:
  fidelity.sh capture <out.png>   screenshot the WezTerm window
  fidelity.sh compare <prefix>    montage <prefix>-before.png and <prefix>-after.png
EOF
  exit 2
}

# Position and size of WezTerm's front window, as "x,y,w,h".
# Needs Accessibility permission; prints nothing when unavailable.
wezterm_window_bounds() {
  osascript 2>/dev/null <<'EOF' || true
tell application "System Events"
  tell process "WezTerm"
    set p to position of front window
    set s to size of front window
    return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ¬
           ((item 1 of s) as text) & "," & ((item 2 of s) as text)
  end tell
end tell
EOF
}

cmd_capture() {
  out=$1
  case $(uname -s) in
    Darwin) ;;
    *)
      echo "snatch.wezterm: screenshots are only supported on macOS" >&2
      exit 1
      ;;
  esac

  bounds=$(wezterm_window_bounds)
  if [ -n "$bounds" ]; then
    screencapture -x -o -R "$bounds" "$out"
  else
    # No Accessibility permission: fall back to the whole primary display.
    echo "snatch.wezterm: cannot read WezTerm window bounds, capturing display 1" >&2
    screencapture -x -o -D 1 "$out"
  fi
}

cmd_compare() {
  prefix=$1
  before=${prefix}-before.png
  after=${prefix}-after.png
  out=${prefix}-compare.png

  for f in "$before" "$after"; do
    if [ ! -f "$f" ]; then
      echo "snatch.wezterm: missing $f" >&2
      exit 1
    fi
  done

  # ImageMagick 7 drives everything through `magick`; 6 used `convert`.
  if command -v magick >/dev/null 2>&1; then
    set -- magick
  elif command -v convert >/dev/null 2>&1; then
    set -- convert
  else
    echo "snatch.wezterm: ImageMagick not found; compare these by hand:" >&2
    echo "  before: $before" >&2
    echo "  after:  $after" >&2
    exit 0
  fi

  # Stack the shots vertically at full width, separated by a magenta rule, so a
  # row or column shift in the reproduction shows up as a misalignment between
  # the two halves. -append rather than montage: montage insists on a font even
  # when no labels are drawn, and macOS has no default one configured.
  "$@" "$before" \
    '(' "$after" -background magenta -gravity north -splice 0x4 ')' \
    -background '#303030' -gravity west -append "$out"

  echo "snatch.wezterm: wrote $out"
  if command -v open >/dev/null 2>&1; then
    open "$out"
  fi
}

[ $# -ge 1 ] || usage
subcommand=$1
shift

case $subcommand in
  capture)
    [ $# -eq 1 ] || usage
    cmd_capture "$1"
    ;;
  compare)
    [ $# -eq 1 ] || usage
    cmd_compare "$1"
    ;;
  *) usage ;;
esac
