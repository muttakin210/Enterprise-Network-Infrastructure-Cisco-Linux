# capture-wireshark.ps1 - open each lab pcap in Wireshark (Windows host) with a display filter,
# select a packet so the detail pane is filled, and save a PNG of the Wireshark window only.
#   powershell -ExecutionPolicy Bypass -File testing\screenshots\capture-wireshark.ps1
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$ws   = 'C:\Program Files\Wireshark\Wireshark.exe'
$out  = Join-Path $root 'screenshots\wireshark'
New-Item -ItemType Directory -Force $out | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@

# name, display filter, packet to select
$shots = @(
  @('01-ospf-adjacency',  'ospf',                      5),
  @('02-dhcp-relay',      'dhcp',                      1),
  @('03-snmpv3-authpriv', 'snmp',                      3),
  @('04-wireguard-outer', 'wg',                        3),
  @('05-wireguard-inner', 'icmp',                      1),
  @('06-syslog-plaintext','syslog',                    1)
)
foreach ($s in $shots) {
  $pcap = Join-Path $root "testing\results\pcap\$($s[0]).pcap"
  $p = Start-Process $ws -ArgumentList @('-r', "`"$pcap`"", '-Y', $s[1], '-g', $s[2]) -PassThru
  for ($i = 0; $i -lt 60 -and $p.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh() }
  Start-Sleep -Seconds 4
  $h = $p.MainWindowHandle
  [W]::SetWindowPos($h, [IntPtr]::Zero, 20, 20, 1400, 900, 0x0040) | Out-Null
  [W]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Seconds 2
  $bmp = New-Object System.Drawing.Bitmap 1400, 900
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc(); [W]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc); $g.Dispose()
  $file = Join-Path $out "$($s[0]).png"
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Stop-Process -Id $p.Id -Force
  Write-Output "saved $file"
}
