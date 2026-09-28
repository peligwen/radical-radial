#!/usr/bin/env python3
"""Run tools/harness.lua against the RadicalRadial addon using the lupa Lua runtime.

    pip install lupa
    python3 tools/check.py

Exit status is the number of failed scenarios.
"""
import os, sys
from lupa import LuaRuntime

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
lua = LuaRuntime(unpack_returned_tuples=True)
with open("tools/harness.lua", encoding="utf-8") as fh:
    failures = lua.execute(fh.read())
sys.exit(int(failures or 0))
