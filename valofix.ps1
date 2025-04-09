# Self-elevate to administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

trap {
    Write-Host "Critical Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)"
    Write-Host "Press Enter to exit..."
    [void][System.Console]::ReadLine()
    exit 1
}

Clear-Host
Write-Host "=== Valorant Secure Boot & Installation Manager ===" -ForegroundColor Cyan
Write-Host "Version 5.1 | Stable Edition`n"

function Get-InstallDrive {
    param(
        [string]$DefaultDrive
    )

    while ($true) {
        $inputDrive = Read-Host "Enter installation drive letter [$($DefaultDrive.ToUpper())]"
        $cleanDrive = $inputDrive.Trim(':').ToUpper()
        
        if ([string]::IsNullOrEmpty($cleanDrive)) {
            $cleanDrive = $DefaultDrive
        }

        if ($cleanDrive -match '^[A-Z]$') {
            $drivePath = "${cleanDrive}:\"
            if (Test-Path $drivePath) {
                return $cleanDrive
            }
            Write-Host "Drive $cleanDrive does not exist!" -ForegroundColor Red
        }
        else {
            Write-Host "Invalid drive letter. Use single letter (A-Z)" -ForegroundColor Red
        }
    }
}

function Get-InstallPath {
    param(
        [string]$DriveLetter
    )

    $paths = @(
        "Program Files\Riot Vanguard",
        "Program Files (x86)\Riot Vanguard",
        "Riot Games\Riot Vanguard"
    )

    foreach ($path in $paths) {
        $fullPath = "${DriveLetter}:\$path"
        if (Test-Path $fullPath) {
            return $fullPath
        }
    }
    return $null
}

function Handle-Services {
    param(
        [string[]]$services,
        [ValidateSet('Stop','Disable','Remove')]
        [string]$action
    )

    foreach ($service in $services) {
        try {
            $serviceObj = Get-Service $service -ErrorAction SilentlyContinue
            if (-not $serviceObj) { continue }

            switch ($action) {
                'Stop' {
                    Write-Host "Stopping service: $service"
                    $serviceObj.Stop()
                    $serviceObj.WaitForStatus('Stopped', (New-TimeSpan -Seconds 5))
                }
                'Disable' {
                    Write-Host "Disabling service: $service"
                    Set-Service $service -StartupType Disabled
                }
                'Remove' {
                    Write-Host "Removing service: $service"
                    sc.exe delete $service | Out-Null
                    Start-Sleep -Seconds 1
                }
            }
        }
        catch {
            Write-Host "Service operation failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Clear-Vanguard {
    param(
        [string]$DriveLetter
    )

    try {
        $installPath = Get-InstallPath -DriveLetter $DriveLetter
        if (-not $installPath) {
            Write-Host "No existing installation found - skipping cleanup" -ForegroundColor Yellow
            return $false
        }

        Write-Host "Removing existing installation from: $installPath" -ForegroundColor Cyan

        # Service management
        $services = @("vgc", "vgk")
        Handle-Services -services $services -action 'Stop'
        Handle-Services -services $services -action 'Disable'
        Handle-Services -services $services -action 'Remove'

        # File cleanup
        $locations = @(
            $installPath,
            "${env:ProgramData}\Riot Games",
            "${env:LocalAppData}\Riot Games"
        )

        foreach ($location in $locations) {
            if (Test-Path $location) {
                Remove-Item $location -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Registry cleanup
        $regPaths = @(
            "HKLM:\SYSTEM\CurrentControlSet\Services\vgc",
            "HKLM:\SYSTEM\CurrentControlSet\Services\vgk",
            "HKLM:\SOFTWARE\Riot Games"
        )

        foreach ($reg in $regPaths) {
            if (Test-Path $reg) {
                Remove-Item $reg -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host "Cleanup completed on drive $DriveLetter!" -ForegroundColor Green
        return $true
    }
    catch {
        throw "Cleanup failed: $($_.Exception.Message)"
    }
}

function Install-Vanguard {
    param(
        [string]$DriveLetter
    )

    try {
        $drivePath = "${DriveLetter}:\"
        if (-not (Test-Path $drivePath)) {
            throw "Drive $DriveLetter does not exist!"
        }

        $tempFile = "$env:TEMP\ValorantInstaller.exe"
        $installPath = "${drivePath}Riot Games"

        # Download installer
        Write-Host "Downloading latest installer..."
        Invoke-WebRequest "https://valorant.secure.dyn.riotcdn.net/channels/public/x/installer/current/live.live.eu.exe" `
            -OutFile $tempFile `
            -UserAgent "Mozilla/5.0" `
            -UseBasicParsing

        # Install process
        Write-Host "Installing to: $installPath"
        $installArgs = @(
            "--launch-product=valorant",
            "--launch-patchline=live",
            "--force",
            "--install-path=`"$installPath`""
        )

        $process = Start-Process $tempFile -ArgumentList $installArgs -PassThru -Wait
        if ($process.ExitCode -ne 0) {
            throw "Installer failed with code $($process.ExitCode)"
        }

        # Verify installation
        if (-not (Test-Path "$installPath\Riot Vanguard")) {
            throw "Installation verification failed"
        }

        Write-Host "Installation successful on drive $DriveLetter!" -ForegroundColor Green
    }
    catch {
        throw "Installation failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Manage-SecureBoot {
    try {
        if (-not (Confirm-SecureBootUEFI -ErrorAction Stop)) {
            Write-Host "Secure Boot is disabled!" -ForegroundColor Red
            try {
                Set-SecureBootUEFI -Enable
                Write-Host "Secure Boot enabled! Reboot required." -ForegroundColor Green
                $choice = Read-Host "Reboot now? (Y/N)"
                if ($choice -in 'Y','y') { shutdown /r /t 0 }
                exit
            }
            catch {
                Write-Host "Manual Secure Boot configuration required" -ForegroundColor Yellow
                $choice = Read-Host "Reboot to UEFI settings? (Y/N)"
                if ($choice -in 'Y','y') { shutdown /r /fw }
                exit
            }
        }
        else {
            Write-Host "Secure Boot is active" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Secure Boot check failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Main execution flow
try {
    Manage-SecureBoot

    # Detect existing installation
    $installPath = Get-InstallPath -DriveLetter "C"
    $defaultDrive = if ($installPath) { $installPath.Substring(0,1) } else { 'C' }

    # Get installation drive
    Write-Host "`n=== Installation Drive Selection ===" -ForegroundColor Yellow
    $installDrive = Get-InstallDrive -DefaultDrive $defaultDrive

    # Conditional cleanup
    $cleanupPerformed = Clear-Vanguard -DriveLetter $installDrive

    # Fresh installation
    Install-Vanguard -DriveLetter $installDrive

    # Final check
    if (Get-InstallPath -DriveLetter $installDrive) {
        Write-Host "Valorant successfully installed on drive $installDrive!" -ForegroundColor Green
    }
    else {
        Write-Host "Installation verification failed" -ForegroundColor Red
        Start-Process "https://playvalorant.com/download/"
    }
}
catch {
    Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "Press Enter to exit..."
[void][System.Console]::ReadLine()
