#!/usr/bin/env python3
"""Restart retained disposable disks after an operator host restart.

No disk creation, password/key generation, production host or host firewall edits.
The private lab directory is deliberately excluded from product deliverables.
"""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import time

assert os.geteuid() == 0 and socket.gethostname() == 'VM-192306'
private = Path('/root/twp-update01-final-private')
assert private.is_dir() and private.stat().st_uid == 0 and private.stat().st_mode & 0o077 == 0
parser = argparse.ArgumentParser()
parser.add_argument('--lab-nic', choices=['virtio-net-pci', 'e1000'], default='virtio-net-pci')
options = parser.parse_args()
for role, port, mac in [('entry', 22230, '10'), ('exit', 22231, '11')]:
    disk, seed = private/(role+'.qcow2'), private/(role+'-seed.img')
    assert disk.is_file() and seed.is_file()
    unit = 'twp-update01-final-'+role
    if subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0:
        continue
    subprocess.run(['qemu-img', 'check', str(disk)], check=True)
    args = ['systemd-run', '--unit='+unit, '--property=MemoryMax=2000M', '--property=OOMPolicy=stop',
            '/usr/bin/qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-smp', '2', '-m', '1024',
            '-display', 'none', '-serial', 'file:'+str(private/(role+'-console.log')), '-monitor', 'none',
            '-drive', f'file={disk},format=qcow2,if=virtio,cache=none',
            '-drive', f'file={seed},format=raw,if=virtio,cache=none',
            '-netdev', f'user,id=wan,hostfwd=tcp:127.0.0.1:{port}-:22',
            '-device', f'virtio-net-pci,netdev=wan,mac=52:54:00:12:30:{mac}',
            '-netdev', 'socket,id=lab,'+('listen' if role == 'entry' else 'connect')+'=127.0.0.1:27230',
            '-device', f'{options.lab_nic},netdev=lab,mac=52:54:00:12:31:{mac}', '-no-reboot']
    subprocess.run(args, check=True)
    if role == 'entry':
        for _ in range(50):
            if subprocess.check_output(['ss', '-H', '-ltn', 'sport = :27230']).strip(): break
            time.sleep(.1)
        else: raise RuntimeError('entry inter-VM listener did not appear')
