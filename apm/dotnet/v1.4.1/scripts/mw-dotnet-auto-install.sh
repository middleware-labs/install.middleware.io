#!/bin/sh
set -e

# guess OS_TYPE if not provided
if [ -z "$OS_TYPE" ]; then
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    cygwin_nt*|mingw*|msys_nt*)
      OS_TYPE="windows"
      ;;
    linux*)
      if [ "$(ldd /bin/ls | grep -m1 'musl')" ]; then
        OS_TYPE="linux-musl"
      else
        OS_TYPE="linux-glibc"
      fi
      ;;
    darwin*)
      OS_TYPE="macos"
      ;;
  esac
fi

case "$OS_TYPE" in
  "linux-glibc"|"linux-musl"|"macos"|"windows")
    ;;
  *)
    echo "Set the operating system type using the OS_TYPE environment variable. Supported values: linux-glibc, linux-musl, macos, windows." >&2
    exit 1
    ;;
esac

OTEL_DOTNET_AUTO_HOME="$HOME/.mw-dotnet-auto"
test -z "$TMPDIR" && TMPDIR="$(mktemp -d)"
test -z "$VERSION" && VERSION="v1.4.1"


#TMPFILE="/home/keval/codebase/middleware-labs/install.middleware.io/apm/dotnet/v1.4.1/middleware-dotnet-instrumentation-linux-glibc.zip"
#unzip -q "$TMPFILE" -d "$OTEL_DOTNET_AUTO_HOME"

RELEASES_URL="https://install.middleware.io/apm/dotnet"
ARCHIVE="middleware-dotnet-instrumentation-$OS_TYPE.zip"

TMPFILE="$TMPDIR/$ARCHIVE"
(
  cd "$TMPDIR"
  echo "Downloading $VERSION for $OS_TYPE..."
  curl -sSfLo "$TMPFILE" "$RELEASES_URL/$VERSION/$ARCHIVE"
)
rm -rf "$OTEL_DOTNET_AUTO_HOME"
unzip -q "$TMPFILE" -d "$OTEL_DOTNET_AUTO_HOME"

