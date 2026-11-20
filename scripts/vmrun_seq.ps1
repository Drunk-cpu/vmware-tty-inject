<#
.SYNOPSIS
    Replay a command sequence inside a running VMware guest's GUI terminal,
    typing each line into the shell's TTY and capturing a screenshot on demand.

.DESCRIPTION
    Host side orchestrator.  It copies the guest-side scripts into the VM,
    opens a terminal window in the graphical session, then pushes every line
    of the sequence file through tty_inject.py (TIOCSTI), waiting between
    lines and grabbing the guest screen with vmrun captureScreen.

.EXAMPLE
    .\vmrun_seq.ps1 -Seq .\examples\demo.txt -OutDir .\out

.NOTES
    Sequence format: one command per line.  A line containing only #SHOT
    takes a screenshot at that point.  Lines starting with # are comments.
#>
param(
    [Parameter(Mandatory = $true)][string]$Seq,
    [string]$Config = "",
    [string]$OutDir = "",
    [int]$WaitMs = 3200,
    [switch]$NoOpenTerm,
    [switch]$Start
)

$ErrorActionPreference = "Stop"

if (-not $Config) { $Config = Join-Path (Split-Path $PSScriptRoot -Parent) "config.local.json" }
if (-not (Test-Path -LiteralPath $Config)) {
    throw "config not found: $Config (copy config.example.json to config.local.json first)"
}
$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($k in @("vmx", "vmrun", "guest_user", "guest_pass")) {
    if (-not $cfg.$k) { throw "config is missing '$k'" }
}

if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) "out" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$guestDir = if ($cfg.guest_dir) { $cfg.guest_dir } else { "/tmp/tti" }
$vmrun = $cfg.vmrun
$vmx = $cfg.vmx
$gu = $cfg.guest_user
$gp = $cfg.guest_pass

function Vm {
    param([string[]]$VmArgs)
    & $vmrun -T ws -gu $gu -gp $gp @VmArgs
    if ($LASTEXITCODE -ne 0) { Write-Warning "vmrun failed: $($VmArgs[0])" }
}

function PushFile {
    param([string]$Local, [string]$Name)
    Vm @("copyFileFromHostToGuest", $vmx, $Local, "$guestDir/$Name")
}

# --- preflight -------------------------------------------------------------
$tools = ""
try { $tools = (& $vmrun -T ws checkToolsState $vmx 2>$null) -join "" } catch { $tools = "" }
if ($tools -notmatch "running") {
    if ($Start) {
        Write-Host "powering on $vmx ..."
        & $vmrun -T ws start $vmx gui | Out-Null
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 5
            try { $tools = (& $vmrun -T ws checkToolsState $vmx 2>$null) -join "" } catch { $tools = "" }
            if ($tools -match "running") { break }
        }
        if ($tools -notmatch "running") { throw "VM powered on but VMware Tools never became ready" }
        Write-Host "VM is up, waiting for the desktop session..."
        Start-Sleep -Seconds 15
    } else {
        throw "VM not ready (powered off or VMware Tools down). Re-run with -Start to power it on."
    }
}

# --- prepare guest ---------------------------------------------------------
$null = Vm @("runProgramInGuest", $vmx, "/bin/sh", "-c", "mkdir -p '$guestDir' && chmod 700 '$guestDir'")

$src = $PSScriptRoot
foreach ($f in @("tty_inject.py", "open_term.sh")) {
    PushFile (Join-Path $src $f) $f
}
Vm @("runProgramInGuest", $vmx, "/bin/sh", "-c", "chmod +x '$guestDir/tty_inject.py' '$guestDir/open_term.sh'")

# sudo password for TIOCSTI, kept in a 0600 file and deleted afterwards
$pwLocal = Join-Path $env:TEMP ("tti_pw_" + [guid]::NewGuid().ToString("N") + ".txt")
[System.IO.File]::WriteAllText($pwLocal, $gp, (New-Object System.Text.UTF8Encoding($false)))
Vm @("copyFileFromHostToGuest", $vmx, $pwLocal, "/tmp/.tti_pw")
Remove-Item -LiteralPath $pwLocal -Force
Vm @("runProgramInGuest", $vmx, "/bin/sh", "-c", "chmod 600 /tmp/.tti_pw")

# --- terminal --------------------------------------------------------------
if (-not $NoOpenTerm) {
    Write-Host "opening terminal in guest..."
    Vm @("runProgramInGuest", $vmx, "/bin/bash", "$guestDir/open_term.sh")
    Start-Sleep -Milliseconds 1500
}

# --- replay ----------------------------------------------------------------
$lines = Get-Content -LiteralPath $Seq -Encoding UTF8
$idx = 0
$shot = 0

function Capture {
    param([int]$n)
    $path = Join-Path $OutDir ("shot_{0:D2}.png" -f $n)
    Vm @("captureScreen", $vmx, $path)
    Write-Host "screenshot -> $path"
}

foreach ($raw in $lines) {
    $line = $raw.TrimEnd()
    $trim = $line.Trim()
    if ($trim -eq "") { continue }
    if ($trim.StartsWith("#") -and $trim -ne "#SHOT") { continue }
    if ($trim -eq "#SHOT") { $shot++; Capture $shot; continue }

    $idx++
    $cmdLocal = Join-Path $env:TEMP ("tti_cmd_" + $idx + ".txt")
    [System.IO.File]::WriteAllText($cmdLocal, $line, (New-Object System.Text.UTF8Encoding($false)))
    Vm @("copyFileFromHostToGuest", $vmx, $cmdLocal, "$guestDir/cmd.txt")
    Remove-Item -LiteralPath $cmdLocal -Force
    $null = Vm @("runProgramInGuest", $vmx, "/bin/python3", "$guestDir/tty_inject.py", "--file", "$guestDir/cmd.txt")
    Write-Host ("[{0}] {1}" -f $idx, $line)
    Start-Sleep -Milliseconds $WaitMs
}

$shot++
Capture $shot
Write-Host "done: $idx commands, $shot screenshots -> $OutDir"

# --- cleanup ---------------------------------------------------------------
$null = Vm @("runProgramInGuest", $vmx, "/bin/sh", "-c", "rm -f /tmp/.tti_pw '$guestDir/cmd.txt'")
