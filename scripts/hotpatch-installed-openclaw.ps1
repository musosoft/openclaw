param(
  [string]$InstallRoot = "$env:APPDATA\npm\node_modules\openclaw",
  [switch]$NoBackup
)

$ErrorActionPreference = "Stop"

$distRoot = Join-Path $InstallRoot "dist"
if (-not (Test-Path $distRoot)) {
  throw "OpenClaw dist not found: $distRoot"
}

$targets = @(
  "config-*.js",
  "daemon-cli.js",
  "exec-*.js",
  "pi-embedded-*.js",
  "reply-*.js",
  "subagent-registry-*.js",
  "plugin-sdk\\config-*.js",
  "plugin-sdk\\reply-*.js"
)

$files = @()
foreach ($pattern in $targets) {
  $files += Get-ChildItem -Path $distRoot -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue
}
$files = $files | Sort-Object FullName -Unique

if ($files.Count -eq 0) {
  throw "No target dist files found under $distRoot"
}

$patchedCount = 0
$scanCount = 0
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $InstallRoot "hotpatch-backups\\$stamp"
if (-not $NoBackup) {
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
}

foreach ($file in $files) {
  $scanCount++
  $text = Get-Content -Raw -Path $file.FullName
  $original = $text

  # Typing TTL config wiring (idempotent)
  if ($text -match 'configuredTypingSeconds = agentCfg\?\.typingIntervalSeconds \?\? sessionCfg\?\.typingIntervalSeconds' -and $text -notmatch 'configuredTypingTtlSeconds') {
    $typingReplace = 'const typingIntervalSeconds = typeof configuredTypingSeconds === "number" ? configuredTypingSeconds : 6;' + "`n`t" + 'const configuredTypingTtlSeconds = agentCfg?.typingTtlSeconds ?? sessionCfg?.typingTtlSeconds;' + "`n`t" + 'const typingTtlMs = typeof configuredTypingTtlSeconds === "number" ? configuredTypingTtlSeconds * 1e3 : 12e4;'
    $text = $text -replace 'const typingIntervalSeconds = typeof configuredTypingSeconds === "number" \? configuredTypingSeconds : 6;', $typingReplace
    $text = $text -replace 'typingIntervalSeconds,\r?\n([ \t]*)silentToken:', "typingIntervalSeconds,`n`$1typingTtlMs,`n`$1silentToken:"
  }

  # Discord slow-listener threshold tuning for MESSAGE_CREATE (idempotent)
  if ($text -match 'DISCORD_SLOW_LISTENER_THRESHOLD_MS = 3e4' -and $text -notmatch 'DISCORD_MESSAGE_LISTENER_THRESHOLD_MS') {
    $text = $text -replace 'const DISCORD_SLOW_LISTENER_THRESHOLD_MS = 3e4;', "const DISCORD_SLOW_LISTENER_THRESHOLD_MS = 3e4;`nconst DISCORD_MESSAGE_LISTENER_THRESHOLD_MS = 12e5;"
    $text = $text -replace 'if \(params\.durationMs < DISCORD_SLOW_LISTENER_THRESHOLD_MS\) return;', "const thresholdMs = params.thresholdMs ?? DISCORD_SLOW_LISTENER_THRESHOLD_MS;`n`tif (params.durationMs < thresholdMs) return;"
    $text = $text -replace 'listener: this\.constructor\.name,\r?\n([ \t]*)event: this\.type,\r?\n([ \t]*)durationMs: Date\.now\(\) - startedAt', "listener: this.constructor.name,`n`$1event: this.type,`n`$2durationMs: Date.now() - startedAt,`n`$2thresholdMs: DISCORD_MESSAGE_LISTENER_THRESHOLD_MS"
  }

  # Config schema: allow typingTtlSeconds in session + agent defaults (idempotent)
  if ($text -match 'typingIntervalSeconds: z\.number\(\)\.int\(\)\.positive\(\)\.optional\(\)' -and $text -notmatch 'typingTtlSeconds: z\.number\(\)\.int\(\)\.positive\(\)\.optional\(\)') {
    $text = $text -replace 'typingIntervalSeconds: z\.number\(\)\.int\(\)\.positive\(\)\.optional\(\),', "typingIntervalSeconds: z.number().int().positive().optional(),`n`ttypingTtlSeconds: z.number().int().positive().optional(),"
  }

  # Windows command resolution: force openclaw.cmd so .ps1 association is never required
  $text = $text -replace '"npm","pnpm","yarn","npx"', '"npm","pnpm","yarn","npx","openclaw"'
  $text = $text -replace '"npm", "pnpm", "yarn", "npx"', '"npm", "pnpm", "yarn", "npx", "openclaw"'
  $text = [regex]::Replace(
    $text,
    '\[\s*"npm"\s*,\s*"pnpm"\s*,\s*"yarn"\s*,\s*"npx"\s*\]\.includes\(basename\)',
    '["npm","pnpm","yarn","npx","openclaw"].includes(basename)'
  )
  $text = $text -replace 'basename === "npm" \|\| basename === "pnpm" \|\| basename === "yarn" \|\| basename === "npx"', 'basename === "npm" || basename === "pnpm" || basename === "yarn" || basename === "npx" || basename === "openclaw"'

  if ($text -ne $original) {
    if (-not $NoBackup) {
      $rel = $file.FullName.Substring($InstallRoot.Length).TrimStart('\\')
      $dst = Join-Path $backupDir $rel
      $dstDir = Split-Path -Parent $dst
      New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
      Copy-Item -Path $file.FullName -Destination $dst -Force
    }
    Set-Content -Path $file.FullName -Value $text -Encoding utf8
    $patchedCount++
    Write-Host "patched: $($file.FullName)"
  }
}

Write-Host ""
Write-Host "scanned: $scanCount"
Write-Host "patched: $patchedCount"
if (-not $NoBackup) {
  Write-Host "backup:  $backupDir"
}
