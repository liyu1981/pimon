#Requires -Version 5.1
<#
.SYNOPSIS
    Self-sign the pimon Win11 agent with a locally generated certificate.

.DESCRIPTION
    Creates (once) a self-signed code-signing certificate in the current user's
    certificate store, exports it as PFX + CER under dist\signing\, and signs
    pimon-agent-win11.exe with signtool.exe.

    Windows-side equivalent of scripts/selfsign-win11.sh (which uses OpenSSL +
    osslsigncode).

.PARAMETER Exe
    Executable(s) to sign.  Defaults to every pimon-agent-win11*.exe under
    zig-out\bin.

.PARAMETER CertDir
    Where the PFX/CER/password file are kept.  Default: dist\signing.

.PARAMETER Subject
    Certificate subject.  Default: CN=pimon Win11 agent self-signed, O=pimon, C=AU

.PARAMETER Days
    Validity in days.  Default: 1095.

.PARAMETER Password
    PFX password.  Default: PIMON_CODESIGN_PASSWORD, dist\signing\password.txt,
    or a newly generated random password.

.PARAMETER TimestampUrl
    RFC 3161 timestamp server.  Self-signed certificates usually do not need a
    timestamp; default: none.

.PARAMETER Renew
    Create a new certificate instead of reusing the existing PFX.

.PARAMETER Trust
    Import the certificate into LocalMachine\Root and LocalMachine\
    TrustedPublisher (requires an elevated shell) so Windows stops warning
    about the publisher on this machine.

.PARAMETER NoVerify
    Skip the Get-AuthenticodeSignature check after signing.

.EXAMPLE
    .\scripts\selfsign-win11.ps1

.EXAMPLE
    .\scripts\selfsign-win11.ps1 -Trust -TimestampUrl http://timestamp.digicert.com
#>
[CmdletBinding()]
param(
    [string[]]$Exe = @(),
    [string]$CertDir = "dist\signing",
    [string]$Subject = "CN=pimon Win11 agent self-signed, O=pimon, C=AU",
    [int]$Days = 1095,
    [string]$Password = "",
    [string]$TimestampUrl = "",
    [switch]$Renew,
    [switch]$Trust,
    [switch]$NoVerify
)

$ErrorActionPreference = "Stop"

function Write-Note([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin",
        "${env:ProgramFiles(x86)}\Windows Kits\8.1\bin"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "signtool.exe not found. Install the Windows SDK (Desktop C++ tools) or run this from a Developer PowerShell."
}

function Get-CertPassword([string]$Dir, [string]$Supplied) {
    if ($Supplied) { return $Supplied }
    if ($env:PIMON_CODESIGN_PASSWORD) { return $env:PIMON_CODESIGN_PASSWORD }

    $file = Join-Path $Dir "password.txt"
    if (Test-Path $file) { return (Get-Content -Path $file -Raw).Trim() }

    $alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $chars = 1..32 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] }
    $password = -join $chars
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Set-Content -Path $file -Value $password -NoNewline -Encoding ASCII
    return $password
}

if ($Exe.Count -eq 0) {
    $Exe = @(Get-ChildItem -Path "zig-out\bin" -Filter "pimon-agent-win11*.exe" -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if ($Exe.Count -eq 0) {
        throw "No pimon-agent-win11*.exe found under zig-out\bin - run 'zig build win -Doptimize=ReleaseSafe' first."
    }
}
foreach ($path in $Exe) {
    if (-not (Test-Path $path)) { throw "$path not found" }
}

$signTool = Find-SignTool
New-Item -ItemType Directory -Force -Path $CertDir | Out-Null

$pfx = Join-Path $CertDir "pimon-codesign.pfx"
$cer = Join-Path $CertDir "pimon-codesign.cer"
$thumbFile = Join-Path $CertDir "thumbprint.txt"
$password = Get-CertPassword $CertDir $Password

if ($Renew) {
    # Drop the previously created certificate from the personal store so
    # renewing does not pile up entries.
    if (Test-Path $thumbFile) {
        $oldThumb = (Get-Content -Path $thumbFile -Raw).Trim()
        if ($oldThumb) {
            Remove-Item -Path "Cert:\CurrentUser\My\$oldThumb" -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $pfx, $cer, $thumbFile
}

if (-not (Test-Path $pfx)) {
    Write-Note "creating self-signed code-signing certificate ($Days days)"
    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Type CodeSigningCert `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddDays($Days) `
        -CertStoreLocation "Cert:\CurrentUser\My"

    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
    Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
    Set-Content -Path $thumbFile -Value $cert.Thumbprint -NoNewline -Encoding ASCII
}
else {
    Write-Note "reusing certificate $pfx"
}

if (-not (Test-Path $cer)) {
    $existing = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $password)
    Export-Certificate -Cert $existing -FilePath $cer -Type CERT | Out-Null
}

if ($Trust) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "-Trust needs an elevated PowerShell (Import-Certificate writes LocalMachine stores)."
    }
    Write-Note "trusting $cer on this machine"
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null
}

foreach ($path in $Exe) {
    Write-Note "signing $path"
    $arguments = @("sign", "/fd", "SHA256", "/f", $pfx, "/p", $password,
        "/d", "pimon Win11 agent", "/du", "https://github.com/liyu1981/pimon")
    if ($TimestampUrl) { $arguments += @("/tr", $TimestampUrl, "/td", "SHA256") }
    $arguments += $path

    & $signTool @arguments
    if ($LASTEXITCODE -ne 0) { throw "signtool sign failed for $path (exit $LASTEXITCODE)" }

    if (-not $NoVerify) {
        $sig = Get-AuthenticodeSignature -FilePath $path
        if ($sig.Status -in @("NotSigned", "HashMismatch")) {
            throw "signature check for $path returned $($sig.Status) ($($sig.StatusMessage))"
        }
        Write-Host "    status: $($sig.Status)  subject: $($sig.SignerCertificate.Subject)"
        if ($sig.Status -ne "Valid" -and -not $Trust) {
            Write-Host "    note: run with -Trust (elevated) so this machine trusts the certificate." -ForegroundColor Yellow
        }
    }
}

Write-Note "done"
Write-Host "certificate: $cer"
$cerCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
Write-Host ("sha256:      " + $cerCert.GetCertHashString("SHA256"))
Write-Host @"

To trust this certificate on another Windows machine, run in an elevated
PowerShell there:

  Import-Certificate -FilePath "$cer" -CertStoreLocation Cert:\LocalMachine\Root
  Import-Certificate -FilePath "$cer" -CertStoreLocation Cert:\LocalMachine\TrustedPublisher

Self-signed signatures only satisfy Windows on machines that trust the
certificate; other people still get "Unknown publisher" / SmartScreen prompts.
"@
