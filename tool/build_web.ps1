# Build the production web app into build/web, connected to Supabase.
# Usage:  ./tool/build_web.ps1
# Then serve build/web over HTTPS (see SUPABASE_SETUP.md) and open on iPhone.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_load_env.ps1"
$defines = Get-SupabaseDefines
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    flutter build web --release --no-tree-shake-icons --no-wasm-dry-run @defines
    Write-Host "`nBuilt to build/web. To preview locally:" -ForegroundColor Green
    Write-Host "  cd build/web; python -m http.server 8080" -ForegroundColor Green
}
finally {
    Pop-Location
}
