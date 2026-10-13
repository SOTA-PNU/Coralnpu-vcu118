# Board-PC side of the CoralNPU VCU118 setup.
#
# Run on the PC that has the VCU118 USB cables (J106 JTAG, J4 UART) plugged in:
#   powershell -ExecutionPolicy Bypass -File board-host.ps1
# Leave the window open. Ctrl+C stops it.
#
# It does three things and installs nothing:
#   1. checks that Windows sees the Digilent JTAG (0403:6014) and CP2105 UART (10c4:ea70)
#   2. starts Vivado's hw_server on TCP 3121 so the build VM can program the FPGA
#      and drive the RISC-V debug port over the LAN (no Vivado license needed)
#   3. bridges each CP2105 COM port to TCP (first port -> 5000, second -> 5001)
#      so the VM can read the console:  nc <this-pc-ip> 5000
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less scripts as ANSI.

param(
    [int]$HwPort   = 3121,
    [int]$UartBase = 5000,
    [int]$Baud     = 115200,
    [switch]$NoHwServer
)

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "WARN: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --- 1. USB devices -------------------------------------------------------------
$pnp = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match 'VID_0403&PID_6014|VID_10C4&PID_EA70' }
$jtag = $pnp | Where-Object { $_.PNPDeviceID -match 'VID_0403&PID_6014' }
$uart = $pnp | Where-Object { $_.PNPDeviceID -match 'VID_10C4&PID_EA70' -and $_.Name -match '\(COM\d+\)' }
if ($jtag) { Step "JTAG  : $(($jtag | Select-Object -First 1).Name)" }
else { Warn 'Digilent JTAG (0403:6014) not found. Board powered on? USB on J106?' }
if ($uart) { $uart | ForEach-Object { Step "UART  : $($_.Name)" } }
else { Warn 'CP2105 UART (10c4:ea70) not found. USB on J4? (needs the Silicon Labs CP210x driver)' }

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
       ForEach-Object { $_.IPAddress }
Step "this PC: $($ips -join ', ')"

# --- 2. hw_server ---------------------------------------------------------------
if (-not $NoHwServer) {
    if (Get-Process -Name hw_server -ErrorAction SilentlyContinue) {
        Step 'hw_server already running (Vivado Hardware Manager or an earlier run)'
    } else {
        $roots = @('C:\AMDDesignTools', 'C:\Xilinx', 'C:\Program Files\Xilinx', 'C:\Program Files\AMD', 'D:\Xilinx', 'D:\AMDDesignTools')
        $hw = Get-ChildItem -Path $roots -Filter 'hw_server.bat' -Recurse -Depth 6 -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $hw) {
            $hw = Get-ChildItem -Path $roots -Filter 'hw_server.exe' -Recurse -Depth 8 -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending | Select-Object -First 1
        }
        if (-not $hw) { Fail 'hw_server not found. Install the free "Vivado Lab Edition" (hardware server only) or point -NoHwServer and start it yourself.' }
        Step "starting $($hw.FullName) on tcp::$HwPort (separate window, keep it open)"
        Start-Process -FilePath $hw.FullName -ArgumentList '-s', "tcp::$HwPort" -WindowStyle Minimized
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name hw_server -ErrorAction SilentlyContinue)) {
            Warn 'hw_server did not stay up; run it by hand to see the error'
        }
    }
    Warn 'if Windows Firewall asks about hw_server or powershell, allow it on the private network'
}

# --- 3. serial <-> TCP bridges ----------------------------------------------------
if (-not $uart) { Step 'no UART to bridge; JTAG only. Ctrl+C to quit.'; while ($true) { Start-Sleep 60 } }

$bridges = @()
$i = 0
foreach ($u in ($uart | Sort-Object Name)) {
    $com = ([regex]::Match($u.Name, '\((COM\d+)\)')).Groups[1].Value
    $sp = New-Object System.IO.Ports.SerialPort $com, $Baud, 'None', 8, 'One'
    $sp.ReadTimeout = 10
    try { $sp.Open() } catch { Warn "cannot open $com ($($_.Exception.Message)); skipped"; continue }
    $port = $UartBase + $i
    $ln = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any), $port
    $ln.Start()
    $bridges += [pscustomobject]@{ Com = $com; Name = $u.Name; Serial = $sp; Listener = $ln; Port = $port; Client = $null; Stream = $null }
    Step "$com ($($u.Name)) <-> tcp port $port"
    $i++
}
if ($bridges.Count -eq 0) { Fail 'no COM port could be opened (another terminal program using it?)' }
Step 'ready. From the VM:  nc <this-pc-ip> 5000   (the port that prints "ROM alive" is the FPGA)'

$buf = New-Object byte[] 4096
try {
    while ($true) {
        $idle = $true
        foreach ($b in $bridges) {
            # accept a new client (replaces the old one)
            if ($b.Listener.Pending()) {
                if ($b.Client) { $b.Client.Close() }
                $b.Client = $b.Listener.AcceptTcpClient()
                $b.Client.NoDelay = $true
                $b.Stream = $b.Client.GetStream()
                Write-Host "    $($b.Com): client $($b.Client.Client.RemoteEndPoint) connected"
            }
            # serial -> tcp (bytes are dropped while no client is connected)
            $n = $b.Serial.BytesToRead
            if ($n -gt 0) {
                $idle = $false
                $n = $b.Serial.Read($buf, 0, [Math]::Min($n, $buf.Length))
                if ($b.Stream) {
                    try { $b.Stream.Write($buf, 0, $n) } catch { $b.Client.Close(); $b.Client = $null; $b.Stream = $null }
                }
            }
            # tcp -> serial
            if ($b.Stream) {
                try {
                    if ($b.Stream.DataAvailable) {
                        $idle = $false
                        $n = $b.Stream.Read($buf, 0, $buf.Length)
                        if ($n -gt 0) { $b.Serial.Write($buf, 0, $n) }
                    } elseif ($b.Client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $b.Client.Available -eq 0) {
                        Write-Host "    $($b.Com): client disconnected"
                        $b.Client.Close(); $b.Client = $null; $b.Stream = $null
                    }
                } catch { $b.Client = $null; $b.Stream = $null }
            }
        }
        if ($idle) { Start-Sleep -Milliseconds 5 }
    }
} finally {
    foreach ($b in $bridges) {
        if ($b.Client) { $b.Client.Close() }
        $b.Listener.Stop()
        $b.Serial.Close()
    }
}
