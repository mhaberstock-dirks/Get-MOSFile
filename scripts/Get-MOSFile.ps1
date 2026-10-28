<#
.SYNOPSIS
  Laedt Oracle-Patches von My Oracle Support (MOS) per Token herunter.

.DESCRIPTION
  Liest eine URL-Datei (eine Zeile pro Patch im Format URL,PATCH_PASSWORD,SHA256 - wie im
  von MOS erzeugten wget.sh) und laedt jede Datei mit curl.exe herunter.
  Die Datei access_token.txt wird im selben Verzeichnis wie die URL-Datei erwartet, die
  Downloads werden dort abgelegt (jeweils per Parameter aenderbar).
  Nach dem Download werden SHA-256 und ZIP-Struktur geprueft.

.PARAMETER ListFile
  Pfad zur URL-Datei (Pflicht, Position 0).

.PARAMETER TokenFile
  Pfad zur Tokendatei. Standard: access_token.txt neben der URL-Datei.

.PARAMETER OutDir
  Zielverzeichnis. Standard: Verzeichnis der URL-Datei.

.EXAMPLE
  .\Get-MOSFile.ps1.ps1 D:\Patches\urls.txt

.NOTES
  Exitcodes: 0 = alles ok, 10 = mindestens ein Fehler, 12 = Authentifizierung fehlgeschlagen.
#>
param(
  [Parameter(Mandatory, Position = 0)][string]$ListFile,
  [string]$TokenFile,
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web, System.IO.Compression.FileSystem

function Resolve-FullPath([string]$p) {
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
function Read-Lines([string]$path) {
  Get-Content -LiteralPath $path | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }
}

$ListFile = Resolve-FullPath $ListFile
if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) { throw "URL-Datei nicht gefunden: $ListFile" }
$baseDir = Split-Path -Parent $ListFile
$TokenFile = if ($TokenFile) { Resolve-FullPath $TokenFile } else { Join-Path $baseDir 'access_token.txt' }
$OutDir    = if ($OutDir)    { Resolve-FullPath $OutDir }    else { $baseDir }

if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
  throw "Tokendatei nicht gefunden: $TokenFile (Token holen: https://updates.oracle.com/Orion/GenToken/get_token)"
}
$token = Read-Lines $TokenFile | Select-Object -First 1
if (-not $token) { throw "Tokendatei enthaelt kein Token: $TokenFile" }
$entries = @(Read-Lines $ListFile)
if (-not $entries) { throw "Keine Eintraege in $ListFile" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
"URL-Datei : $ListFile"
"Tokendatei: $TokenFile"
"Zielordner: $OutDir`n"

$hdr = New-TemporaryFile
$ok = @(); $failed = @(); $skipped = @(); $authFailed = $false

try {
  Set-Content -Path $hdr -Value "Authorization: Bearer $token" -Encoding ascii
  foreach ($line in $entries) {
    $p   = $line.Split(',')
    $url = $p[0].Trim()
    $pw  = if ($p.Count -gt 1) { $p[1].Trim() } else { '' }
    $sha = if ($p.Count -gt 2) { $p[2].Trim().ToLower() } else { '' }
    $name = '?'
    try {
      if ($authFailed) { $skipped += $url; continue }
      $uri = [Uri]$url
      if ($uri.Host -ne 'updates.oracle.com') { throw "Unerwarteter Host: $($uri.Host)" }
      $name = [System.Web.HttpUtility]::ParseQueryString($uri.Query)['patch_file']
      if (-not $name) { $name = [IO.Path]::GetFileName($uri.AbsolutePath) }
      if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Ungueltiger Dateiname: $name" }
      if ($sha -notmatch '^[0-9a-f]{64}$') { throw "SHA-256 fehlt oder ist ungueltig in Zeile fuer $name" }
      if ($pw) {
        $sep = if ($url.Contains('?')) { '&' } else { '?' }
        $url = "$url${sep}patch_password=$([Uri]::EscapeDataString($pw))"
      }
      $target = Join-Path $OutDir $name
      if ((Test-Path -LiteralPath $target) -and ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower() -eq $sha)) {
        "SKIP (bereits vollstaendig): $name"; $ok += $name; continue
      }
      & curl.exe -L --location-trusted --fail -C - --retry 3 -H "@$hdr" -o $target $url
      if ($LASTEXITCODE -eq 22) { $authFailed = $true; throw 'HTTP-Fehler (401/403: Token abgelaufen, sonst Firewall pruefen)' }
      if ($LASTEXITCODE -ne 0)  { throw "curl.exe Exitcode $LASTEXITCODE" }
      $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
      if ($actual -ne $sha) { throw "SHA-256 stimmt nicht (erhalten $actual)" }
      $z = [IO.Compression.ZipFile]::OpenRead($target); $z.Dispose()
      "OK: $name"; $ok += $name
    }
    catch { "FEHLER ${name}: $($_.Exception.Message)"; $failed += $name }
  }
}
finally { Remove-Item $hdr -Force -ErrorAction SilentlyContinue }

"`nErfolgreich: $($ok.Count)  Fehler: $($failed.Count)  Uebersprungen: $($skipped.Count)"
if ($authFailed) { exit 12 }
if ($failed.Count) { exit 10 }
