# Build ACG720 PC console into a standalone Windows app.
# Run from the project root:
#   powershell -ExecutionPolicy Bypass -File tools\build_pc_exe.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

python -m pip install -r requirements.txt
python -m pip install pyinstaller

python -m PyInstaller --noconfirm --clean --windowed `
  --name ACG720_Console `
  --distpath "$root\dist_pc" `
  --workpath "$root\build_pc" `
  --specpath "$root\build_pc" `
  --collect-all bleak `
  --collect-all serial `
  --hidden-import=bleak.backends.winrt `
  "$root\tools\pc_app.py"

Write-Host ""
Write-Host "Done: $root\dist_pc\ACG720_Console\ACG720_Console.exe"
Write-Host "Distribute the whole ACG720_Console folder."
