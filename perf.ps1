<#
.SYNOPSIS
  Mesure les performances de boot et d'exécution d'une VM sous QEMU/TCG (sans accélération matérielle).
  Conçu pour être lancé sur un vieux PC et comparer les machines / les variantes d'image.

.DESCRIPTION
  Pour chaque run, chaque variante d'image (non compressée / compressée) et chaque modèle de CPU,
  la VM est démarrée en mode snapshot (rien n'est écrit dans les images) sur des ports libres,
  puis arrêtée. Mesures:
    - t_prompt : démarrage de QEMU -> prompt shell sur la console série (autologin)
    - t_ssh    : -> bannière SSH disponible
    - t_http_N : -> le port invité N (autre que 22) répond en HTTP (ex: le lab ttyd)
    - kernel / userspace : systemd-analyze (dans la VM)
    - cpu_ms   : sha256 de 128 Mo (calcul pur)        -> plus petit = mieux
    - fork_ms  : 100 fork+exec de /bin/true            -> coût des processus
    - disk_ms  : lecture séquentielle de 256 Mo du disque, cache invité vidé (image compressée vs non)
  Résultats: tableau récapitulatif (médianes) + perf\perf-<PC>-<date>.json et .csv

.PARAMETER Vm        Spec dans VMs\ (sans .yml). Défaut: vm_debian_docker
.PARAMETER Runs      Nombre de runs par configuration (défaut 3). Le 1er run est le plus "à froid" (cache disque de l'hôte).
.PARAMETER Variants  uncompressed, compressed (défaut: les deux)
.PARAMETER CpuModels Modèles de CPU QEMU à comparer (défaut: max). Ex: -CpuModels max,qemu64
.PARAMETER Memory    RAM de la VM en Mo (défaut 1024)
.PARAMETER Cpus      vCPU (défaut 2)
.PARAMETER TimeoutSec Délai max par jalon de boot (défaut 900: prévu pour de très vieux PC)

.EXAMPLE
  .\perf.ps1
  .\perf.ps1 -Runs 2 -CpuModels max,qemu64
  .\perf.ps1 -Vm vm_debian_min -Variants uncompressed
#>
param(
  [string]$Vm = "vm_debian_docker",
  [int]$Runs = 3,
  [ValidateSet("uncompressed", "compressed")][string[]]$Variants = @("uncompressed", "compressed"),
  [string[]]$CpuModels = @("max"),
  [int]$Memory = 1024,
  [int]$Cpus = 2,
  [int]$TimeoutSec = 900
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# ------------------------------------------------------------------ configuration
$info = python "$root\scripts\vm_info.py" $Vm | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $info) { throw "Lecture de VMs\$Vm.yml impossible (python + PyYAML requis)" }
$qemu = Join-Path $info.dir_qemu "qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) { throw "QEMU introuvable: $qemu" }

$images = [ordered]@{}
foreach ($v in $Variants) {
  $f = if ($v -eq "compressed") { $info.img_compressed } else { $info.img }
  if (Test-Path $f) { $images[$v] = $f } else { Write-Warning "Image absente, variante ignorée: $f" }
}
if ($images.Count -eq 0) { throw "Aucune image à tester (python scripts\build.py $Vm)" }

# ports invités à surveiller (hôte:invité -> on ne garde que l'invité, l'hôte reçoit un port libre)
$guestPorts = @($info.ports | ForEach-Object { [int](($_ -split ":")[1]) })
$sshPort = 22
if ($guestPorts -notcontains 22) { $guestPorts += 22 }
$httpPorts = @($guestPorts | Where-Object { $_ -ne 22 })

# clé SSH: copie avec ACL restreinte (OpenSSH Windows refuse une clé lisible par d'autres)
$hasSsh = [bool](Get-Command ssh.exe -ErrorAction SilentlyContinue) -and (Test-Path $info.key)
$keyCopy = Join-Path $env:TEMP "perf_key_$PID"
if ($hasSsh) {
  Copy-Item $info.key $keyCopy -Force
  & icacls $keyCopy /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
} else { Write-Warning "ssh.exe ou clé absente: mesures dans la VM ignorées (jalons de boot seulement)" }

# ------------------------------------------------------------------ infos machine hôte
function Get-HostInfo {
  $h = [ordered]@{ pc = $env:COMPUTERNAME; date = (Get-Date).ToString("s") }
  try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $h.cpu = $cpu.Name.Trim(); $h.cores = $cpu.NumberOfCores; $h.threads = $cpu.NumberOfLogicalProcessors
    $h.cpu_mhz = $cpu.MaxClockSpeed
    $h.ram_mb = [int]($cs.TotalPhysicalMemory / 1MB); $h.ram_free_mb = [int]($os.FreePhysicalMemory / 1KB)
    $h.hypervisor_present = $cs.HypervisorPresent
    $h.os = "$($os.Caption) $($os.Version)"
  } catch { $h.error_cim = $_.Exception.Message }
  try {
    $letter = (Get-Item $root).PSDrive.Name
    $disk = Get-Partition -DriveLetter $letter | Get-Disk | Get-PhysicalDisk
    $h.disk = "$($disk.FriendlyName) $($disk.MediaType) $($disk.BusType)"
  } catch { $h.disk = "inconnu" }
  try { $h.qemu = (& $qemu --version | Select-Object -First 1) } catch {}
  $h.power_plan = try { (powercfg /getactivescheme) -replace '^.*: ', '' } catch { "?" }
  [pscustomobject]$h
}

# ------------------------------------------------------------------ utilitaires
function Get-FreePort {
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p
}

function Read-Shared([string]$path) {
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object IO.StreamReader($fs); $t = $sr.ReadToEnd(); $sr.Close(); $t
  } catch { "" }
}

# Se connecte, envoie $send (optionnel), lit le début de la réponse: vrai si elle commence par $expect
function Test-Banner([int]$port, [string]$send, [string]$expect) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect("127.0.0.1", $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(400)) { return $false }
    $c.EndConnect($iar)
    $s = $c.GetStream(); $s.ReadTimeout = 800; $s.WriteTimeout = 800
    if ($send) { $b = [Text.Encoding]::ASCII.GetBytes($send); $s.Write($b, 0, $b.Length) }
    $buf = New-Object byte[] 16; $n = $s.Read($buf, 0, 16)
    return ($n -gt 0 -and [Text.Encoding]::ASCII.GetString($buf, 0, $n).StartsWith($expect))
  } catch { return $false } finally { $c.Close() }
}

# "Startup finished in 3.5s (kernel) + 1min 5.3s (userspace) = 1min 8.8s" -> secondes
function ConvertTo-Sec([string]$t) {
  $sec = 0.0
  if ($t -match '([\d.]+)\s*min') { $sec += 60 * [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
  if ($t -match '([\d.]+)\s*s(?!\w)') { $sec += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
  elseif ($t -match '([\d.]+)\s*ms') { $sec += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) / 1000 }
  [math]::Round($sec, 2)
}

function Get-Median($values) {
  $v = @($values | Where-Object { $null -ne $_ } | Sort-Object)
  if ($v.Count -eq 0) { return $null }
  $m = [int][math]::Floor($v.Count / 2)
  if ($v.Count % 2) { $v[$m] } else { [math]::Round(($v[$m - 1] + $v[$m]) / 2, 2) }
}

# Script exécuté dans la VM (via ssh, sur stdin). Sortie: clé=valeur
$guestScript = @'
true
echo boot_time="$(systemd-analyze time 2>/dev/null | head -1)"
echo guest_cpus=$(nproc)
echo guest_mem_mb=$(free -m | awk '/Mem:/{print $2}')
s=$(date +%s%N); head -c 134217728 /dev/zero | sha256sum >/dev/null; e=$(date +%s%N); echo cpu_ms=$(( (e-s)/1000000 ))
s=$(date +%s%N); for i in $(seq 1 100); do /bin/true; done; e=$(date +%s%N); echo fork_ms=$(( (e-s)/1000000 ))
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
s=$(date +%s%N); sudo dd if=/dev/vda1 of=/dev/null bs=1M count=256 2>/dev/null; e=$(date +%s%N); echo disk_ms=$(( (e-s)/1000000 ))
'@ -replace "`r`n", "`n"

# ------------------------------------------------------------------ un run
function Invoke-Run([string]$variant, [string]$img, [string]$cpuModel, [int]$run) {
  $res = [ordered]@{ vm = $Vm; variant = $variant; cpu_model = $cpuModel; run = $run
    t_prompt = $null; t_ssh = $null; kernel_s = $null; userspace_s = $null
    cpu_ms = $null; fork_ms = $null; disk_ms = $null; error = $null }
  foreach ($gp in $httpPorts) { $res["t_http_$gp"] = $null }

  $serial = Join-Path $env:TEMP "perf_serial_$PID.log"
  Remove-Item $serial -ErrorAction SilentlyContinue
  $map = @{}; foreach ($gp in $guestPorts) { $map[$gp] = Get-FreePort }
  $fwd = ($guestPorts | ForEach-Object { "hostfwd=tcp:127.0.0.1:$($map[$_])-:$_" }) -join ","
  $qargs = "-machine pc -accel tcg,thread=multi -cpu $cpuModel -smp $Cpus -m $Memory " +
    "-drive `"file=$img,if=virtio,format=qcow2,snapshot=on`" " +
    "-netdev `"user,id=net0,$fwd`" -device virtio-net-pci,netdev=net0 " +
    "-display none -serial `"file:$serial`" -monitor none"

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $qemu -ArgumentList $qargs -PassThru -WindowStyle Hidden
  try {
    $pending = @("t_prompt", "t_ssh") + @($httpPorts | ForEach-Object { "t_http_$_" })
    while ($pending.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
      if ($p.HasExited) { throw "QEMU s'est arrêté (code $($p.ExitCode))" }
      Start-Sleep -Milliseconds 400
      $now = [math]::Round($sw.Elapsed.TotalSeconds, 2)
      foreach ($m in @($pending)) {
        $ok = switch -Regex ($m) {
          '^t_prompt$' { (Read-Shared $serial) -match '\S+@\S+:\S*[\$#]' }
          '^t_ssh$'    { Test-Banner $map[$sshPort] $null "SSH-" }
          '^t_http_(\d+)$' { Test-Banner $map[[int]$Matches[1]] "GET / HTTP/1.0`r`n`r`n" "HTTP/" }
        }
        if ($ok) { $res[$m] = $now; $pending = @($pending | Where-Object { $_ -ne $m }) }
      }
    }
    if ($pending.Count -gt 0) { $res.error = "jalons non atteints: $($pending -join ', ')" }

    if ($hasSsh -and $res.t_ssh) {
      $sshArgs = @("-i", $keyCopy, "-p", $map[$sshPort], "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
        "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=30",
        "$($info.user)@127.0.0.1", "bash -s")
      $out = $null
      for ($try = 0; $try -lt 5 -and -not $out; $try++) {
        $ErrorActionPreference = "Continue"   # le stderr de ssh ne doit pas lever d'exception
        $out = $guestScript | & ssh.exe @sshArgs 2>$null
        $ErrorActionPreference = "Stop"
        if (-not $out) { Start-Sleep 3 }
      }
      foreach ($line in @($out)) {
        if ($line -match '^(\w+)=(.*)$') {
          $key = $Matches[1]; $val = $Matches[2]   # ($Matches est écrasé par les -match suivants)
          switch ($key) {
            "boot_time" {
              if ($val -match '\(kernel\)') {
                $parts = $val -split '\+'
                $res.kernel_s = ConvertTo-Sec ($parts[0] -replace '^.*in', '')
                $res.userspace_s = ConvertTo-Sec $parts[1]
              }
            }
            "cpu_ms" { $res.cpu_ms = [int]$val }
            "fork_ms" { $res.fork_ms = [int]$val }
            "disk_ms" { $res.disk_ms = [int]$val }
          }
        }
      }
      if ($null -eq $res.cpu_ms) { $res.error = (($res.error, "mesures SSH vides") | Where-Object { $_ }) -join "; " }
    }
  } catch {
    $res.error = $_.Exception.Message
  } finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $null = $p.WaitForExit(10000) }
    Remove-Item $serial -ErrorAction SilentlyContinue
  }
  [pscustomobject]$res
}

# ------------------------------------------------------------------ exécution
$hostInfo = Get-HostInfo
Write-Host "=== Machine: $($hostInfo.pc) | $($hostInfo.cpu) | $($hostInfo.threads) threads | $($hostInfo.ram_mb) Mo RAM | $($hostInfo.disk)"
Write-Host "=== VM: $Vm | $Cpus vCPU, $Memory Mo | variantes: $($images.Keys -join ', ') | cpu: $($CpuModels -join ', ') | runs: $Runs"
foreach ($k in $images.Keys) { Write-Host ("    {0,-13} {1,7:N0} Mo  {2}" -f $k, ((Get-Item $images[$k]).Length / 1MB), $images[$k]) }
Write-Host "Ne pas utiliser le PC pendant la mesure (résultats faussés). Ctrl+C pour interrompre.`n"

$results = New-Object System.Collections.ArrayList
try {
  for ($r = 1; $r -le $Runs; $r++) {
    foreach ($cpu in $CpuModels) {
      foreach ($v in $images.Keys) {
        Write-Host ("run {0}/{1}  {2,-12} cpu={3,-7} ... " -f $r, $Runs, $v, $cpu) -NoNewline
        $x = Invoke-Run $v $images[$v] $cpu $r
        [void]$results.Add($x)
        if ($x.error) { Write-Host "ERREUR: $($x.error)" -ForegroundColor Yellow }
        else { Write-Host ("prompt {0}s  ssh {1}s  cpu {2}ms  disk {3}ms" -f $x.t_prompt, $x.t_ssh, $x.cpu_ms, $x.disk_ms) }
      }
    }
  }
} finally {
  if ($hasSsh) { Remove-Item $keyCopy -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ résumé + sauvegarde
$cols = @("t_prompt", "t_ssh") + @($httpPorts | ForEach-Object { "t_http_$_" }) + @("kernel_s", "userspace_s", "cpu_ms", "fork_ms", "disk_ms")
$summary = $results | Group-Object variant, cpu_model | ForEach-Object {
  $g = $_.Group
  $o = [ordered]@{ variante = $g[0].variant; cpu = $g[0].cpu_model; ok = @($g | Where-Object { -not $_.error }).Count; runs = $g.Count }
  foreach ($c in $cols) { $o[$c] = Get-Median ($g | ForEach-Object { $_.$c }) }
  [pscustomobject]$o
}
Write-Host "`n=== Médianes (secondes pour t_*, kernel_s, userspace_s; millisecondes pour *_ms) ==="
Write-Host "-- Démarrage (secondes) --"
$bootCols = @("variante", "cpu", "ok", "runs", "t_prompt", "t_ssh") + @($httpPorts | ForEach-Object { "t_http_$_" }) + @("kernel_s", "userspace_s")
$summary | Select-Object $bootCols | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "-- Exécution dans la VM (millisecondes, plus petit = mieux) --"
$summary | Select-Object variante, cpu, cpu_ms, fork_ms, disk_ms | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$outDir = Join-Path $root "perf"
New-Item -ItemType Directory -Force $outDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$base = Join-Path $outDir "perf-$($env:COMPUTERNAME)-$stamp"
[pscustomobject]@{ host = $hostInfo; vm = $Vm; memory_mb = $Memory; vcpus = $Cpus
  images = ($images.Keys | ForEach-Object { [pscustomobject]@{ variant = $_; path = $images[$_]; size_mb = [int]((Get-Item $images[$_]).Length / 1MB) } })
  runs = $results; summary = $summary } | ConvertTo-Json -Depth 6 | Set-Content "$base.json" -Encoding UTF8
$results | Export-Csv "$base.csv" -NoTypeInformation -Encoding UTF8
Write-Host "Résultats: $base.json"
Write-Host "           $base.csv"
