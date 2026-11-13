#!/usr/bin/env bash
# Self-sign the pimon Win11 agent with a locally generated code-signing
# certificate (OpenSSL + osslsigncode).  Linux/macOS equivalent of
# scripts/selfsign-win11.ps1.
#
#   ./scripts/selfsign-win11.sh                     # sign zig-out + dist/release
#   ./scripts/selfsign-win11.sh --renew             # new certificate first
#   ./scripts/selfsign-win11.sh dist/release/*.exe  # sign other outputs
#
# The certificate, key and PFX live in dist/signing/ (git-ignored).  Keep the
# key private and install dist/signing/pimon-codesign.cer into
# "Trusted Root Certification Authorities" on the Windows machines that should
# trust the signature.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

CERT_DIR="dist/signing"
SUBJECT="${PIMON_CODESIGN_SUBJECT:-CN=pimon Win11 agent self-signed, O=pimon, C=AU}"
DAYS="${PIMON_CODESIGN_DAYS:-1095}"
PASSWORD="${PIMON_CODESIGN_PASSWORD:-}"
TIMESTAMP_URL=""
RENEW=0
VERIFY=1
EXES=()

# openssl req -subj wants /CN=.../O=... form; accept the comma-separated
# form used by PowerShell's New-SelfSignedCertificate too.
case "$SUBJECT" in
    /*) ;;
    *) SUBJECT="/$(printf '%s' "$SUBJECT" | sed 's/, */\//g')" ;;
esac

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
usage: scripts/selfsign-win11.sh [options] [EXE...]

Generate (once) a self-signed code-signing certificate and sign the Windows 11
agent with it.  Default target: zig-out/bin/pimon-agent-win11.exe plus
dist/release/pimon-agent-win11.exe when that release copy exists.

options:
  --cert-dir DIR     where key/crt/pfx/cer are kept (default: dist/signing)
  --subject NAME     certificate subject (default: CN=pimon ... self-signed)
  --days N           validity in days (default: 1095)
  --password PASS    PFX password (default: stored in CERT_DIR/password.txt)
  --timestamp        add an RFC 3161 timestamp from DigiCert
  --timestamp-url U  add an RFC 3161 timestamp from URL U
  --renew            create a new certificate, overwriting the old one
  --no-verify        skip the post-signing verification
  -h, --help         show this help

environment:
  PIMON_CODESIGN_PASSWORD   same as --password
  PIMON_CODESIGN_SUBJECT    same as --subject
  PIMON_CODESIGN_DAYS       same as --days
  PIMON_CODESIGN_DIR        same as --cert-dir
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cert-dir) CERT_DIR="${2:?--cert-dir needs a value}"; shift 2 ;;
        --subject) SUBJECT="${2:?--subject needs a value}"; shift 2 ;;
        --days) DAYS="${2:?--days needs a value}"; shift 2 ;;
        --password) PASSWORD="${2:?--password needs a value}"; shift 2 ;;
        --timestamp) TIMESTAMP_URL="http://timestamp.digicert.com"; shift ;;
        --timestamp-url) TIMESTAMP_URL="${2:?--timestamp-url needs a value}"; shift 2 ;;
        --renew) RENEW=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do EXES+=("$1"); shift; done ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *) EXES+=("$1"); shift ;;
    esac
done

if [ -n "${PIMON_CODESIGN_DIR:-}" ] && [ "$CERT_DIR" = "dist/signing" ]; then
    CERT_DIR="$PIMON_CODESIGN_DIR"
fi

if [ ${#EXES[@]} -eq 0 ]; then
    EXES=("zig-out/bin/pimon-agent-win11.exe")
    # `scripts/build-release.sh` copies the agent to dist/release; sign that
    # copy too when it is present so a release build is not left unsigned.
    if [ -f "dist/release/pimon-agent-win11.exe" ]; then
        EXES+=("dist/release/pimon-agent-win11.exe")
    fi
fi

for exe in "${EXES[@]}"; do
    [ -f "$exe" ] || die "$exe not found - run 'zig build win -Doptimize=ReleaseSafe' first"
done

command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v osslsigncode >/dev/null 2>&1 || die \
    "osslsigncode not found - install it (apt install osslsigncode, brew install osslsigncode)"

KEY="$CERT_DIR/pimon-codesign.key"
CRT="$CERT_DIR/pimon-codesign.crt"
PFX="$CERT_DIR/pimon-codesign.pfx"
CER="$CERT_DIR/pimon-codesign.cer"
PASSFILE="$CERT_DIR/password.txt"

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ -z "$PASSWORD" ]; then
    if [ -s "$PASSFILE" ]; then
        PASSWORD="$(cat "$PASSFILE")"
    else
        PASSWORD="$(openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-24)"
    fi
fi
printf '%s' "$PASSWORD" >"$PASSFILE"
chmod 600 "$PASSFILE"

if [ "$RENEW" -eq 1 ]; then
    rm -f "$KEY" "$CRT" "$PFX" "$CER"
fi

if [ ! -s "$KEY" ] || [ ! -s "$CRT" ]; then
    note "creating self-signed code-signing certificate ($DAYS days)"
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days "$DAYS" \
        -keyout "$KEY" -out "$CRT" -subj "$SUBJECT" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
else
    note "reusing certificate $CRT"
fi
chmod 600 "$KEY"

# Windows signtool cannot read the AES-256 PFX that OpenSSL 3 writes by
# default, so ask for the legacy 3DES PBE explicitly (still supported by both
# OpenSSL 3 and signtool.exe).
if [ -s "$PFX" ] && ! openssl pkcs12 -in "$PFX" -passin "pass:$PASSWORD" -noout >/dev/null 2>&1; then
    note "PFX password changed - re-exporting $PFX"
    rm -f "$PFX"
fi

if [ ! -s "$PFX" ]; then
    openssl pkcs12 -export -out "$PFX" -inkey "$KEY" -in "$CRT" \
        -name "pimon Win11 agent" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$PASSWORD"
fi
chmod 600 "$PFX"

if [ ! -s "$CER" ]; then
    openssl x509 -in "$CRT" -outform der -out "$CER"
fi

for exe in "${EXES[@]}"; do
    # osslsigncode refuses to write over an existing -out file, so sign into a
    # fresh temp directory (mktemp files exist already) and restore the exe's
    # mode when moving the result into place.
    mode="$(stat -c '%a' "$exe" 2>/dev/null || stat -f '%Lp' "$exe")"
    tmpdir="$(mktemp -d)"
    out="$tmpdir/$(basename "$exe")"
    trap 'rm -rf "$tmpdir"' EXIT
    note "signing $exe"
    args=(sign -pkcs12 "$PFX" -pass "$PASSWORD"
        -n "pimon Win11 agent" -i "https://github.com/liyu1981/pimon"
        -h sha256 -in "$exe" -out "$out")
    if [ -n "$TIMESTAMP_URL" ]; then args+=(-ts "$TIMESTAMP_URL"); fi
    osslsigncode "${args[@]}"
    mv -f "$out" "$exe"
    chmod "$mode" "$exe"
    rm -rf "$tmpdir"
    trap - EXIT

    if [ "$VERIFY" -eq 1 ]; then
        note "verifying $exe"
        osslsigncode verify -in "$exe" -CAfile "$CRT" >/dev/null \
            || die "signature verification failed for $exe"
    fi
done

fp="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
printf '\n'
note "done"
printf 'certificate: %s\n' "$CER"
printf 'sha256:      %s\n' "$fp"
printf 'password:    %s (keep private)\n' "$PASSFILE"
cat <<EOF

To trust this certificate on a Windows machine, run in an elevated PowerShell:

  Import-Certificate -FilePath "$CER" -CertStoreLocation Cert:\\LocalMachine\\Root
  Import-Certificate -FilePath "$CER" -CertStoreLocation Cert:\\LocalMachine\\TrustedPublisher

Self-signed signatures only satisfy Windows on machines that trust the
certificate; other people still get "Unknown publisher" / SmartScreen prompts.
EOF
