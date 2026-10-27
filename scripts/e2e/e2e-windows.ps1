$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

# WM_APP+6 is accepted only with FULCRUM_ACCEPTANCE=1. It calls the same
# QuitApplication method as the tray menu, so we can assert a real clean exit
# without attempting to drive the system tray in an unattended CI session.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FulcrumNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = Join-Path $repo '.rivet\acceptance\windows'
$data = Join-Path $output "data-$PID"
$executable = Get-ChildItem -LiteralPath (Join-Path $repo 'dist') `
    -Filter RivetHost.exe -File -Recurse | Select-Object -First 1
if (-not $executable) { throw 'packaged Fulcrum executable was not found' }
New-Item -ItemType Directory -Force -Path $output,$data | Out-Null

function Wait-Until {
    param([string]$Description, [scriptblock]$Probe, [int]$TimeoutSeconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 100
    }
    throw "timed out waiting for $Description"
}

function Find-ById {
    param($Root, [string]$AutomationId)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ByName {
    param($Root, [string]$Name)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ByNameFragment {
    param($Root, [string]$Fragment)
    $nodes = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    for ($index = 0; $index -lt $nodes.Count; $index++) {
        if ($nodes[$index].Current.Name -like "*$Fragment*") { return $nodes[$index] }
    }
    return $null
}

function Save-AccessibilitySnapshot {
    param($Root, [string]$Path)
    $nodes = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $snapshot = for ($index = 0; $index -lt [Math]::Min($nodes.Count, 500); $index++) {
        $node = $nodes[$index]
        [ordered]@{ name = $node.Current.Name; controlType = $node.Current.ControlType.ProgrammaticName; automationId = $node.Current.AutomationId }
    }
    ConvertTo-Json -InputObject @($snapshot) -Depth 4 |
        Set-Content -LiteralPath $Path -Encoding utf8
}

$process = $null
$savedData = $env:FULCRUM_DATA_DIR
$savedInstanceId = $env:FULCRUM_INSTANCE_ID
$savedAcceptance = $env:FULCRUM_ACCEPTANCE
try {
    $env:FULCRUM_DATA_DIR = $data
    $env:FULCRUM_INSTANCE_ID = "site.jrtx.fulcrum.acceptance.$PID"
    $env:FULCRUM_ACCEPTANCE = '1'
    Set-Clipboard -Value ''
    $process = Start-Process -FilePath $executable.FullName -PassThru `
        -WorkingDirectory $repo `
        -RedirectStandardOutput (Join-Path $output 'application.stdout.log') `
        -RedirectStandardError (Join-Path $output 'application.stderr.log')
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $window = Wait-Until 'Fulcrum window' {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
    }
    $query = Wait-Until 'Fulcrum query field' { Find-ById $window 'QueryBox' }
    # The first visible WinUI frame must be initialized, not the old empty
    # XAML scaffold showing only the "Search apps" placeholder.
    $firstStatus = Find-ById $window 'StatusText'
    if (-not $firstStatus -or $firstStatus.Current.Name -match 'Starting embedded') {
        throw 'the launcher appeared before the backend completed startup'
    }
    [void](Wait-Until 'embedded backend ready status' {
        $status = Find-ById $window 'StatusText'
        if ($status -and $status.Current.Name -match 'Ready') { return $true }
        return $false
    })
    # Drive the query through the same keyboard path as a user. WinUI's
    # ValuePattern.SetValue can update the automation value without reliably
    # raising TextChanged when the packaged app has just finished startup.
    $query.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait('12*12')
    [void](Wait-Until 'query field value 12*12' {
        $pattern = $query.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if (([System.Windows.Automation.ValuePattern]$pattern).Current.Value -eq '12*12') { return $true }
        return $false
    })
    try {
        [void](Wait-Until 'calculator result 144 from embedded backend' {
            if (Find-ByNameFragment $window '144') { return $true }
            return $false
        })
    } catch {
        Save-AccessibilitySnapshot $window (Join-Path $output 'failure-accessibility.json')
        $status = Find-ById $window 'StatusText'
        $statusText = if ($status) { $status.Current.Name } else { '<missing>' }
        throw "$($_.Exception.Message); status=$statusText"
    }

    Save-AccessibilitySnapshot $window (Join-Path $output 'accessibility.json')

    $query.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    [void](Wait-Until 'calculator action clipboard event' {
        $text = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if ($text -and $text.TrimEnd() -eq '144') { return $true }
        return $false
    })
    # Starting a second EXE while the resident host owns the lease must not
    # leave another invisible Fulcrum process. It should summon the original.
    $secondary = Start-Process -FilePath $executable.FullName -PassThru -WorkingDirectory $repo
    try {
        if (-not $secondary.WaitForExit(15000)) {
            throw 'secondary single-instance process stayed alive'
        }
        if ($secondary.ExitCode -ne 0) {
            throw "secondary instance exited with code $($secondary.ExitCode)"
        }
        if ($process.HasExited) { throw 'secondary launch killed the primary instance' }
        $reopened = Wait-Until 'primary launcher re-summoned by secondary launch' {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
            $desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
        }
    } finally {
        if (-not $secondary.HasExited) { Stop-Process -Id $secondary.Id -Force -ErrorAction SilentlyContinue }
        $secondary.Dispose()
    }

    # Close through the exact production QuitApplication function and demand
    # natural process exit (not a test force-kill). The next primary must be
    # free to acquire the same instance ID and expose a usable window again.
    $hwnd = [IntPtr]::new([int64]$reopened.Current.NativeWindowHandle)
    if ($hwnd -eq [IntPtr]::Zero -or -not [FulcrumNative]::PostMessage(
        $hwnd, [uint32]0x8006, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw 'could not request acceptance-only QuitApplication'
    }
    if (-not $process.WaitForExit(30000)) {
        throw 'Fulcrum did not terminate after QuitApplication'
    }
    if ($process.ExitCode -ne 0) {
        throw "Fulcrum quit with code $($process.ExitCode)"
    }
    $process.Dispose()
    $process = Start-Process -FilePath $executable.FullName -PassThru `
        -WorkingDirectory $repo `
        -RedirectStandardOutput (Join-Path $output 'relaunch.stdout.log') `
        -RedirectStandardError (Join-Path $output 'relaunch.stderr.log')
    $restarted = Wait-Until 'restarted Fulcrum launcher' {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
    }
    [void](Wait-Until 'restarted query field' { Find-ById $restarted 'QueryBox' })
    $restartedStatus = Find-ById $restarted 'StatusText'
    if (-not $restartedStatus -or $restartedStatus.Current.Name -match 'Starting embedded') {
        throw 'restarted launcher showed uninitialized scaffold'
    }

    [ordered]@{
        platform = 'windows'
        artifact = $executable.FullName
        actions = @('set:QueryBox=12*12','press:Enter','launch:secondary','quit:acceptance-tray-path','launch:again')
        assertions = @('no blank startup XAML frame','packaged WinUI window activated','QueryBox exposed through UI Automation','query crossed RVT1 into the embedded backend','native result list contains 144','run-action emitted 144 to the native clipboard','secondary exited without a phantom process','secondary summons primary','QuitApplication terminated primary normally','relaunch obtained same lease and painted the ready window')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'interaction-trace.json') -Encoding utf8
} finally {
    $env:FULCRUM_DATA_DIR = $savedData
    $env:FULCRUM_INSTANCE_ID = $savedInstanceId
    $env:FULCRUM_ACCEPTANCE = $savedAcceptance
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    if ($process) { $process.Dispose() }
}
