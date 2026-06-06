# Reads supabase.env (KEY=VALUE lines, untracked) from the project root and
# returns the two --dart-define args Flutter needs. Shared by run_web.ps1 and
# build_web.ps1. Dot-source it: . "$PSScriptRoot\_load_env.ps1"
function Get-SupabaseDefines {
    $root = Split-Path $PSScriptRoot -Parent
    $envFile = Join-Path $root 'supabase.env'
    if (-not (Test-Path $envFile)) {
        Write-Error "Missing $envFile. Create it with two lines:`nSUPABASE_URL=https://xxxx.supabase.co`nSUPABASE_ANON_KEY=your-anon-key"
        exit 1
    }
    $map = @{}
    foreach ($line in Get-Content $envFile) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    foreach ($k in 'SUPABASE_URL', 'SUPABASE_ANON_KEY') {
        if (-not $map.ContainsKey($k) -or $map[$k] -eq '') {
            Write-Error "supabase.env is missing $k"
            exit 1
        }
    }
    return @(
        "--dart-define=SUPABASE_URL=$($map['SUPABASE_URL'])",
        "--dart-define=SUPABASE_ANON_KEY=$($map['SUPABASE_ANON_KEY'])"
    )
}
