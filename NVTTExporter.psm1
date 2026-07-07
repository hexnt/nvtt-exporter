<#
.SYNOPSIS
    A module which allows exporting textures to DDS using NVIDIA Texture Tools in batches.
#>

#region Configuration and constants

$script:CONFIG = @{
    DefaultFilter           = "*.png"
    DefaultUICulture        = "en-US"
    LocalizedDataName       = "NVTTExporter"
    MaxParallelJobs         = 4
    NvttExeName             = "nvtt_export.exe"
    NvttSoftwareName        = "NVIDIA Texture Tools"
    NvttPresetExtension     = "*.dpf"
    OutputExtension         = ".dds"
    ProcessPollMsInterval   = 50
    ErrorMissingLang        = "Critical Error: Language files missing! Please ensure the folder 'en-US' exists and contains 'NVTTExporter.psd1'."
    ErrorMissingLangEx      = "Localization files not found."
    IgnoredNvttOutput       = @('Processing\.\.\.', 'Done\.')
    RegistryAppPath         = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\nvtt_export.exe"
    )
    UninstallPaths          = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
}

#endregion

#region Private functions

function Get-NvttLocalizedStrings {
    [CmdletBinding()]
    param ([string]$BaseDirectory)

    try {
        return Import-LocalizedData -BaseDirectory $BaseDirectory -FileName $script:CONFIG.LocalizedDataName -ErrorAction Stop
    } catch {
        try {
            return Import-LocalizedData -BaseDirectory $BaseDirectory -FileName $script:CONFIG.LocalizedDataName -UICulture $script:CONFIG.DefaultUICulture -ErrorAction Stop
        } catch {
            Write-Error $script:CONFIG.ErrorMissingLang
            throw $script:CONFIG.ErrorMissingLangEx
        }
    }
}

function Get-NvttExporterPath {
    [CmdletBinding()]
    param ()

    foreach ($path in $script:CONFIG.RegistryAppPath) {
        $regPath = (Get-ItemProperty -Path $path -ErrorAction SilentlyContinue).'(default)'
        if ($regPath -and (Test-Path $regPath -PathType Leaf)) {
            return $regPath
        }
    }

    $nvttReg = Get-ItemProperty -Path $script:CONFIG.UninstallPaths -ErrorAction SilentlyContinue | 
               Where-Object { $_.DisplayName -match $script:CONFIG.NvttSoftwareName } | 
               Select-Object -First 1
    
    if ($nvttReg -and $nvttReg.InstallLocation) {
        $potentialPath = Join-Path $nvttReg.InstallLocation $script:CONFIG.NvttExeName
        if (Test-Path $potentialPath -PathType Leaf) {
            return $potentialPath
        }
    }

    $sysCommand = Get-Command $script:CONFIG.NvttExeName -ErrorAction SilentlyContinue
    if ($sysCommand) { 
        return $sysCommand.Source 
    }

    return $null
}

function Get-NvttPresetPath {
    [CmdletBinding()]
    param ([string]$SourceDirectory)

    $preset = Get-ChildItem -Path $SourceDirectory -Filter $script:CONFIG.NvttPresetExtension | Select-Object -First 1
    if ($preset) {
        return $preset.FullName
    }
    return $null
}

function Resolve-NvttJobResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] $Job,
        [Parameter(Mandatory = $true)] $Messages
    )
    
    $rawOut = $Job.Process.StandardOutput.ReadToEnd()
    $rawErr = $Job.Process.StandardError.ReadToEnd()
    $fullText = "$rawOut`n$rawErr"

    $filteredText = $fullText
    foreach ($ignore in $script:CONFIG.IgnoredNvttOutput) {
        $filteredText = $filteredText -replace $ignore, ''
    }

    $cleanedText = ($filteredText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"

    if ($Job.Process.ExitCode -ne 0 -or $cleanedText.Length -gt 0) {
        $warnMsg = ($Messages.WarningPrefix -f $Job.FileName)
        if ($Job.Process.ExitCode -ne 0) { $warnMsg += ($Messages.WarningExitCode -f $Job.Process.ExitCode) }
        if ($cleanedText.Length -gt 0) { $warnMsg += ($Messages.WarningDetails -f $cleanedText) }
        Write-Warning $warnMsg
    } else {
        $outputFile = [System.IO.Path]::ChangeExtension($Job.FileName, $script:CONFIG.OutputExtension)
        Write-Host ($Messages.ItemDone -f $Job.FileName, $outputFile) -ForegroundColor DarkGreen
    }

    $Job.Process.Dispose()
}

#endregion

#region Public functions

function Invoke-NvttBatchExport {
    <#
    .SYNOPSIS
    Batch exports textures to DDS using NVIDIA Texture Tools.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [string]$SourceDirectory = $PWD,

        [Parameter()]
        [string]$ExporterPath,

        [Parameter()]
        [ValidateRange(1, 64)]
        [int]$MaxParallelJobs = $script:CONFIG.MaxParallelJobs,

        [Parameter()]
        [string]$PresetFile,

        [Parameter()]
        [string]$Filter = $script:CONFIG.DefaultFilter
    )

    try {
        $Msg = Get-NvttLocalizedStrings -BaseDirectory $PSScriptRoot
    } catch { 
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExporterPath)) {
        $ExporterPath = Get-NvttExporterPath
    }

    if ([string]::IsNullOrWhiteSpace($ExporterPath) -or -not (Test-Path -Path $ExporterPath -PathType Leaf)) {
        $displayPath = if ($ExporterPath) { $ExporterPath } else { $Msg.ErrorAutoDiscoveryFailed }
        Write-Error ($Msg.ErrorExporterNotFound -f $displayPath)
        return
    }

    if ([string]::IsNullOrWhiteSpace($PresetFile)) {
        $PresetFile = Get-NvttPresetPath -SourceDirectory $SourceDirectory
        if (-not $PresetFile) {
            Write-Error ($Msg.ErrorPresetNotFound -f $SourceDirectory)
            return
        }
    }

    $Files = @(Get-ChildItem -Path $SourceDirectory -Filter $Filter)
    $TotalFiles = $Files.Count

    if ($TotalFiles -eq 0) {
        Write-Warning ($Msg.WarningNoFiles -f $Filter)
        return
    }

    Write-Host ($Msg.StartMessage -f $TotalFiles, ($PresetFile | Split-Path -Leaf)) -ForegroundColor Cyan

    $ActiveJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $CompletedFiles = 0
    $FailedFiles = 0
    $UserCancelled = $false

    try {
        $OriginalCtrlC = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $true
    } catch { 
        $OriginalCtrlC = $false 
    }

    $CheckCtrlC = {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and $key.Modifiers -match 'Control') { return $true }
        }
        return $false
    }

    try {
        Write-Progress -Activity $Msg.ActivityName -Status ($Msg.ProgressPreparing -f $TotalFiles) -PercentComplete 0

        foreach ($File in $Files) {
            if (& $CheckCtrlC) { $UserCancelled = $true; break }

            $OutputFile = Join-Path $SourceDirectory "$($File.BaseName)$($script:CONFIG.OutputExtension)"

            while ($ActiveJobs.Count -ge $MaxParallelJobs) {
                if (& $CheckCtrlC) { $UserCancelled = $true; break }

                Start-Sleep -Milliseconds $script:CONFIG.ProcessPollMsInterval
                for ($i = $ActiveJobs.Count - 1; $i -ge 0; $i--) {
                    $Job = $ActiveJobs[$i]
                    if ($Job.Process.HasExited) {
                        if ($Job.Process.ExitCode -ne 0) { $FailedFiles++ }
                        Resolve-NvttJobResult -Job $Job -Messages $Msg
                        $ActiveJobs.RemoveAt($i)
                        $CompletedFiles++
                    }
                }
            }
            
            if ($UserCancelled) { break }

            $StartInfo = [System.Diagnostics.ProcessStartInfo]@{
                FileName               = $ExporterPath
                Arguments              = "`"$($File.FullName)`" --preset `"$PresetFile`" --output `"$OutputFile`""
                UseShellExecute        = $false
                CreateNoWindow         = $true
                RedirectStandardOutput = $true
                RedirectStandardError  = $true
            }

            try {
                $Proc = [System.Diagnostics.Process]::Start($StartInfo)
                $ActiveJobs.Add([PSCustomObject]@{ Process = $Proc; FileName = $File.Name })
            } catch {
                Write-Error ($Msg.ErrorFailedStart -f $File.Name)
                $FailedFiles++
            }

            $Percent = if ($TotalFiles -gt 0) { ($CompletedFiles / $TotalFiles) * 100 } else { 0 }
            Write-Progress -Activity $Msg.ActivityName -Status ($Msg.ProgressStatus -f $CompletedFiles, $TotalFiles, $ActiveJobs.Count, $MaxParallelJobs) -PercentComplete $Percent
        }

        while ($ActiveJobs.Count -gt 0 -and -not $UserCancelled) {
            if (& $CheckCtrlC) { $UserCancelled = $true; break }

            Start-Sleep -Milliseconds $script:CONFIG.ProcessPollMsInterval
            for ($i = $ActiveJobs.Count - 1; $i -ge 0; $i--) {
                $Job = $ActiveJobs[$i]
                if ($Job.Process.HasExited) {
                    if ($Job.Process.ExitCode -ne 0) { $FailedFiles++ }
                    Resolve-NvttJobResult -Job $Job -Messages $Msg
                    $ActiveJobs.RemoveAt($i)
                    $CompletedFiles++
                    
                    $Percent = if ($TotalFiles -gt 0) { ($CompletedFiles / $TotalFiles) * 100 } else { 0 }
                    Write-Progress -Activity $Msg.ActivityName -Status ($Msg.ProgressStatus -f $CompletedFiles, $TotalFiles, $ActiveJobs.Count, $MaxParallelJobs) -PercentComplete $Percent
                }
            }
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $OriginalCtrlC
        Write-Progress -Activity $Msg.ActivityName -Completed

        $KilledFiles = @()
        foreach ($Job in $ActiveJobs) {
            if ($null -ne $Job.Process -and -not $Job.Process.HasExited) {
                try {
                    $Job.Process.Kill()
                    $KilledFiles += $Job.FileName 
                } catch {}
                $Job.Process.Dispose()
            }
        }
        
        if ($UserCancelled) {
            Write-Host $Msg.ScriptAborted -ForegroundColor Red
            if ($KilledFiles.Count -gt 0) {
                Write-Host ($Msg.KilledProcesses -f $KilledFiles.Count) -ForegroundColor Red
                foreach ($KilledFile in $KilledFiles) {
                    Write-Host ($Msg.KilledFileItem -f $KilledFile) -ForegroundColor DarkRed
                }
            }
        } else {
            if ($FailedFiles -gt 0) {
                Write-Host ($Msg.ExportFinishedWithErrors -f ($CompletedFiles - $FailedFiles), $FailedFiles) -ForegroundColor Yellow
            } else {
                Write-Host ($Msg.ExportFinishedSuccess -f $TotalFiles) -ForegroundColor Green
            }
        }
    }
}

#endregion

Export-ModuleMember -Function Invoke-NvttBatchExport