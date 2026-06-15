<#
================================================================================
 SIMPLE SCRIPT: Install Sysmon + Winlogbeat on Remote Host(s)
================================================================================

This script is intentionally kept simple and straightforward.

------------------------------------------------------------------------------
STEP 0: PREPARE FILES ON YOUR ADMIN MACHINE (Do this first)
------------------------------------------------------------------------------

1. DOWNLOAD SYSMON
   - Go to: https://download.sysinternals.com/files/Sysmon.zip
   - Extract the zip to a folder on your PC, for example: C:\Tools\Sysmon

2. SYSMON CONFIGURATION (Optional but recommended)
   - Create or download a config file (example: sysmonconfig.xml)
   - Popular community config: https://github.com/SwiftOnSecurity/sysmon-config
   - Or create a basic one. Save it next to Sysmon64.exe or in a known location.

3. DOWNLOAD WINLOGBEAT
   - Go to: https://artifacts.elastic.co/downloads/beats/winlogbeat/
   - Download the Windows zip for your version, for example:
     winlogbeat-8.17.3-windows-x86_64.zip
   - Extract it to a folder on your PC, for example: C:\Tools\Winlogbeat

4. WINLOGBEAT CONFIGURATION (Required)
   - Copy the sample winlogbeat.yml from the extracted folder and edit it.
   - At minimum you need:
        output.elasticsearch:
          hosts: ["https://your-elasticsearch:9200"]
          username: "elastic"
          password: "yourpassword"

        winlogbeat.event_logs:
          - name: Microsoft-Windows-Sysmon/Operational
          - name: Security
          - name: System
   - Save your edited file as winlogbeat.yml in the Winlogbeat folder.

------------------------------------------------------------------------------
HOW TO RUN THIS SCRIPT
------------------------------------------------------------------------------
Example for one host:
    $cred = Get-Credential -Message "Enter DOMAIN\Username"
    .\Install-SysmonWinlogbeat-Simple.ps1 -ComputerName "PC01" `
        -SysmonPath "C:\Tools\Sysmon" `
        -WinlogbeatPath "C:\Tools\Winlogbeat" `
        -WinlogbeatConfig "C:\Tools\Winlogbeat\winlogbeat.yml"

Example for multiple hosts:
    $computers = Get-Content "C:\temp\hosts.txt"
    .\Install-SysmonWinlogbeat-Simple.ps1 -ComputerName $computers ...
#>

param(
    [Parameter(Mandatory=$true)]
    [string[]]$ComputerName,                    # One or more computer names

    [Parameter(Mandatory=$true)]
    [string]$SysmonPath,                        # Local folder containing Sysmon64.exe

    [Parameter(Mandatory=$true)]
    [string]$WinlogbeatPath,                    # Local folder containing winlogbeat.exe

    [string]$SysmonConfig,                      # Optional: Path to your sysmonconfig.xml

    [string]$WinlogbeatConfig                   # Path to your edited winlogbeat.yml (recommended)
)

Write-Host "=== Sysmon + Winlogbeat Remote Installation ===" -ForegroundColor Cyan

# ============================================
# STEP 1: Set Trusted Hosts (if needed)
# ============================================
Write-Host "`n[1] Configuring Trusted Hosts for WinRM..." -ForegroundColor Yellow
# Only needed if hosts are not in the same domain or trusted.
# Example: Set-Item WSMan:\localhost\Client\TrustedHosts -Value "PC01,PC02,*.yourdomain.local" -Force
Write-Host "   (Edit the script and uncomment the Set-Item line above if you need to add hosts)" -ForegroundColor Gray

# ============================================
# STEP 2: Get Domain Credentials
# ============================================
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter domain credentials (DOMAIN\Username)"
}

# ============================================
# STEP 3: Install on each remote host
# ============================================
$results = @()

foreach ($computer in $ComputerName) {
    Write-Host "`n--- Processing: $computer ---" -ForegroundColor Magenta

    try {
        # Create remote session
        $session = New-PSSession -ComputerName $computer -Credential $Credential -ErrorAction Stop
        Write-Host "   Session established." -ForegroundColor Green

        # Create temp folder on remote
        $remoteTemp = "C:\Windows\Temp\Installers"
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -Path $using:remoteTemp -ItemType Directory -Force | Out-Null
        }

        # Copy Sysmon files
        Copy-Item -Path "$SysmonPath\*" -Destination $remoteTemp -ToSession $session -Recurse -Force
        Write-Host "   Sysmon files copied." -ForegroundColor Green

        # Copy Winlogbeat files
        Copy-Item -Path "$WinlogbeatPath\*" -Destination $remoteTemp -ToSession $session -Recurse -Force
        Write-Host "   Winlogbeat files copied." -ForegroundColor Green

        # Copy configs if provided
        if ($SysmonConfig -and (Test-Path $SysmonConfig)) {
            Copy-Item -Path $SysmonConfig -Destination "$remoteTemp\sysmonconfig.xml" -ToSession $session -Force
        }
        if ($WinlogbeatConfig -and (Test-Path $WinlogbeatConfig)) {
            Copy-Item -Path $WinlogbeatConfig -Destination "$remoteTemp\winlogbeat.yml" -ToSession $session -Force
            Write-Host "   Winlogbeat config copied." -ForegroundColor Green
        }

        # Run installation commands on remote host
        $installStatus = Invoke-Command -Session $session -ScriptBlock {
            param($temp, $hasSysmonConfig, $hasWinlogbeatConfig)

            # --- Install Sysmon ---
            $sysmonExe = Join-Path $temp "Sysmon64.exe"
            if (Test-Path $sysmonExe) {
                if ($hasSysmonConfig) {
                    & $sysmonExe -accepteula -i "$temp\sysmonconfig.xml" | Out-Null
                } else {
                    & $sysmonExe -accepteula -i | Out-Null
                }
            }

            # --- Install Winlogbeat ---
            $wbExe = Join-Path $temp "winlogbeat.exe"
            if (Test-Path $wbExe) {
                if ($hasWinlogbeatConfig) {
                    # Use the copied config
                    Copy-Item "$temp\winlogbeat.yml" -Destination (Join-Path $temp "winlogbeat.yml") -Force
                }
                & $wbExe install | Out-Null
                Start-Service winlogbeat -ErrorAction SilentlyContinue
            }

            # Simple check
            [pscustomobject]@{
                SysmonStatus      = (Get-Service Sysmon -ErrorAction SilentlyContinue).Status
                WinlogbeatStatus  = (Get-Service winlogbeat -ErrorAction SilentlyContinue).Status
            }
        } -ArgumentList $remoteTemp, [bool]$SysmonConfig, [bool]$WinlogbeatConfig

        $results += [pscustomobject]@{
            Computer   = $computer
            Sysmon     = $installStatus.SysmonStatus
            Winlogbeat = $installStatus.WinlogbeatStatus
        }

        Remove-PSSession $session
        Write-Host "   Installation completed on $computer" -ForegroundColor Green

    } catch {
        Write-Host "   ERROR on ${computer}: $($_.Exception.Message)" -ForegroundColor Red
        $results += [pscustomobject]@{
            Computer = $computer
            Sysmon   = "ERROR"
            Winlogbeat = "ERROR"
        }
    }
}

# ============================================
# STEP 4: Final Status Report
# ============================================
Write-Host "`n=== FINAL INSTALLATION CHECK ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Save simple report
$csvPath = ".\Sysmon_Winlogbeat_Install_Report_$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Report saved to: $csvPath" -ForegroundColor Gray

Write-Host "`nDone. Check that both services show as 'Running'." -ForegroundColor Cyan
