#!/usr/bin/env python3
import os
import shutil
import time

paths = [
    os.path.expanduser("~/.docker"),
    os.path.expanduser("~/.config/docker-secrets-engine"),
    os.path.expanduser("~/.cache/docker-secrets-engine"),
]

start = time.time()
for p in paths:
    try:
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        elif os.path.lexists(p):
            os.remove(p)
        print("removed:", p)
    except Exception as exc:  # noqa: BLE001
        print("failed:", p, exc)

print("elapsed %.1fs" % (time.time() - start))

leftover = [p for p in paths if os.path.lexists(p)]
if leftover:
    print("STILL_EXIST:", leftover)
else:
    print("ALL_CLEAN")

# self cleanup
try:
    os.remove(os.path.abspath(__file__))
except Exception:
    pass
