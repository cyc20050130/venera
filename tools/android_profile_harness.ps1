param(
  [string]$Package = "com.github.wgh136.venera",
  [string]$OutDir = "",
  [int]$DurationSeconds = 180,
  [int]$ResumeIdleSeconds = 600,
  [string]$Serial = "",
  [switch]$SkipLaunch,
  [switch]$SkipResumeWait
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ScenarioResults = @()

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowEmptyString()][string]$Content
  )
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function Append-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowEmptyString()][string]$Content
  )
  [System.IO.File]::AppendAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][scriptblock]$Command
  )
  $path = Join-Path $OutDir $FileName
  Append-Utf8File $SummaryPath "`n## $Name`n`n"
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = & $Command 2>&1 | ForEach-Object { "$_" } | Out-String
    $exitCode = $global:LASTEXITCODE
    Write-Utf8File $path $output
    Append-Utf8File $SummaryPath "- output: $FileName`n"
    if ($null -ne $exitCode -and $exitCode -ne 0) {
      Append-Utf8File $SummaryPath "- exitCode: $exitCode`n"
    }
    return $output
  } catch {
    $message = $_ | Out-String
    Write-Utf8File $path $message
    Append-Utf8File $SummaryPath "- failed: $FileName`n- error: $($_.Exception.Message)`n"
    return $message
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
}

function Invoke-Adb {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  if ($Serial -ne "") {
    & adb -s $Serial @Arguments
  } else {
    & adb @Arguments
  }
}

function Invoke-AdbText {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    return (Invoke-Adb $Arguments 2>&1 | ForEach-Object { "$_" } | Out-String)
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
}

function Invoke-AdbCapture {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  Invoke-Capture $Name $FileName { Invoke-Adb $Arguments } | Out-Null
}

function Get-SafeFileName {
  param([Parameter(Mandatory = $true)][string]$Name)
  return ($Name.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
}

function Write-ScenarioInstructions {
  param([Parameter(Mandatory = $true)][string]$ScenarioName)
  switch ($ScenarioName) {
    "cold-start" {
      return "Wait until the app reaches the home page and becomes interactive."
    }
    "home-scroll" {
      return "Scroll the home page/list surfaces continuously."
    }
    "detail-open" {
      return "Open one comic detail page and wait for cover, chapters, thumbnails and comments preview work."
    }
    "reader-scroll" {
      return "Open the reader and scroll or turn pages continuously."
    }
    "download-sync-while-active" {
      return "Start or keep download/sync activity running, then navigate enough to expose contention."
    }
    "resume-first-operation" {
      return "Immediately after resume, turn page, favorite, save image, switch chapter, or run download/sync navigation."
    }
    default {
      return "Exercise this focused scenario."
    }
  }
}

function Get-FirstIntFromText {
  param(
    [AllowEmptyString()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern
  )
  if ($Text -match $Pattern) {
    return [int]$matches[1]
  }
  return $null
}

function Collect-ScenarioEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$ScenarioName,
    [Parameter(Mandatory = $true)][string]$Instruction,
    [int]$WindowSeconds = $DurationSeconds,
    [switch]$ColdLaunch
  )

  $safeName = Get-SafeFileName $ScenarioName
  $scenarioDir = Join-Path $OutDir $safeName
  New-Item -ItemType Directory -Force -Path $scenarioDir | Out-Null
  $scenarioSummary = Join-Path $scenarioDir "summary.md"
  Write-Utf8File $scenarioSummary "# Scenario: $ScenarioName`n`n"
  Append-Utf8File $scenarioSummary "- instruction: $Instruction`n"
  Append-Utf8File $scenarioSummary "- windowSeconds: $WindowSeconds`n"
  Append-Utf8File $scenarioSummary "- startedAt: $(Get-Date -Format o)`n"

  Write-Host ""
  Write-Host "[$ScenarioName] $Instruction"

  Invoke-AdbText @("logcat", "-c") | Out-Null
  Invoke-AdbText @("shell", "dumpsys", "gfxinfo", $Package, "reset") | Out-Null

  if ($ColdLaunch) {
    Invoke-AdbText @("shell", "am", "force-stop", $Package) | Out-Null
    $launchStart = Get-Date
    Invoke-AdbText @("shell", "monkey", "-p", $Package, "1") | Out-Null
    $launchElapsedMs = [int]((Get-Date) - $launchStart).TotalMilliseconds
    Append-Utf8File $scenarioSummary "- launchCommandMs: $launchElapsedMs`n"
  }

  $start = Get-Date
  Start-Sleep -Seconds $WindowSeconds
  $elapsedMs = [int]((Get-Date) - $start).TotalMilliseconds

  $logcatFile = Join-Path $scenarioDir "logcat.txt"
  $gfxFile = Join-Path $scenarioDir "gfxinfo.txt"
  $frameFile = Join-Path $scenarioDir "gfxinfo-framestats.txt"
  $memFile = Join-Path $scenarioDir "meminfo.txt"
  $perfFile = Join-Path $scenarioDir "perf-log-lines.txt"
  $perfSummaryFile = Join-Path $scenarioDir "perf-summary.txt"
  $crashFile = Join-Path $scenarioDir "crash-markers.txt"

  Write-Utf8File $logcatFile (Invoke-AdbText @("logcat", "-d"))
  Write-Utf8File $gfxFile (Invoke-AdbText @("shell", "dumpsys", "gfxinfo", $Package))
  Write-Utf8File $frameFile (Invoke-AdbText @("shell", "dumpsys", "gfxinfo", $Package, "framestats"))
  Write-Utf8File $memFile (Invoke-AdbText @("shell", "dumpsys", "meminfo", $Package))

  $perfLines = Select-String -Path $logcatFile -Pattern "[perf]" -SimpleMatch
  $crashPattern = "FATAL EXCEPTION|SIGSEGV|SIGABRT|ANR in|Application Not Responding|Force finishing activity|has died"
  $crashLines = Select-String -Path $logcatFile -Pattern $crashPattern -AllMatches
  Write-Utf8File $perfFile (($perfLines | Out-String))
  $perfSummary = @($perfLines | ForEach-Object {
    if ($_.Line -match "\[perf\]\s+(.*)$") {
      $matches[1]
    }
  }) -join "`n"
  Write-Utf8File $perfSummaryFile $perfSummary
  Write-Utf8File $crashFile (($crashLines | Out-String))

  $jankySummary = Select-String -Path $gfxFile -Pattern "Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Slow UI thread|Number Slow bitmap uploads|Number Slow issue draw commands" | Out-String
  Write-Utf8File (Join-Path $scenarioDir "gfxinfo-headlines.txt") $jankySummary

  $perfCount = @($perfLines).Count
  $crashCount = @($crashLines).Count
  $totalFrames = Get-FirstIntFromText $jankySummary "Total frames rendered:\s+(\d+)"
  $jankyFrames = Get-FirstIntFromText $jankySummary "Janky frames:\s+(\d+)"
  Append-Utf8File $scenarioSummary "- elapsedMs: $elapsedMs`n"
  Append-Utf8File $scenarioSummary "- perfLineCount: $perfCount`n"
  Append-Utf8File $scenarioSummary "- crashMarkerCount: $crashCount`n"
  Append-Utf8File $scenarioSummary "- artifacts: logcat.txt, perf-log-lines.txt, perf-summary.txt, crash-markers.txt, gfxinfo.txt, gfxinfo-framestats.txt, gfxinfo-headlines.txt, meminfo.txt`n"
  Append-Utf8File $scenarioSummary "- finishedAt: $(Get-Date -Format o)`n"

  Append-Utf8File $SummaryPath "`n### $ScenarioName`n`n"
  Append-Utf8File $SummaryPath "- instruction: $Instruction`n"
  Append-Utf8File $SummaryPath "- elapsedMs: $elapsedMs`n"
  Append-Utf8File $SummaryPath "- perfLineCount: $perfCount`n"
  Append-Utf8File $SummaryPath "- crashMarkerCount: $crashCount`n"
  if ($perfSummary -ne "") {
    Append-Utf8File $SummaryPath "- keyPerfTimings:`n"
    foreach ($line in ($perfSummary -split "`r?`n" | Select-Object -First 8)) {
      Append-Utf8File $SummaryPath "  - $line`n"
    }
  }
  Append-Utf8File $SummaryPath "- artifactDir: $safeName`n"

  $script:ScenarioResults += [PSCustomObject]@{
    Name = $ScenarioName
    SafeName = $safeName
    CrashCount = $crashCount
    PerfSummary = $perfSummary
    TotalFrames = $totalFrames
    JankyFrames = $jankyFrames
  }
}

function Get-PerfTimingMs {
  param(
    [AllowEmptyString()][string]$PerfSummary,
    [Parameter(Mandatory = $true)][string]$Label
  )
  foreach ($line in ($PerfSummary -split "`r?`n")) {
    if ($line -match "^\s*$([regex]::Escape($Label))\s+(\d+)ms\b") {
      return [int]$matches[1]
    }
  }
  return $null
}

function New-Candidate {
  param(
    [Parameter(Mandatory = $true)][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$Evidence,
    [Parameter(Mandatory = $true)][string]$NextStep
  )
  return [PSCustomObject]@{
    Severity = $Severity
    Scenario = $Scenario
    Evidence = $Evidence
    NextStep = $NextStep
  }
}

function Get-EvidenceBasedCandidates {
  $candidates = @()
  foreach ($result in $ScenarioResults) {
    if ($result.CrashCount -gt 0) {
      $candidates += New-Candidate "P0/P1" $result.Name "$($result.CrashCount) crash marker(s) in $($result.SafeName)/crash-markers.txt" "Open crash-markers.txt and logcat.txt, then fix the crashing stack before performance work."
    }
  }

  foreach ($result in $ScenarioResults) {
    $mainVisibleMs = Get-PerfTimingMs $result.PerfSummary "main page visible"
    if ($null -ne $mainVisibleMs -and $mainVisibleMs -ge 4000) {
      $candidates += New-Candidate "P1" $result.Name "main page visible ${mainVisibleMs}ms in $($result.SafeName)/perf-summary.txt" "Profile phaseA/phaseB and first screen data work; defer or reduce non-critical startup tasks."
    }
    $firstFrameMs = Get-PerfTimingMs $result.PerfSummary "first Flutter frame"
    if ($null -ne $firstFrameMs -and $firstFrameMs -ge 2500) {
      $candidates += New-Candidate "P1" $result.Name "first Flutter frame ${firstFrameMs}ms in $($result.SafeName)/perf-summary.txt" "Inspect Android startup and Flutter bootstrap timing before adding UI work."
    }
    $bootstrapMs = Get-PerfTimingMs $result.PerfSummary "bootstrap ready"
    if ($null -ne $bootstrapMs -and $bootstrapMs -ge 10000) {
      $candidates += New-Candidate "P1" $result.Name "bootstrap ready ${bootstrapMs}ms in $($result.SafeName)/perf-summary.txt" "Check whether long bootstrap overlaps foreground interaction; move non-critical work behind the quiet window if trace confirms contention."
    }
    $networkMs = Get-PerfTimingMs $result.PerfSummary "network ready"
    if ($null -ne $networkMs -and $networkMs -ge 10000) {
      $candidates += New-Candidate "P1" $result.Name "network ready ${networkMs}ms in $($result.SafeName)/perf-summary.txt" "Trace network initialization and cache validation before changing code."
    }
  }

  foreach ($result in $ScenarioResults) {
    if ($null -ne $result.TotalFrames -and $result.TotalFrames -ge 30 -and
        $null -ne $result.JankyFrames -and $result.JankyFrames -gt 0) {
      $percent = [math]::Round(($result.JankyFrames * 100.0) / $result.TotalFrames, 2)
      if ($percent -ge 10) {
        $candidates += New-Candidate "P1" $result.Name "$($result.JankyFrames)/$($result.TotalFrames) janky frames (${percent}%) in $($result.SafeName)/gfxinfo-headlines.txt" "Open gfxinfo framestats and matching logcat [perf] markers to identify the long frame source."
      }
    }
  }

  return @($candidates | Select-Object -First 3)
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($OutDir -eq "") {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $OutDir = Join-Path $repoRoot "build/android-profile/$timestamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$SummaryPath = Join-Path $OutDir "summary.md"

Write-Utf8File $SummaryPath "# Android Profile Harness`n`n"
Append-Utf8File $SummaryPath "- package: $Package`n"
Append-Utf8File $SummaryPath "- outDir: $OutDir`n"
Append-Utf8File $SummaryPath "- durationSeconds: $DurationSeconds`n"
Append-Utf8File $SummaryPath "- resumeIdleSeconds: $ResumeIdleSeconds`n"
Append-Utf8File $SummaryPath "- startedAt: $(Get-Date -Format o)`n"

if ((Get-Command adb -ErrorAction SilentlyContinue) -eq $null) {
  Append-Utf8File $SummaryPath "`n## Status`n`n- skipped: adb was not found on PATH.`n"
  Append-Utf8File $SummaryPath "`n## Next Fix Candidates`n`n- none: no Android evidence was captured because adb was unavailable.`n"
  Write-Host "Android profile harness skipped: adb was not found. Summary: $SummaryPath"
  exit 0
}

Invoke-Capture "Flutter Devices" "flutter-devices.txt" {
  if ((Get-Command flutter -ErrorAction SilentlyContinue) -eq $null) {
    "flutter was not found on PATH"
  } else {
    & flutter devices
  }
} | Out-Null

$adbDevices = Invoke-Capture "ADB Devices" "adb-devices.txt" { & adb devices -l }
$deviceLines = @()
foreach ($line in ($adbDevices -split "`r?`n")) {
  if ($line -match "^\s*(\S+)\s+device\s+") {
    $deviceLines += $matches[1]
  }
}

if ($Serial -eq "" -and $deviceLines.Count -gt 0) {
  $Serial = $deviceLines[0]
}
if ($Serial -ne "") {
  Append-Utf8File $SummaryPath "- selectedSerial: $Serial`n"
}

if ($Serial -eq "") {
  Append-Utf8File $SummaryPath "`n## Status`n`n- skipped: no Android adb device or emulator was connected.`n"
  Append-Utf8File $SummaryPath "`n## Next Fix Candidates`n`n- none: no Android evidence was captured because no adb target was connected.`n"
  Write-Host "Android profile harness skipped: no Android adb device. Summary: $SummaryPath"
  exit 0
}

Invoke-AdbCapture "Device Properties" "device-props.txt" @("shell", "getprop")
Invoke-AdbCapture "Package Info" "package-info.txt" @("shell", "dumpsys", "package", $Package)
Invoke-AdbCapture "Current Window" "window.txt" @("shell", "dumpsys", "window")

Append-Utf8File $SummaryPath "`n## Scenario Evidence`n`n"

if (-not $SkipLaunch) {
  Collect-ScenarioEvidence "cold-start" (Write-ScenarioInstructions "cold-start") $DurationSeconds -ColdLaunch
} else {
  Append-Utf8File $SummaryPath "### cold-start`n`n- skipped: SkipLaunch was set.`n"
}

Collect-ScenarioEvidence "home-scroll" (Write-ScenarioInstructions "home-scroll") $DurationSeconds
Collect-ScenarioEvidence "detail-open" (Write-ScenarioInstructions "detail-open") $DurationSeconds
Collect-ScenarioEvidence "reader-scroll" (Write-ScenarioInstructions "reader-scroll") $DurationSeconds
Collect-ScenarioEvidence "download-sync-while-active" (Write-ScenarioInstructions "download-sync-while-active") $DurationSeconds

if (-not $SkipResumeWait -and $ResumeIdleSeconds -gt 0) {
  Invoke-AdbCapture "Send App To Background" "background.txt" @("shell", "input", "keyevent", "KEYCODE_HOME")
  Append-Utf8File $SummaryPath "`n## Resume Wait`n`n- backgroundIdleSeconds: $ResumeIdleSeconds`n"
  Write-Host "Waiting in background for $ResumeIdleSeconds seconds before resume scenario..."
  Start-Sleep -Seconds $ResumeIdleSeconds
  Invoke-AdbCapture "Resume App" "resume.txt" @("shell", "monkey", "-p", $Package, "1")
  Collect-ScenarioEvidence "resume-first-operation" (Write-ScenarioInstructions "resume-first-operation") $DurationSeconds
} else {
  Append-Utf8File $SummaryPath "`n### resume-first-operation`n`n- skipped: SkipResumeWait was set or ResumeIdleSeconds <= 0.`n"
}

Append-Utf8File $SummaryPath "`n## Next Fix Candidates`n`n"
$candidates = Get-EvidenceBasedCandidates
if ($candidates.Count -eq 0) {
  Append-Utf8File $SummaryPath "- none: no crash marker, high-confidence `[perf]` threshold breach, or sufficient-frame gfxinfo jank was found in this run.`n"
} else {
  $index = 1
  foreach ($candidate in $candidates) {
    Append-Utf8File $SummaryPath "$index. $($candidate.Severity) $($candidate.Scenario): $($candidate.Evidence)`n"
    Append-Utf8File $SummaryPath "   Next: $($candidate.NextStep)`n"
    $index++
  }
}
Append-Utf8File $SummaryPath "`nOnly fix issues backed by these artifacts. Keep low-confidence static risks in the audit report until a log, profile, or test proves them.`n"

Append-Utf8File $SummaryPath "`n## Status`n`n- completed: local adb scenario evidence captured.`n"
Append-Utf8File $SummaryPath "- finishedAt: $(Get-Date -Format o)`n"
Write-Host "Android profile harness complete. Summary: $SummaryPath"
