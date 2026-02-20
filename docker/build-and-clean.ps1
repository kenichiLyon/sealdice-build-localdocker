param(
    [string]$ComposeFile = "docker-compose.artifact.yml",
    [string]$Service = "artifact-builder",
    [switch]$KeepImage,
    [switch]$KeepBuilderCache,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string[]]$Command
    )
    $cmdText = ($Command -join " ")
    Write-Host ">> $cmdText"
    if ($DryRun) {
        return 0
    }
    $commandName = $Command[0]
    $commandArgs = @()
    if ($Command.Length -gt 1) {
        $commandArgs = $Command[1..($Command.Length - 1)]
    }

    if ($commandArgs.Count -gt 0) {
        & $commandName @commandArgs | Out-Host
    }
    else {
        & $commandName | Out-Host
    }

    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    return [int]$exitCode
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$composePath = Join-Path $projectRoot $ComposeFile

if (-not (Test-Path $composePath)) {
    throw "Compose file not found: $composePath"
}

$buildExitCode = 0
try {
    $buildExitCode = Invoke-Step -Command @("docker", "compose", "-f", $composePath, "run", "--build", "--rm", $Service)
    if ($buildExitCode -ne 0) {
        Write-Warning "Build step exited with code $buildExitCode"
    }
}
finally {
    if (-not $KeepImage) {
        try {
            Invoke-Step -Command @("docker", "image", "rm", "-f", "sealdice-core-artifact:local") | Out-Null
        }
        catch {
            Write-Warning "Remove image failed (ignored): $($_.Exception.Message)"
        }
    }

    if (-not $KeepBuilderCache) {
        try {
            Invoke-Step -Command @("docker", "builder", "prune", "-af") | Out-Null
        }
        catch {
            Write-Warning "Builder prune failed (ignored): $($_.Exception.Message)"
        }
    }
}

exit $buildExitCode
