<#
.SYNOPSIS
    VCF 9.1 Management Domain startup

.DESCRIPTION
    Powers on VCF hosts using Homey Pro smart plugs and starts a VCF 9.1 Management Domain homelab based on the official startup order:
    https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/sddc-startup/start-the-management-domain.html

.PARAMETER EnvConfigFile
    Path to the powershell configuration file.

    The file contains VM display names, Hostnames and Homey Pro information
    settings.

.EXAMPLE
    ./Full-VCF-9-1-Start-up.ps1 -EnvConfigFile ./sample-variables.ps1

    Runs the script using sample-variables.ps1 from the current directory.

.NOTES
    Author  : Niclas Borgstrom
    Version : 1.0

    Companion to the management domain shutdown script.

    Requirements:
    - PowerShell 7+
    - VMware PowerCLI
    - Access to the target VCF hosts

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

function Start-VMIfExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$VMName
    )

    foreach ($name in $VMName) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $vms = Get-VM -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.PowerState -eq "PoweredOff" }

        if ($vms) {
            Write-Host "Powering on: $($vms.Name -join ', ')" -ForegroundColor Cyan
            $vms | Start-VM -Confirm:$false
        }
        else {
            Write-Host "No powered-off VM found for pattern: $name (already on or not found)" -ForegroundColor DarkGray
        }
    }
}

function Wait-VMTools {
    param (
        [string[]]$VMName,
        [int]$TimeoutSeconds = 600
    )

    foreach ($name in $VMName) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $vms = Get-VM -Name $name -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            Write-Host "Waiting for VMware Tools on $($vm.Name)..." -ForegroundColor Yellow
            $elapsed = 0
            while ($vm.ExtensionData.Guest.ToolsStatus -notin @("toolsOk", "toolsOld") -and $elapsed -lt $TimeoutSeconds) {
                Start-Sleep -Seconds 15
                $elapsed += 15
                $vm = Get-VM -Id $vm.Id
            }
            if ($elapsed -ge $TimeoutSeconds) {
                Write-Host "Timeout waiting for Tools on $($vm.Name)" -ForegroundColor Red
            }
            else {
                Write-Host "$($vm.Name) is ready." -ForegroundColor Green
            }
        }
    }
}

# Turn on a device by ID (assumes it has 'onoff' capability)
function Set-HomeyDeviceOn {
    param([string]$DeviceId)

    $url = "$HomeyIP/api/manager/devices/device/$DeviceId/capability/onoff"
    $body = @{ value = $true } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri $url -Headers $Headers -Method Put -Body $body | Out-Null
        Write-Host "✅ Turned ON: $DeviceId" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Failed to turn on $DeviceId : $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($PowerOnSmartplugs) {
    $Headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }

    # Get all devices
    function Get-HomeyDevices {
        $url = "$HomeyIP/api/manager/devices/device/"
        $response = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
        return $response
    }

    # Main logic
    Write-Host "Fetching devices from Homey..." -ForegroundColor Cyan
    $devices = Get-HomeyDevices

    # Build a name -> device lookup
    $deviceMap = @{}
    foreach ($dev in $devices.PSObject.Properties) {
        $d = $dev.Value
        if ($d.name) {
            $deviceMap[$d.name] = $d
        }
    }

    Write-Host "Found $($deviceMap.Count) devices.`n" -ForegroundColor Cyan

    # Turn on the target devices
    foreach ($name in $HomeyDeviceNames) {
        if ($deviceMap.ContainsKey($name)) {
            $dev = $deviceMap[$name]
            Write-Host "Found device: $($dev.name) (ID: $($dev.id))" -ForegroundColor Yellow
            Set-HomeyDeviceOn -DeviceId $dev.id
        }
        else {
            Write-Host "⚠️  Device not found: $name" -ForegroundColor Magenta
        }
    }

    # Display all devices by name in Homey for reference
    Write-Host "`n=== All Devices (Name only) ===" -ForegroundColor Cyan
    $devices.PSObject.Properties | ForEach-Object {
        $d = $_.Value
        if ($d.name) { Write-Host $d.name }
    }

    # Wait until $vcentersrv IP address becomes available
    Write-Host "`nWaiting for $vcentersrv IP address to become available..." -ForegroundColor Cyan

    while (-not (Test-Connection -ComputerName $vcentersrv -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 2
    }
}
else {
    Write-Host "`nSkipping Homey Pro Power-On script." -ForegroundColor Yellow
}

if ($StartUpVCF) {
    Write-Host "`nWaiting for $vcentersrv services to become fully available..." -ForegroundColor Cyan

    $SecurePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force
    $Credential = [PSCredential]::new($Username, $SecurePassword)

    while ($true) {
        try {
            $viServer = Connect-VIServer -Server $vcentersrv -Credential $Credential -ErrorAction Stop

            # Verify that the vCenter API is actually responding
            $null = Get-Datacenter -Server $viServer -ErrorAction Stop

            Write-Host "✅ $vcentersrv is fully available." -ForegroundColor Green
            Write-Host "Let vCenter stabilize for 60s before continuing"
            Start-Sleep -Seconds 60
            break
        }
        catch {
            Write-Host "vCenter not ready yet. Retrying in 10 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            # Clean up any partial/failed connection before retrying
            if ($global:DefaultVIServer) {
                Disconnect-VIServer -Server $vcentersrv -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    $cluster = Get-Cluster -Name $clustername -ErrorAction Stop

    # Start the VSAN cluster
    Write-Host "Starting vSAN cluster '$clustername'..." -ForegroundColor Cyan

    # Initiate the cluster power-on (equivalent to UI "Restart cluster")
    Start-VsanCluster -Cluster $cluster -PowerOnReason "VCF management domain startup"

    # Wait until the cluster reports it is powered on
    $timeoutMinutes = 10
    $pollSeconds    = 30
    $elapsed        = 0
    $maxSeconds     = $timeoutMinutes * 60

    do {
        Start-Sleep -Seconds $pollSeconds
        $elapsed += $pollSeconds

        $state = Get-VsanClusterPowerState -Cluster $cluster -ErrorAction SilentlyContinue

        $current = $state.CurrentClusterPowerStatus
        Write-Host ("[{0:mm\:ss}] vSAN cluster power state: {1}" -f ([TimeSpan]::FromSeconds($elapsed)), $current) -ForegroundColor Yellow

        if ($elapsed -ge $maxSeconds) {
            throw "Timeout after $timeoutMinutes minutes waiting for vSAN cluster to become poweredOn. Last state: $current"
        }
    } while ($current -ne "clusterPoweredOn")

    Write-Host "vSAN cluster is powered on." -ForegroundColor Green

    # VSAN health check
    Write-Host "Running quick vSAN health check..." -ForegroundColor Cyan
    try {
        $health = Test-VsanClusterHealth -Cluster $cluster -ErrorAction Stop
        Write-Host "vSAN health check completed." -ForegroundColor Green
    }
    catch {
        Write-Host "vSAN health check reported issues (continuing anyway): $_" -ForegroundColor Yellow
    }

    Write-Host "`nProceeding to start management VMs..." -ForegroundColor Green

    # Continue with powering on VMs
    Write-Host "`n=== Starting Management Domain components ===" -ForegroundColor Green

    # SDDC Manager
    Write-Host "`n[ SDDC Manager ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $SDDCManager
    Wait-VMTools -VMName $SDDCManager

    # NSX Manager
    Write-Host "`n[ NSX Manager ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $NSXManagerNodes
    Wait-VMTools -VMName $NSXManagerNodes
    Start-Sleep -Seconds 60   # give NSX cluster time to form

    # NSX Edge / VNA
    Write-Host "`n[ NSX Edge / VNA ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $NSXEdges, $VNANodes
    Wait-VMTools -VMName $NSXEdges, $VNANodes

    # VCF Operations
    Write-Host "`n[ VCF Operations ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $VCFOperations
    Wait-VMTools -VMName $VCFOperations
    Write-Host "Remember to bring the VCF Operations cluster online in the /admin UI if required." -ForegroundColor Yellow

    # VCF Management Services (control nodes first, then workers)
    Write-Host "`n[ VCF Management Services ]" -ForegroundColor Magenta

    # Control nodes (fewer CPUs)
    $controlNodes = Get-Folder -Name "vcf-management-services" -ErrorAction SilentlyContinue |
                    Get-VM | Where-Object { $_.NumCpu -le 8 -and $_.PowerState -eq "PoweredOff" }

    if ($controlNodes) {
        Write-Host "Powering on control nodes: $($controlNodes.Name -join ', ')" -ForegroundColor Cyan
        $controlNodes | Start-VM -Confirm:$false
        Start-Sleep -Seconds 180   # wait for control plane
    }

    # Worker nodes (remaining VMs in the folder)
    $workerNodes = Get-Folder -Name "vcf-management-services" -ErrorAction SilentlyContinue |
                Get-VM | Where-Object { $_.NumCpu -gt 8 -and $_.PowerState -eq "PoweredOff" }

    if ($workerNodes) {
        Write-Host "Powering on worker nodes: $($workerNodes.Name -join ', ')" -ForegroundColor Cyan
        $workerNodes | Start-VM -Confirm:$false
        Start-Sleep -Seconds 300   # workers take longer
    }

    # Fallback if folder naming differs – use the pattern variable
    Start-VMIfExists -VMName $VCFManagementServices

    # License Server
    Write-Host "`n[ License Server ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $LicenseServer
    Wait-VMTools -VMName $LicenseServer

    # Cloud Proxy
    Write-Host "`n[ Cloud Proxy ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $CloudProxy
    Wait-VMTools -VMName $CloudProxy

    # VCF Operations for Networks
    Write-Host "`n[ VCF Operations for Networks ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $VCFOperationsforNetworks
    Wait-VMTools -VMName $VCFOperationsforNetworks

    # VCF Automation
    Write-Host "`n[ VCF Automation ]" -ForegroundColor Magenta
    Start-VMIfExists -VMName $VCFAutomation
    Wait-VMTools -VMName $VCFAutomation

    # Final status
    Write-Host "`n=== Final power state of key VCF VMs ===" -ForegroundColor Green
    Get-VM |
        Where-Object {
            $_.Name -like $VCFAutomation -or
            $_.Name -like $VCFManagementServices -or
            $_.Name -eq $VCFOperations -or
            $_.Name -eq $CloudProxy -or
            $_.Name -eq $LicenseServer -or
            $_.Name -eq $SDDCManager -or
            $_.Name -like $NSXManagerNodes -or
            $_.Name -eq $vcentersrv.Split('.')[0]
        } | Select-Object Name, PowerState | Sort-Object Name | Format-Table -AutoSize

    Write-Host "`nStartup sequence completed." -ForegroundColor Green
    Write-Host "Verify VCF Operations cluster is online and VCF Management Services are healthy in the UI." -ForegroundColor Yellow

    Disconnect-VIServer -Server $vcentersrv -Confirm:$false
}
else {
    Write-Host "`nSkipping VCF Start-up script." -ForegroundColor Yellow
}