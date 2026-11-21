#!/usr/bin/env python3
"""Affiche en JSON ce dont vm_start.ps1 a besoin: dir_qemu, img, ports, hostname.

Usage: python scripts/vm_info.py vm_debian_docker
"""
import json
import re
import sys
from pathlib import Path

import yaml


class Loader(yaml.SafeLoader):
    """YAML 1.1 lit `2222:22` comme un entier sexagésimal (133342): on le désactive."""


Loader.yaml_implicit_resolvers = {
    k: [(t, r) for t, r in v if t != "tag:yaml.org,2002:int"]
    for k, v in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
Loader.add_implicit_resolver("tag:yaml.org,2002:int", re.compile(r"^[-+]?[0-9]+$"), list("-+0123456789"))

ROOT = Path(__file__).resolve().parent.parent
conf = yaml.load((ROOT / "conf.yml").read_text(encoding="utf-8"), Loader)
spec = yaml.load((ROOT / "VMs" / f"{sys.argv[1]}.yml").read_text(encoding="utf-8"), Loader)
print(json.dumps({
    "dir_qemu": conf["dir_qemu"],
    "img": str(ROOT / "VMs" / "qcow2" / spec["img"]),
    "img_compressed": str(ROOT / "VMs" / "qcow2" / (Path(spec["img"]).stem + "-compressed.qcow2")),
    "ports": [str(p) for p in (spec.get("ports") or ["2222:22"])],  # "hôte:invité"
    "user": spec["users"][0]["name"],
    "key": str(ROOT / "VMs" / spec["users"][0]["id_rsa"]),
    "hostname": spec.get("hostname", spec["name"]),
}))
