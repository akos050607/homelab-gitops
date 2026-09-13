#!/usr/bin/env bash
#
# Installs the exact tool versions this repository validates with, into ./bin
# and ./.venv — both gitignored. CI and a laptop therefore run identical
# versions, so a green run locally means a green run in Actions.
#
# Idempotent: re-running with the tools already present is a no-op.
#
set -euo pipefail

KUBECONFORM_VERSION="v0.8.0"
YQ_VERSION="v4.53.6"
YAMLLINT_VERSION="1.38.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
VENV="$ROOT/.venv"

mkdir -p "$BIN"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# --- kubeconform ------------------------------------------------------------
if [ -x "$BIN/kubeconform" ] && "$BIN/kubeconform" -v 2>&1 | grep -qF "$KUBECONFORM_VERSION"; then
  echo "==> kubeconform $KUBECONFORM_VERSION already present"
else
  echo "==> installing kubeconform $KUBECONFORM_VERSION"
  curl -fsSL \
    "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${OS}-${ARCH}.tar.gz" \
    | tar -xz -C "$BIN" kubeconform
  chmod +x "$BIN/kubeconform"
fi

# --- yq ---------------------------------------------------------------------
if [ -x "$BIN/yq" ] && "$BIN/yq" --version 2>&1 | grep -qF "$YQ_VERSION"; then
  echo "==> yq $YQ_VERSION already present"
else
  echo "==> installing yq $YQ_VERSION"
  curl -fsSL -o "$BIN/yq" \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
  chmod +x "$BIN/yq"
fi

# --- yamllint (Python, so it lives in a venv rather than ./bin) --------------
if [ -x "$VENV/bin/yamllint" ] && "$VENV/bin/yamllint" --version 2>&1 | grep -qF "$YAMLLINT_VERSION"; then
  echo "==> yamllint $YAMLLINT_VERSION already present"
else
  echo "==> installing yamllint $YAMLLINT_VERSION"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet "yamllint==${YAMLLINT_VERSION}"
fi

echo
echo "Installed:"
echo "  $("$BIN/kubeconform" -v)          -> $BIN/kubeconform"
echo "  $("$BIN/yq" --version)            -> $BIN/yq"
echo "  $("$VENV/bin/yamllint" --version) -> $VENV/bin/yamllint"
echo "  $(helm version --short)           -> $(command -v helm)"
