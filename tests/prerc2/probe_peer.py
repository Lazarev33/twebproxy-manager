#!/usr/bin/env python3
# Continuous non-loopback TCP connect probe, run inside the peer network
# namespace. One thread per port; every attempt is one line:
#   <monotonic ns>\t<wall ns>\t<port>\t<OPEN|TIMEOUT|ERR<errno>>
# The monotonic clock is shared with the host-side recorder (same kernel).
import socket
import sys
import threading
import time

host = sys.argv[1]
outfile = sys.argv[2]
ports = [int(x) for x in sys.argv[3:]]
lock = threading.Lock()
out = open(outfile, 'w', buffering=1)


def loop(port):
    while True:
        mono = time.monotonic_ns()
        wall = time.time_ns()
        s = socket.socket()
        s.settimeout(0.035)
        try:
            s.connect((host, port))
            status = 'OPEN'
        except socket.timeout:
            status = 'TIMEOUT'
        except OSError as e:
            status = 'ERR%d' % e.errno
        finally:
            s.close()
        with lock:
            out.write('%d\t%d\t%d\t%s\n' % (mono, wall, port, status))
        time.sleep(0.007)


for p in ports:
    threading.Thread(target=loop, args=(p,), daemon=True).start()
while True:
    time.sleep(1)
