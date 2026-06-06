# Run the app in Chrome, connected to Supabase (reads supabase.env).
# Usage:  ./tool/run_web.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_load_env.ps1"
$defines = Get-SupabaseDefines
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    flutter run -d chrome @defines
}
finally {
    Pop-Location
}
