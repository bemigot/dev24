# MAINTCD for dev24/Python bootstrap on Windows

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned  # 1. per-user, no admin; lets .ps1 here run without -Bypass
D:                                                   # 2. switch to this drive
.\ubootstrap.ps1                                     # 3. install the Python Install Manager, clear the Store stubs
python --version                                     # 4. first run downloads Python itself -> real Python set up
py check-req.py sample-project                       # 5. the readiness check (the point of all this)
.\cboot1.ps1                                         # 6. optional, run elevated: enable SSH for ./VM/harness.py ssh
```

If `py` isn't found at step 4, open a new terminal so PATH refreshes.
Skipping step 1? Run a script directly: `powershell -ExecutionPolicy Bypass -File .\ubootstrap.ps1`.
