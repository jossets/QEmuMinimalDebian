#!/usr/bin/env python3
"""Construit une image qcow2 Debian minimale à partir d'une spec VMs/vm_<nom>.yml.

Pipeline (cf. README):
  1. télécharge l'image cloud Debian (cache dans cache/, SHA512 vérifié)
  2. génère user-data/meta-data (NoCloud, servis en HTTP local via SMBIOS: pas d'ISO à fabriquer)
  3. boot QEMU (TCG) avec SSH redirigé 127.0.0.1:2222 -> 22
  4. attend SSH, pousse et exécute scripts/setup.sh en root
  5. attend l'arrêt, produit deux images dans VMs/qcow2/: <img> (non compressée)
     et <img>-compressed.qcow2 (compressée zstd, plus petite à distribuer)

Usage:  python scripts/build.py vm_debian_min [--keep-work]
"""
import argparse
import functools
import hashlib
import http.server
import os
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SSH_PORT, HTTP_PORT = 2222, 8000


def log(m):
    print(f"\n=== {m}", flush=True)


def download(url: str, dest: Path):
    if dest.exists():
        print(f"cache: {dest.name}")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"Téléchargement {url}")
    tmp = dest.with_suffix(".part")
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(dest)


def verify_sha512(base_url: str, name: str, f: Path):
    try:
        sums = urllib.request.urlopen(base_url + "SHA512SUMS", timeout=30).read().decode()
    except Exception as e:
        print(f"(SHA512SUMS indisponible: {e}) vérification ignorée")
        return
    want = next((l.split()[0] for l in sums.splitlines() if l.endswith(" " + name)), None)
    if not want:
        print("(pas de somme pour ce fichier)")
        return
    h = hashlib.sha512()
    with open(f, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != want:
        f.unlink()
        sys.exit("SHA512 invalide: image supprimée du cache, relancer.")
    print("SHA512 ok")


def cloud_init_files(spec: dict, d: Path):
    users = []
    for u in spec["users"]:
        pub = (ROOT / "VMs" / u["id_rsa_pub"]).read_text().strip()
        e = {"name": u["name"], "shell": "/bin/bash", "lock_passwd": True, "ssh_authorized_keys": [pub]}
        if u.get("sudo"):
            e["sudo"] = "ALL=(ALL) NOPASSWD:ALL"
        users.append(e)
    (d / "meta-data").write_text(f"instance-id: build-{int(time.time())}\nlocal-hostname: {spec['hostname']}\n")
    (d / "user-data").write_text(
        "#cloud-config\n" + yaml.safe_dump({"users": users, "ssh_pwauth": False, "package_update": False})
    )


def private_key_copy(src: Path, work: Path) -> Path:
    """OpenSSH sous Windows refuse une clé lisible par d'autres: copie avec ACL restreinte."""
    dst = work / "id_build"
    shutil.copyfile(src, dst)
    if os.name == "nt":
        subprocess.run(
            ["icacls", str(dst), "/inheritance:r", "/grant:r", f"{os.environ['USERNAME']}:F"],
            check=True, stdout=subprocess.DEVNULL,
        )
    else:
        dst.chmod(0o600)
    return dst


def clean_work(work: Path):
    """Supprime work/, y compris une clé dont l'ACL a été restreinte."""
    def fix(func, path, *_):
        if os.name == "nt":
            subprocess.run(["icacls", str(path), "/grant:r", f"{os.environ['USERNAME']}:F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(path, 0o700)
        func(path)
    if work.exists():
        shutil.rmtree(work, onexc=fix)


def wait_ssh(port, timeout, proc):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            sys.exit("QEMU s'est arrêté prématurément")
        try:
            with socket.create_connection(("127.0.0.1", port), 2) as s:
                s.settimeout(10)
                if s.recv(4).startswith(b"SSH"):
                    return
        except OSError:
            pass
        time.sleep(5)
    sys.exit("Timeout en attendant SSH")


def build_docker_images(spec: dict) -> list:
    """Build sur l'hôte (Docker Desktop). 'lab_ttyd_base:latest' <- Dockers/lab-ttyd-base/."""
    images = spec.get("docker_images") or []
    for img in images:
        ctx = ROOT / "Dockers" / img.split(":")[0].replace("_", "-")
        if not (ctx / "Dockerfile").exists():
            sys.exit(f"Pas de Dockerfile pour {img}: {ctx}")
        log(f"docker build {img}  ({ctx.relative_to(ROOT)})")
        subprocess.run(["docker", "build", "--platform", "linux/amd64", "-t", img, str(ctx)], check=True)
    return images


def image_tar_stream(images, ssh):
    """docker save (hôte) | ssh 'docker load' (VM), sans fichier intermédiaire."""
    save = subprocess.Popen(["docker", "save", *images], stdout=subprocess.PIPE)
    load = subprocess.Popen([*ssh, "sudo docker load"], stdin=save.stdout)
    save.stdout.close()
    if load.wait() != 0 or save.wait() != 0:
        sys.exit("Échec du transfert des images docker")


def provision(spec, ssh, opts, target, user, stream):
    """Images docker, fichiers, et script de démarrage (cmd:) installé dans la VM."""
    images = spec.get("_images") or []
    if images:
        log(f"Upload des images docker dans la VM: {', '.join(images)}")
        stream(images, ssh)
    for f in spec.get("files") or []:
        src = ROOT / "Dockers" / f
        if not src.is_file():
            sys.exit(f"Fichier introuvable: {src}")
        log(f"Copie {f} -> ~/{f}")
        d = Path(f).parent.as_posix()
        subprocess.run([*ssh, f"mkdir -p {d}"], check=True)
        subprocess.run(["scp", *opts, "-P", str(SSH_PORT), str(src), f"{target}:{f}"], check=True)
    cmds = spec.get("cmd") or []
    if cmds:
        log("Installation du service vm-start (commandes cmd:)")
        wd = ROOT / "work"
        script = "#!/bin/bash\n# généré par build.py depuis cmd: du yml\ncd \"$HOME\"\n" + "".join(
            f"echo '+ '{shlex.quote(c)}\n{c}\n" for c in cmds)
        (wd / "vm-start.sh").write_text(script, newline="\n")
        unit = (ROOT / "scripts" / "vm-start.service").read_text().replace("__USER__", user)
        (wd / "vm-start.service").write_text(unit, newline="\n")
        for n in ("vm-start.sh", "vm-start.service"):
            subprocess.run(["scp", *opts, "-P", str(SSH_PORT), str(wd / n), f"{target}:/tmp/{n}"], check=True)
        subprocess.run([*ssh, "sudo install -m755 /tmp/vm-start.sh /usr/local/bin/vm-start.sh && "
                              "sudo install -m644 /tmp/vm-start.service /etc/systemd/system/vm-start.service && "
                              "sudo systemctl enable vm-start.service"], check=True)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[seed]", fmt % args, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vm", help="ex: vm_debian_min")
    ap.add_argument("--keep-work", action="store_true", help="garde work/ (console.log, disque brut)")
    a = ap.parse_args()

    conf = yaml.safe_load((ROOT / "conf.yml").read_text())
    spec = yaml.safe_load((ROOT / "VMs" / f"{a.vm}.yml").read_text())
    qemu_dir = Path(conf["dir_qemu"])
    qemu, qimg = qemu_dir / "qemu-system-x86_64.exe", qemu_dir / "qemu-img.exe"

    spec["_images"] = build_docker_images(spec)  # avant de démarrer la VM: échoue tôt

    base = ROOT / "cache" / spec["base"]
    download(spec["base_url"] + spec["base"], base)
    verify_sha512(spec["base_url"], spec["base"], base)

    work = ROOT / "work"
    clean_work(work)
    work.mkdir()
    seed = work / "seed"
    seed.mkdir()
    cloud_init_files(spec, seed)

    disk = work / "build.qcow2"
    subprocess.run([qimg, "convert", "-O", "qcow2", base, disk], check=True)
    subprocess.run([qimg, "resize", disk, spec["disk_size"]], check=True)  # FS agrandi par cloud-init au 1er boot

    primary = spec["users"][0]
    key = private_key_copy(ROOT / "VMs" / primary["id_rsa"], work)
    auto = next((u["name"] for u in spec["users"] if u.get("autologin")), "-")

    handler = functools.partial(QuietHandler, directory=str(seed))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    log("Boot QEMU (TCG) pour le provisioning — long, c'est normal. Console: work/console.log")
    vm = subprocess.Popen([
        str(qemu), "-machine", "pc", "-accel", "tcg,thread=multi", "-cpu", "max",
        "-smp", str(spec["build_cpus"]), "-m", str(spec["build_memory"]),
        "-drive", f"file={disk},if=virtio,format=qcow2,discard=unmap",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=n0",
        "-smbios", f"type=1,serial=ds=nocloud;s=http://10.0.2.2:{HTTP_PORT}/",
        "-display", "none", "-serial", f"file:{work / 'console.log'}",
    ])
    try:
        wait_ssh(SSH_PORT, 1800, vm)
        opts = ["-i", str(key), "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={os.devnull}",
                "-o", "IdentitiesOnly=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=30"]
        target = f"{primary['name']}@127.0.0.1"
        ssh = ["ssh", *opts, "-p", str(SSH_PORT), target]

        log("Attente de la fin de cloud-init (clé SSH, sudo)")
        for _ in range(90):
            if subprocess.run([*ssh, "sudo -n true && (cloud-init status --wait >/dev/null 2>&1; true)"]).returncode == 0:
                break
            time.sleep(10)
        else:
            sys.exit("Impossible de se connecter en SSH avec la clé")

        log("Envoi et exécution de setup.sh")
        subprocess.run(["scp", *opts, "-P", str(SSH_PORT), str(ROOT / "scripts" / "setup.sh"), f"{target}:/tmp/setup.sh"], check=True)
        pkgs = " ".join(spec.get("packages") or [])
        groups = ";".join(f"{u['name']}:{','.join(u['groups'])}" for u in spec["users"] if u.get("groups"))
        subprocess.run([*ssh, f"sudo USER_GROUPS='{groups}' bash /tmp/setup.sh {auto} {spec['hostname']} {pkgs}"], check=True)
        provision(spec, ssh, opts, target, primary["name"], image_tar_stream)
        log("Finalisation (mise à zéro de l'espace libre)")
        subprocess.run(["scp", *opts, "-P", str(SSH_PORT), str(ROOT / "scripts" / "finalize.sh"), f"{target}:/tmp/finalize.sh"], check=True)
        subprocess.run([*ssh, "sudo bash /tmp/finalize.sh"], check=True)
        subprocess.run([*ssh, "sudo systemctl poweroff"])  # la connexion coupe: code retour ignoré
        vm.wait(timeout=300)
    except BaseException:
        vm.kill()
        raise
    finally:
        httpd.shutdown()

    out = ROOT / "VMs" / "qcow2" / spec["img"]
    out_c = out.with_name(out.stem + "-compressed" + out.suffix)
    out.parent.mkdir(parents=True, exist_ok=True)
    log(f"Image non compressée (démarrage le plus rapide) -> {out.name}")
    subprocess.run([str(qimg), "convert", "-O", "qcow2", str(disk), str(out)], check=True)
    log(f"Image compressée (distribution) -> {out_c.name}")
    subprocess.run([str(qimg), "convert", "-c", "-O", "qcow2", "-o", "compression_type=zstd", str(disk), str(out_c)], check=True)
    print(f"Taille: {out.name} {out.stat().st_size / 1e6:.0f} Mo | {out_c.name} {out_c.stat().st_size / 1e6:.0f} Mo")
    if not a.keep_work:
        clean_work(work)


if __name__ == "__main__":
    main()
