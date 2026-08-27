<#
.SYNOPSIS
    VCF 9.1 Management domain shutdown

.DESCRIPTION
    Cleanly shuts down a VCF 9.1 Management Domain homelab based on the official shutdown order:
    https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html

    Shuts down the VCF Managment Services cluster, all VCF related VMs, vSAN and vCenter server and shuts down the hosts at the end.
    Also powers off hosts from the grid using Homey Pro smart power plugs.

    Assumes any workload domain and any non-VCF related VMS in the Management domain are already shut down before running this script.

.PARAMETER EnvConfigFile
    Path to the powershell configuration file.

    The file contains VM display names, Hostnames and Homey Pro information
    settings.

.EXAMPLE
    ./Full-VCF-9-1-Shut-down.ps1 -EnvConfigFile ./sample-variables.ps1

    Runs the script using sample-variables.ps1 from the current directory.

.NOTES
    Author  : Niclas Borgstrom
    Version : 1.0

    Based/inspired by "VCF Services shutdown" by Ward Vissers (NOT REQUIRED to be available):
    https://github.com/WardVissers/VCF-Public/blob/main/VCF%209.1%20Shutdown%20VCF%20Services%20VMs.ps1

    Companion script (REQUIRED to be available, stored in the same folder):
    https://github.com/WardVissers/VCF-Public/blob/main/vcf_services_runtime_shutdown.ps1

    Companion to the management domain start-up script.

    Requirements:
    - PowerShell 7+
    - VMware PowerCLI
    - Access to the target VCF Management Domain vCenter Server
    - vcf_services_runtime_shutdown.ps1 present in the same folder

    Install PowerCLI with:
      Install-Module VCF.PowerCLI
#>

param (
    [string]$EnvConfigFile
)

# Validate that the file exists
if ($EnvConfigFile -and (Test-Path $EnvConfigFile)) {
    . $EnvConfigFile  # Dot-sourcing the config file
} else {
    Write-Host -ForegroundColor Red "`nNo valid deployment configuration file was provided or file was not found.`n"
    exit
}

function Stop-VMGuestIfExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$VMName
    )

    foreach ($name in $VMName) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $vms = Get-VM -Name $name -ErrorAction SilentlyContinue |
               Where-Object { $_.PowerState -eq "PoweredOn" }

        if ($vms) {
            Write-Host "Gracefully shutting down: $($vms.Name -join ', ')" -ForegroundColor Cyan
            $vms | Shutdown-VMGuest -Confirm:$false
        }
        else {
            Write-Host "No powered-on VM found for pattern: $name" -ForegroundColor DarkGray
        }
    }
}

if ($ShutdownVCF) {
    $SecurePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force
    $Credential = [PSCredential]::new($Username, $SecurePassword)

    # Reliable script location
    $vcf_folder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    Set-Location $vcf_folder

    $runtimeShutdownScript = Join-Path $vcf_folder "vcf_services_runtime_shutdown.ps1"

    if (-not (Test-Path -Path $runtimeShutdownScript -PathType Leaf)) {
        Write-Host "Required file not found: vcf_services_runtime_shutdown.ps1" -ForegroundColor Red
        Write-Host "Download it here and place it in the same folder as this script:" -ForegroundColor Yellow
        Write-Host "https://github.com/WardVissers/VCF-Public/blob/main/vcf_services_runtime_shutdown.ps1" -ForegroundColor Cyan
        throw "Missing required companion script: vcf_services_runtime_shutdown.ps1"
    }

    try {
        Connect-VIServer -Server $vcentersrv -Credential $Credential -ErrorAction Stop
    }
    catch {
        throw "Failed to connect to vCenter $vcentersrv : $_"
    }

    $cluster = Get-Cluster -Name $clustername -ErrorAction Stop

    # Get first control-node IPv4
    $ControlNodeIP = Get-Folder -Name "vcf-management-services" -ErrorAction Stop |
        Get-VM | Where-Object { $_.NumCpu -le 8 -and $_.PowerState -eq "PoweredOn" } |
        ForEach-Object {
            $_.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        } | Select-Object -First 1

    if (-not $ControlNodeIP) {
        throw "Unable to determine VCF Management Services control node IP"
    }

    Write-Host "Control Node IP: $ControlNodeIP" -ForegroundColor Green

    # Shutdown VCF Services Runtime
    .\vcf_services_runtime_shutdown.ps1 -NodeIp $ControlNodeIP -Credential $Credential -Password $VMSP_PASSWORD

    # Individual components (order matters)
    Stop-VMGuestIfExists -VMName $VCFAutomation
    Stop-VMGuestIfExists -VMName $VCFOperationsforNetworks
    Stop-VMGuestIfExists -VMName $CloudProxy
    Stop-VMGuestIfExists -VMName $LicenseServer
    Stop-VMGuestIfExists -VMName $VCFManagementServices
    Stop-VMGuestIfExists -VMName $VCFOperations
    Stop-VMGuestIfExists -VMName $NSXEdge, $VNANodes
    Stop-VMGuestIfExists -VMName $NSXManagerNodes
    Stop-VMGuestIfExists -VMName $SDDCManager

    # Give graceful shutdowns some time
    Write-Host "Waiting 90 seconds for graceful shutdowns..." -ForegroundColor Yellow
    Start-Sleep -Seconds 90

    # Wait for VMs (except vCenter) to shutdown
    $vcenterHostname = $vcentersrv.Split('.')[0]

    Write-Host "Waiting for all VMs to reach PoweredOff state (excluding $vcenterHostname and vCLS-*)..." -ForegroundColor Cyan

    do {
        $stillPoweredOn = Get-VM | Where-Object {
            $_.PowerState -ne "PoweredOff" -and
            $_.Name -ne $vcenterHostname -and
            $_.Name -notlike "vCLS-*"
        }

        if ($stillPoweredOn) {
            Write-Host "Still waiting for the following VMs to power off:" -ForegroundColor Yellow
            $stillPoweredOn | Select-Object Name, PowerState | Format-Table -AutoSize
            Start-Sleep -Seconds 15
        }
    } while ($stillPoweredOn)

    Write-Host "All VMs are now PoweredOff (except $vcenterHostname)." -ForegroundColor Green

    # Final check
    Get-VM | Select-Object Name, PowerState | Sort-Object Name | Format-Table -AutoSize

    # vSAN cluster shutdown (connection will be lost when vCenter is powered off)
    Write-Host "Starting vSAN cluster shutdown..." -ForegroundColor Cyan
    try {
        Stop-VsanCluster -Cluster $cluster -PowerOffReason "VCF management domain shutdown" -ErrorAction Stop
    }
    catch {
        # Expected when vCenter goes offline
        Write-Host "vSAN shutdown initiated (or connection lost as expected): $_" -ForegroundColor Yellow
    }

    Disconnect-VIServer -Server $vcentersrv -Confirm:$false -ErrorAction SilentlyContinue
}
else {
    Write-Host "`nSkipping VCF Services shutdown script." -ForegroundColor Yellow
}

# Run the power off script to bring the environment completely off-line
if ($PowerOffSmartplugs) {
    Write-Host "`nRunning Homey Pro Power-Off script" -ForegroundColor Cyan

    $Headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }

    function Get-HomeyDevices {
        $url = "$HomeyIP/api/manager/devices/device/"
        Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
    }

    # Turn off a device by ID
    function Set-HomeyDeviceOff {
        param([string]$DeviceId)

        $url = "$HomeyIP/api/manager/devices/device/$DeviceId/capability/onoff"
        $body = @{ value = $false } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $url -Headers $Headers -Method Put -Body $body | Out-Null
            Write-Host "✅ Turned OFF: $DeviceId" -ForegroundColor Green
        }
        catch {
            Write-Host "❌ Failed to turn off $DeviceId : $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Verify that the hosts are shutdown before powering off the power plug
    Write-Host "Checking if $($VCFHosts.Count) host(s) are shutdown before proceeding..." -ForegroundColor Cyan
    Write-Host ""

    Write-Host "`nWaiting for all VCF hosts to shut down..." -ForegroundColor Cyan

    while ($true) {
        $allDown = $true
        foreach ($hostname in $VCFHosts) {
            $isUp = Test-Connection -ComputerName $hostname -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($isUp) {
                Write-Host "[UP]   $hostname" -ForegroundColor Yellow
                $allDown = $false
            }
            else {
                Write-Host "[DOWN] $hostname" -ForegroundColor Green
            }
        }

        if ($allDown) {
            Write-Host "`nAll VCF hosts are shut down." -ForegroundColor Green
            break
        }

        Write-Host "`nSome hosts are still running. Checking again in 10 seconds..." -ForegroundColor Cyan
        Start-Sleep -Seconds 10
        Write-Host ""
    }

    Write-Host "All hosts are shutdown. Continuing..." -ForegroundColor Magenta

    # Poweroff power plugs in Homey Pro defined in the variables file
    Write-Host "Fetching devices from Homey..." -ForegroundColor Cyan
    $devices = Get-HomeyDevices

    $deviceMap = @{}
    foreach ($dev in $devices.PSObject.Properties) {
        $d = $dev.Value
        if ($d.name) {
            $deviceMap[$d.name] = $d
        }
    }

    Write-Host "Found $($deviceMap.Count) devices.`n" -ForegroundColor Cyan

    foreach ($name in $HomeyDeviceNames) {
        if ($deviceMap.ContainsKey($name)) {
            $dev = $deviceMap[$name]
            Write-Host "Found device: $($dev.name) (ID: $($dev.id))" -ForegroundColor Yellow
            Set-HomeyDeviceOff -DeviceId $dev.id
        }
        else {
            Write-Host "⚠️  Device not found: $name" -ForegroundColor Magenta
        }
    }

    # Display all devices by name in Homey for reference
    Write-Host "`n=== All Devices (Name only) in Homey Pro ===" -ForegroundColor Cyan
    $devices.PSObject.Properties | ForEach-Object {
        $d = $_.Value
        if ($d.name) { Write-Host $d.name }
    }
}
else {
    Write-Host "`nSkipping Homey Pro Power-Off script." -ForegroundColor Yellow
}