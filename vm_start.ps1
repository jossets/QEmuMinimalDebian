<#
.SYNOPSIS
  Démarre une VM construite par scripts/build.py, sous QEMU (TCG, sans accélération matérielle).

.PARAMETER Vm
  Nom de la spec dans VMs/ (sans .yml). Défaut: vm_debian_docker

.PARAMETER Compressed
  Utilise l'image compressée (<img>-compressed.qcow2) au lieu de l'image non compressée.

.PARAMETER Reset
  Supprime la couche d'écriture de la VM (VMs/overlays/<vm>.qcow2) avant de démarrer:
  retour à l'état de l'image de référence.

.PARAMETER Snapshot
  Écritures jetées à l'arrêt (aucune couche conservée).

L'image de référence VMs/qcow2/<img> n'est jamais modifiée: la VM démarre sur une couche
qcow2 (backing file) qui contient seulement ses écritures. Reset = supprimer cette couche.

.PARAMETER DryRun
  Affiche la commande QEMU sans la lancer.

.EXAMPLE
  .\vm_start.ps1
  .\vm_start.ps1 -Vm vm_debian_min -Snapshot
#>
param(
  [string]$Vm = "vm_debian_docker",
  [int]$Memory = 1024,
  [int]$Cpus = 2,
  [switch]$Compressed,
  [switch]$Reset,
  [switch]$Snapshot,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# conf.yml + VMs/<vm>.yml (YAML lu par Python/PyYAML, comme build.py)
$info = python "$root\scripts\vm_info.py" $Vm | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $info) { throw "Lecture de VMs\$Vm.yml impossible" }

if ($Compressed) { $info.img = $info.img_compressed; $suffix = "-compressed" } else { $suffix = "" }
$qemu = Join-Path $info.dir_qemu "qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) { throw "QEMU introuvable: $qemu" }
if (-not (Test-Path $info.img)) { throw "Image absente: $($info.img) (python scripts\build.py $Vm)" }

# ports: "hôte:invité" -> hostfwd, accessible uniquement depuis cette machine (127.0.0.1)
$fwd = ($info.ports | ForEach-Object {
  $p = $_ -split ":"
  if ($p.Count -ne 2) { throw "Port invalide '$_' (attendu hôte:invité)" }
  "hostfwd=tcp:127.0.0.1:$($p[0])-:$($p[1])"
}) -join ","

# Couche d'écriture (copy-on-write) au-dessus de l'image de référence
$qimg = Join-Path $info.dir_qemu "qemu-img.exe"
$overlay = Join-Path $root "VMs\overlays\$Vm$suffix.qcow2"
if ($Snapshot) {
  $drive = "file=$($info.img),if=virtio,format=qcow2,snapshot=on"
} else {
  New-Item -ItemType Directory -Force (Split-Path $overlay) | Out-Null
  if ($Reset -and (Test-Path $overlay)) { Remove-Item $overlay -Force; Write-Host "Couche supprimée: retour à l'image de référence" }
  # une image de référence reconstruite plus récemment rend la couche invalide
  if ((Test-Path $overlay) -and ((Get-Item $info.img).LastWriteTime -gt (Get-Item $overlay).CreationTime)) {
    Write-Host "Image de référence plus récente que la couche: couche recréée"
    Remove-Item $overlay -Force
  }
  if (-not (Test-Path $overlay)) {
    # chemin relatif: le dépôt peut être déplacé sans casser la couche
    $rel = "../qcow2/" + (Split-Path $info.img -Leaf)
    & $qimg create -q -f qcow2 -b $rel -F qcow2 $overlay
    if ($LASTEXITCODE -ne 0) { throw "Création de la couche impossible" }
  }
  $drive = "file=$overlay,if=virtio,format=qcow2"
}

$qemuArgs = @(
  "-machine", "pc",
  "-accel", "tcg,thread=multi",
  "-cpu", "max",
  "-smp", $Cpus,
  "-m", $Memory,
  "-drive", $drive,
  "-netdev", "user,id=net0,$fwd",
  "-device", "virtio-net-pci,netdev=net0",
  "-nographic"
)

Write-Host "VM $($info.hostname): " -NoNewline
Write-Host (($info.ports | ForEach-Object { "127.0.0.1:" + ($_ -split ":")[0] + " -> VM:" + ($_ -split ":")[1] }) -join "  ")
Write-Host "Quitter QEMU: Ctrl+A puis X`n"

if ($DryRun) { Write-Host "$qemu $($qemuArgs -join ' ')"; return }
& $qemu @qemuArgs
