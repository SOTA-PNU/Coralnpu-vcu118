# Create the Ubuntu VM used to build and run CoralNPU on the VCU118.
#
# Run (PowerShell 5.1, normal user is fine):
#   powershell -ExecutionPolicy Bypass -File C:\Users\ehdgn\SOTA\create-vcu118-vm.ps1
# Options:
#   -VmDir D:\VMs        where the VM disk goes (needs ~300 GB free)
#   -IsoPath <file.iso>  use an Ubuntu ISO you already downloaded
#   -NoUnattended        only create the VM; install Ubuntu by hand
#
# What it does
#   1. checks VirtualBox, host RAM/CPU and free disk
#   2. downloads Ubuntu 22.04.5 desktop ISO and verifies its SHA256
#      (Vivado 2026.1 supports Ubuntu 22.04.3-.5 and 24.04-24.04.3, UG973)
#   3. creates the VM with a FIXED MAC address (the Vivado node-locked license
#      is tied to it) and a USB controller for the VCU118 JTAG/UART cables
#   4. starts an unattended Ubuntu install (VirtualBox fills in the installer)
#   5. writes the VM name, MAC and license Host ID to vcu118-vm-info.txt
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less scripts as ANSI.

param(
    [string]$VmName  = 'vcu118-dev',
    [string]$VmDir   = 'C:\VMs',
    [string]$IsoPath = '',
    [int]   $DiskGB  = 300,
    [switch]$NoUnattended
)

$ErrorActionPreference = 'Stop'
$InfoFile = Join-Path $PSScriptRoot 'vcu118-vm-info.txt'
$IsoUrl   = 'https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso'
$SumsUrl  = 'https://releases.ubuntu.com/22.04/SHA256SUMS'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }

# --- 1. VirtualBox --------------------------------------------------------------
$VBox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBox)) { Fail "VBoxManage not found at $VBox. Is VirtualBox installed?" }
function VB {
    $out = & $VBox @args 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "VBoxManage $($args -join ' ') failed:`n$out" }
    return $out
}
function VBTry { & $VBox @args 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }

Step "VirtualBox $((& $VBox --version) -join '')"

$existing = (& $VBox list vms) -join "`n"
if ($existing -match ('"' + [regex]::Escape($VmName) + '"')) {
    $mac = ((& $VBox showvminfo $VmName --machinereadable) | Select-String '^macaddress1=' ) -replace '.*="?([0-9A-Fa-f]{12})"?.*', '$1'
    Fail "VM '$VmName' already exists (MAC $mac). Delete it in VirtualBox or pass -VmName <other>."
}

# --- host resources ---------------------------------------------------------------
$cs      = Get-CimInstance Win32_ComputerSystem
$hostGB  = [math]::Floor($cs.TotalPhysicalMemory / 1GB)
$hostCpu = [int]$cs.NumberOfLogicalProcessors
$vmGB    = [math]::Min(32, [math]::Floor($hostGB / 2))
$vmCpu   = [math]::Max(2, [math]::Floor($hostCpu / 2))
Step "host: $hostGB GB RAM, $hostCpu logical CPUs -> VM: $vmGB GB, $vmCpu CPUs"
if ($vmGB -lt 16) { Warn "VM gets only $vmGB GB. Vivado P&R of the CoralNPU SoC wants 16 GB+, 32 GB recommended." }

if (-not (Test-Path $VmDir)) { New-Item -ItemType Directory -Path $VmDir | Out-Null }
$drive  = (Get-Item $VmDir).PSDrive
$freeGB = [math]::Floor($drive.Free / 1GB)
Step "free space on $($drive.Name): $freeGB GB (disk is dynamic, grows up to $DiskGB GB)"
if ($freeGB -lt 200) {
    $others = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 200GB } |
              ForEach-Object { "$($_.Name): $([math]::Floor($_.Free/1GB)) GB" }
    Fail "need about 200 GB free for Ubuntu + Vivado. Drives with room: $($others -join ', '). Re-run with -VmDir X:\VMs"
}

# --- 2. Ubuntu ISO ----------------------------------------------------------------
if ($IsoPath -eq '') {
    $IsoPath = Join-Path $VmDir 'ubuntu-22.04.5-desktop-amd64.iso'
    if (-not (Test-Path $IsoPath)) {
        Step "downloading Ubuntu ISO (~4.7 GB) to $IsoPath"
        try {
            Start-BitsTransfer -Source $IsoUrl -Destination $IsoPath -DisplayName 'Ubuntu 22.04.5 ISO'
        } catch {
            Warn "BITS download failed ($($_.Exception.Message)); falling back to Invoke-WebRequest"
            $ProgressPreference = 'SilentlyContinue'   # IWR progress bar makes it 10x slower on PS 5.1
            Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
        }
    }
}
if (-not (Test-Path $IsoPath)) { Fail "ISO not found: $IsoPath" }

Step 'verifying ISO SHA256'
$isoName = Split-Path $IsoPath -Leaf
try {
    $sums = (Invoke-WebRequest -Uri $SumsUrl -UseBasicParsing).Content
    $line = ($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($isoName) } | Select-Object -First 1
    if (-not $line) { Warn "$isoName not listed in SHA256SUMS; skipping check" }
    else {
        $want = ($line -split '\s+')[0].ToLower()
        $have = (Get-FileHash -Algorithm SHA256 $IsoPath).Hash.ToLower()
        if ($want -ne $have) { Fail "SHA256 mismatch (download corrupted?). Delete $IsoPath and re-run." }
        Write-Host "    OK $have"
    }
} catch { Warn "could not fetch SHA256SUMS ($($_.Exception.Message)); skipping check" }

# --- 3. VM ------------------------------------------------------------------------
# VirtualBox OUI 08:00:27 + random tail. Fixed so the Vivado license keeps working.
$rand = -join ((1..6) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
$Mac  = "080027$rand"

Step "creating VM '$VmName' in $VmDir"
VB createvm --name $VmName --ostype Ubuntu22_LTS_64 --register --basefolder $VmDir | Out-Null
VB modifyvm $VmName --memory ($vmGB * 1024) --cpus $vmCpu --vram 128 `
   --graphicscontroller vmsvga --ioapic on --rtcuseutc on `
   --nic1 nat --macaddress1 $Mac `
   --clipboard-mode bidirectional --drag-and-drop bidirectional | Out-Null

$disk = Join-Path (Join-Path $VmDir $VmName) "$VmName.vdi"
VB createmedium disk --filename $disk --size ($DiskGB * 1024) --format VDI | Out-Null
VB storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 2 | Out-Null
VB storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $disk | Out-Null
VB storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $IsoPath | Out-Null

# USB for the VCU118 cables. The Extension Pack is not allowed here. VBoxManage
# accepts any controller setting, but a controller whose implementation lives in
# the Extension Pack makes the VM refuse to START ("Implementation of the USB x.0
# controller not found"). So test-boot the empty VM with each controller.
function UsbOff { VBTry modifyvm $VmName --usbxhci off --usbehci off --usbohci off | Out-Null }
function BootsOk {
    if (-not (VBTry startvm $VmName --type headless)) { return $false }
    Start-Sleep -Seconds 4
    VBTry controlvm $VmName poweroff | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        $st = (& $VBox showvminfo $VmName --machinereadable) | Select-String '^VMState='
        if ("$st" -match 'poweroff|aborted') { break }
        Start-Sleep -Seconds 1
    }
    return $true
}
$usb = 'none'
foreach ($c in @('--usbxhci', '--usbehci', '--usbohci')) {
    UsbOff
    if (-not (VBTry modifyvm $VmName $c on)) { continue }
    if (BootsOk) { $usb = $c.TrimStart('-'); break }
    Warn "VM does not start with $($c.TrimStart('-')); trying the next USB controller"
}
if ($usb -eq 'none') {
    UsbOff
    Warn 'no USB controller works; OpenOCD will not see the board from the VM'
} else {
    Step "USB controller: $usb"
    # Auto-attach the two VCU118 USB devices whenever they are plugged in.
    VBTry usbfilter add 0 --target $VmName --name 'VCU118 JTAG (Digilent SMT2-NC)' --vendorid 0403 --productid 6014 | Out-Null
    VBTry usbfilter add 1 --target $VmName --name 'VCU118 UART (CP2105)' --vendorid 10c4 --productid ea70 | Out-Null
}

# --- 5. record what the license needs ---------------------------------------------
$macColon = ($Mac -split '(..)' | Where-Object { $_ }) -join ':'
@"
VM name        : $VmName
VM folder      : $(Join-Path $VmDir $VmName)
MAC (fixed)    : $macColon
License HostID : $Mac      <- paste this into AMD 'Generate Node-Locked License'
RAM / CPUs     : $vmGB GB / $vmCpu
USB controller : $usb
Created        : $(Get-Date -Format 'yyyy-MM-dd HH:mm')
"@ | Set-Content -Path $InfoFile -Encoding ASCII
Step "wrote $InfoFile"

# --- 4. unattended install ---------------------------------------------------------
if ($NoUnattended) {
    VB startvm $VmName --type gui | Out-Null
    Step 'VM started; install Ubuntu by hand (choose "Normal installation", English).'
} else {
    $user = Read-Host 'Linux user name for the VM (lowercase, e.g. ehdgn)'
    if ($user -notmatch '^[a-z][a-z0-9_-]{0,31}$') { Fail "invalid Linux user name '$user'" }
    $sec  = Read-Host 'Password for that user (also used for sudo)' -AsSecureString
    $pw   = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ($pw.Length -lt 4) { Fail 'password too short' }
    $pwFile = Join-Path $env:TEMP "vbox-pw-$([guid]::NewGuid()).txt"
    [IO.File]::WriteAllText($pwFile, $pw)
    # VirtualBox 7.1 renamed --password-file to --user-password-file; use whichever this one knows.
    $help = (& $VBox unattended install --help 2>&1) -join "`n"
    $pwOpt = '--password-file'
    if ($help -match '--user-password-file') { $pwOpt = '--user-password-file' }
    try {
        Step 'starting unattended Ubuntu install (20-40 min, the VM window shows progress)'
        & $VBox unattended install $VmName --iso=$IsoPath --user=$user "$pwOpt=$pwFile" `
            --full-user-name=$user --hostname="$VmName.local" --locale=en_US --country=KR `
            --time-zone=Asia/Seoul --install-additions --start-vm=gui 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            Warn 'unattended install could not start; booting the ISO for a manual install instead'
            VB startvm $VmName --type gui | Out-Null
        }
    } finally {
        Remove-Item $pwFile -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "DONE. License Host ID: $Mac   (also in $InfoFile)" -ForegroundColor Green
