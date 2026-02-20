param(
  [string]$Repo = "$env:USERPROFILE\openclaw-fork",
  [string]$SourceBranch = "local-winpatch-2026.2.19-2",
  [string]$PatchBase = "v2026.2.19",
  [string]$TargetRef = "origin/main",
  [string]$NewBranch = "",
  [switch]$NoFetch
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Args
  )
  & git -C $Repo @Args
  if ($LASTEXITCODE -ne 0) {
    throw "git failed: $($Args -join ' ')"
  }
}

if (-not (Test-Path $Repo)) {
  throw "Repo not found: $Repo"
}

if (-not $NoFetch) {
  Invoke-Git -Args @("fetch", "--all", "--tags")
}

$sourceExists = (& git -C $Repo rev-parse --verify --quiet $SourceBranch)
if (-not $sourceExists) {
  throw "Source branch not found: $SourceBranch"
}

$baseExists = (& git -C $Repo rev-parse --verify --quiet $PatchBase)
if (-not $baseExists) {
  throw "Patch base not found: $PatchBase"
}

$targetExists = (& git -C $Repo rev-parse --verify --quiet $TargetRef)
if (-not $targetExists) {
  throw "Target ref not found: $TargetRef"
}

if ([string]::IsNullOrWhiteSpace($NewBranch)) {
  $safeTarget = ($TargetRef -replace "[^a-zA-Z0-9._-]", "-").Trim("-")
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $NewBranch = "local-winpatch-$safeTarget-$stamp"
}

$patchCommits = @(& git -C $Repo rev-list --reverse "$PatchBase..$SourceBranch")
if ($patchCommits.Count -eq 0) {
  Write-Host "No patch commits found in range $PatchBase..$SourceBranch."
  exit 0
}

Invoke-Git -Args @("switch", "-C", $NewBranch, $TargetRef)

foreach ($sha in $patchCommits) {
  $subject = (& git -C $Repo show -s --format=%s $sha)
  Write-Host "Cherry-picking $sha $subject"
  & git -C $Repo cherry-pick $sha
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Cherry-pick conflict on $sha."
    Write-Host "Resolve conflicts, then run:"
    Write-Host "  git -C `"$Repo`" cherry-pick --continue"
    Write-Host "or abort with:"
    Write-Host "  git -C `"$Repo`" cherry-pick --abort"
    exit 1
  }
}

Write-Host ""
Write-Host "Patch reapply complete."
Write-Host "Branch: $NewBranch"
Write-Host "Repo: $Repo"
