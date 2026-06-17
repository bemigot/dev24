# ============================================================
#  p24core Build Prerequisites Check & Setup
#  Run this before build-f4.bat / build-f4.ps1 to verify your environment.
# ============================================================

$errors        = 0
$warnings      = 0
$fixes         = 0
$missing       = @()
$warningMessages = @()

# All shared functions (Read-YesNo, Test-PowerShellVersion, Initialize-Mise,
# Invoke-NodeReinstall) live in helper.ps1. Dot-source it now - it only DEFINES
# functions (no side effects), so this produces no output yet and lets the
# version pre-check below use Read-YesNo before the mise step runs.
. "$PSScriptRoot\scripts\helper.ps1"

Write-Host "============================================================"
Write-Host " p24core Build Prerequisites Check"
Write-Host "============================================================"
Write-Host ""

# PowerShell version pre-check (unlabeled) - offers the PS7 upgrade on 5.1.
if (Test-PowerShellVersion) { exit 0 }
Write-Host ""

# --- 0. mise (dev toolchain manager) ---
Write-Host "[0] Checking mise..."
Initialize-Mise
Write-Host ""

# --- 1. Java JDK (javac: LTS 21/25, or current 26) ---
# Gate on javac, not java: the build needs a compiler, and a `java` on PATH
# could be a JRE or a different JDK than the one javac belongs to.
Write-Host "[1/6] Checking Java JDK..."
$javac = Get-Command javac -ErrorAction SilentlyContinue
if (-not $javac) {
    Write-Host "  FAIL: javac not found - a JDK is required to build (a JRE alone is not enough)"
    if ($miseExe -and (Read-YesNo "Install JDK 25 (Temurin) via mise?")) {
        Write-Host "  Installing JDK 25 via mise (this may take a few minutes)..."
        & $miseExe install java@temurin-25 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: mise install failed"
            Write-Host "  MANUAL: mise install java@temurin-25"
            $missing += "Java JDK  ->  mise install java@temurin-25"
            $errors++
        } else {
            & $miseExe use --global java@temurin-25 2>&1 | Out-Null
            & $miseExe activate pwsh | Out-String | Invoke-Expression
            Write-Host "  FIXED: JDK 25 installed via mise"
            $fixes++
        }
    } else {
        Write-Host "  INSTALL: mise install java@temurin-25"
        $missing += "Java JDK  ->  mise install java@temurin-25"
        $errors++
    }
} else {
    $javacVer = (& javac -version 2>&1) -replace 'javac ',''
    $javacMajor = [int]($javacVer -split '\.')[0]
    switch ($javacMajor) {
        21 { Write-Host "  OK: javac $javacVer (LTS 21)" }
        25 { Write-Host "  OK: javac $javacVer (LTS 25)" }
        26 { Write-Host "  OK: javac $javacVer (current release; CI builds on 25)" }
        default {
            Write-Host "  WARN: javac $javacVer is not a tested version - expected 21, 25, or 26 (CI builds on 25)"
            Write-Host "  INSTALL: mise install java@temurin-25"
            $warningMessages += "javac $javacVer untested  ->  mise install java@temurin-25"
            $warnings++
        }
    }
}
Write-Host ""

# --- 2. Node.js ---
Write-Host "[2/6] Checking Node.js..."
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host "  FAIL: node not found on PATH"
    if ($miseExe -and (Read-YesNo "Install latest Node.js LTS via mise?")) {
        & $miseExe use --global node@lts
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: mise install failed"
            $missing += "Node.js  ->  mise use --global node@lts"
            $errors++
        } else {
            Write-Host "  FIXED: Node.js LTS installed via mise"
            $fixes++
        }
    } else {
        $missing += "Node.js  ->  mise use --global node@lts"
        $errors++
    }
} else {
    $nodeVerRaw = (& node -v 2>&1).ToString().TrimStart('v')
    $nodeMajor  = [int]($nodeVerRaw -split '\.')[0]
    if ($nodeMajor -lt 22) {
        Write-Host "  FAIL: node v$nodeVerRaw is older than 22 - version 22+ is required"
        Invoke-NodeReinstall $nodeVerRaw
    } else {
        Write-Host "  Checking latest patch for Node.js v$nodeMajor..."
        try {
            $releases    = Invoke-RestMethod 'https://nodejs.org/dist/index.json' -TimeoutSec 10
            $latestPatch = $releases |
                Where-Object { $_.lts -ne $false -and ([int]($_.version.TrimStart('v') -split '\.')[0]) -eq $nodeMajor } |
                Select-Object -First 1
            if ($latestPatch) {
                $latestVer = $latestPatch.version.TrimStart('v')
                if ($nodeVerRaw -eq $latestVer) {
                    Write-Host "  OK: node v$nodeVerRaw (latest LTS patch)"
                } else {
                    Write-Host "  WARN: node v$nodeVerRaw is not the latest patch (latest: v$latestVer)"
                    Invoke-NodeReinstall $nodeVerRaw
                }
            } else {
                Write-Host "  OK: node v$nodeVerRaw (major $nodeMajor not yet an LTS release - skipping patch check)"
            }
        } catch {
            Write-Host "  OK: node v$nodeVerRaw (could not reach nodejs.org to verify latest patch)"
        }
    }
}
Write-Host ""

# --- 3. npm ---
Write-Host "[3/6] Checking npm..."
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
    Write-Host "  FAIL: npm not found on PATH (should come with Node.js)"
    $missing += "npm       ->  comes with Node.js (see above)"
    $errors++
} else {
    $npmVer = & npm -v 2>&1
    Write-Host "  OK: npm $npmVer"
}
Write-Host ""

# --- 4. Git ---
Write-Host "[4/6] Checking Git..."
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "  FAIL: git not found on PATH"
    Write-Host "  INSTALL: winget install Git.Git"
    Write-Host "           or download from https://git-scm.com/download/win"
    $missing += "Git       ->  winget install Git.Git"
    $errors++
} else {
    $gitVer = (& git --version 2>&1) -replace 'git version ',''
    Write-Host "  OK: git $gitVer"
}
Write-Host ""

# --- 5. PostgreSQL tools (psql + pgAdmin) ---
Write-Host "[5/6] Checking PostgreSQL tools..."
Test-PostgresTools
Write-Host ""

# --- 5b. Port 5432 availability for a Postgres container ---
Write-Host "[5b] Checking port 5432 is free for a Postgres container..."
Test-Port5432
Write-Host ""

# --- 6. Frontend dependencies (node_modules) ---
Write-Host "[6/6] Checking frontend dependencies..."
if (-not (Test-Path "platform24-spa\node_modules")) {
    Write-Host "  MISSING: platform24-spa\node_modules not found"
    if (-not $npm) {
        Write-Host "  SKIP: npm not available - install Node.js first (see step 2)"
        $warningMessages += "node_modules not installed  ->  install Node.js first, then re-run"
        $warnings++
    } else {
        Write-Host "  Installing npm dependencies..."
        Push-Location platform24-spa
        npm install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: npm install failed"
            $errors++
        } else {
            Write-Host "  FIXED: npm dependencies installed"
            $fixes++
        }
        Pop-Location
    }
} else {
    Write-Host "  OK: node_modules present"
}
Write-Host ""

# --- 6b. openapi-generator-cli ---
Write-Host "[6b] Checking openapi-generator-cli (via npx)..."
if (Test-Path "platform24-spa\node_modules\@openapitools\openapi-generator-cli") {
    Write-Host "  OK: @openapitools/openapi-generator-cli installed locally"
} else {
    Write-Host "  WARN: @openapitools/openapi-generator-cli not in node_modules"
    Write-Host "  This should have been installed by npm install above."
    Write-Host "  Try: cd platform24-spa; npm install"
    $warningMessages += "openapi-generator-cli missing  ->  cd platform24-spa; npm install"
    $warnings++
}
Write-Host ""

# --- Patch generate-api.mjs if it calls bare openapi-generator-cli ---
Write-Host "[FIX] Checking generate-api.mjs for bare openapi-generator-cli calls..."
$genApi = "platform24-spa\scripts\generate-api.mjs"
$content = Get-Content $genApi -Raw
if ($content -match 'openapi-generator-cli generate' -and $content -notmatch 'npx openapi-generator-cli') {
    Write-Host "  ISSUE: generate-api.mjs calls openapi-generator-cli without npx - patching..."
    $content -replace 'openapi-generator-cli generate', 'npx openapi-generator-cli generate' |
        Set-Content $genApi -Encoding UTF8
    if ($?) {
        Write-Host "  FIXED: generate-api.mjs now uses npx"
        $fixes++
    } else {
        Write-Host "  FAIL: could not patch generate-api.mjs"
        Write-Host '  MANUAL: replace "openapi-generator-cli generate" with "npx openapi-generator-cli generate"'
        $errors++
    }
} else {
    Write-Host "  OK: No patching needed"
}
Write-Host ""

# --- 7. Python / Pixi ---
Write-Host "[7] Checking Python..."
. "$PSScriptRoot\scripts\python-setup.ps1"
Write-Host ""

# --- 8. Container runtime (Docker / Podman) ---
Write-Host "[8] Checking container runtime..."
. "$PSScriptRoot\scripts\docker-setup.ps1"

# --- 9. Playwright browsers ---
Write-Host "[9] Checking Playwright browsers..."
$playwrightBin   = "platform24-spa\node_modules\.bin\playwright"
$playwrightCache = "$env:LocalAppData\ms-playwright"
if (-not (Test-Path $playwrightBin)) {
    Write-Host "  SKIP: playwright not in node_modules - run npm install first (see step 6)"
    $warningMessages += "Playwright browsers not checked  ->  run npm install first, then re-run this script"
    $warnings++
} else {
    # npx playwright install hangs during zip extraction on machines with strict EDR policies.
    # Use PowerShell Invoke-WebRequest + Expand-Archive instead - bypasses Node.js extraction entirely.
    # Revisions are read from browsers.json, the single source of truth bundled with playwright-core.
    $browsersJson = Get-Content "platform24-spa\node_modules\playwright-core\browsers.json" -Raw | ConvertFrom-Json

    function Install-PlaywrightPackage($name, $urlTemplate, $destPrefix, $checkExe, $sizeMB) {
        $rev  = ($script:browsersJson.browsers | Where-Object { $_.name -eq $name }).revision
        $dest = "$script:playwrightCache\$destPrefix-$rev"
        $exe  = "$dest\$checkExe"
        if (Test-Path $exe) {
            Write-Host "  OK: $exe"
            return
        }
        $stale = Get-ChildItem "$script:playwrightCache\$destPrefix-*" -Directory -EA SilentlyContinue | Select-Object -First 1
        if ($stale) {
            Write-Host "  INCOMPLETE: $($stale.Name) exists but $checkExe missing"
        } else {
            Write-Host "  MISSING: $name rev $rev"
        }
        if (Read-YesNo "Install $name now? (~$sizeMB MB download)") {
            $url = "https://cdn.playwright.dev/dbazure/download/playwright/builds/$($urlTemplate -f $rev)"
            $zip = "$env:TEMP\pw-$name-$rev.zip"
            if ($stale) { Remove-Item $stale.FullName -Recurse -Force -EA SilentlyContinue }
            Write-Host "  Downloading $url ..."
            try {
                Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
                Write-Host "  Extracting..."
                Expand-Archive -Path $zip -DestinationPath $dest -Force
                Remove-Item $zip -Force -EA SilentlyContinue
                Write-Host "  FIXED: $name installed"
                $script:fixes++
            } catch {
                Write-Host "  FAIL: $_"
                $script:missing += "$name  ->  Invoke-WebRequest '$url' -OutFile `$env:TEMP\pw.zip; Expand-Archive `$env:TEMP\pw.zip '$dest'"
                $script:errors++
            }
        } else {
            Write-Host "  SKIPPED"
            $script:missing += "$name  ->  cd platform24-spa && npx playwright install $name"
            $script:errors++
        }
    }

    Install-PlaywrightPackage "chromium-headless-shell" "chromium/{0}/chromium-headless-shell-win64.zip" "chromium_headless_shell" "chrome-headless-shell-win64\chrome-headless-shell.exe" 107
    Install-PlaywrightPackage "ffmpeg"                  "ffmpeg/{0}/ffmpeg-win64.zip"                    "ffmpeg"                  "ffmpeg-win64.exe"                                     2
}
Write-Host ""

# --- Windows Defender exclusions ---
Write-Host "[D] Checking Windows Defender exclusions..."
Test-DefenderExclusions
Write-Host ""

# ============================================================
#  Summary
# ============================================================
Write-Host "============================================================"
if ($errors -eq 0 -and $warnings -eq 0) {
    Write-Host " ALL CHECKS PASSED  (fixes applied: $fixes)"
    Write-Host " You can now run: build-f4.bat / run-f4.sh"
} else {
    Write-Host " $errors ERROR(s), $warnings WARNING(s)  (fixes applied: $fixes)"
    if ($missing.Count -gt 0) {
        Write-Host " Errors - missing tools:"
        foreach ($item in $missing) {
            Write-Host "   - $item"
        }
    }
    if ($warningMessages.Count -gt 0) {
        Write-Host " Warnings:"
        foreach ($item in $warningMessages) {
            Write-Host "   - $item"
        }
    }
    if ($errors -gt 0) {
        Write-Host " Fix errors above, then re-run this script."
    }
}
Write-Host "============================================================"
