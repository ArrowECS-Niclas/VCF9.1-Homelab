<#
.SYNOPSIS
    VCF 9.1 Management Domain Startup or shut-down

.DESCRIPTION
    Combined script that either powers on VCF hosts (via Homey Pro smart plugs)
    and starts a VCF 9.1 Management Domain, or cleanly shuts it down and powers
    the hosts off again.

    Startup order follows:
    https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/sddc-startup/start-the-management-domain.html

    Shut-down order follows:
    https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html

.PARAMETER EnvConfigFile
    Required. Path to the PowerShell configuration file that contains VM display names,
    hostnames, Homey Pro settings, credentials, etc.

.PARAMETER Action
    Required. Must be either 'Startup' or 'Shutdown'.
    Controls which sequence is executed. The opposite sequence is never run.

.EXAMPLE
    ./Full-VCF-9-1-Start-Shutdown.ps1 -EnvConfigFile ./sample-variables.ps1 -Action Startup

.EXAMPLE
    ./Full-VCF-9-1-Start-Shutdown.ps1 -EnvConfigFile ./sample-variables.ps1 -Action Shutdown

.NOTES
    Author  : Niclas Borgstrom
    Version : 1.1

    Requirements:
    - PowerShell 7+
    - VMware PowerCLI (Install-Module VCF.PowerCLI)
    - For Shutdown: vcf_services_runtime_shutdown.ps1 must be present in the same folder
      (https://github.com/WardVissers/VCF-Public/blob/main/vcf_services_runtime_shutdown.ps1)
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$EnvConfigFile,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Startup', 'Shutdown')]
    [string]$Action
)

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if (-not (Test-Path -Path $EnvConfigFile -PathType Leaf)) {
    Write-Host -ForegroundColor Red "`nNo valid deployment configuration file was provided or file was not found.`n"
    exit 1
}

. $EnvConfigFile  # Dot-source the config file

# ---------------------------------------------------------------------------
# Shared helper functions
# ---------------------------------------------------------------------------

function Start-VMIfExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$VMName
    )

    foreach ($name in $VMName) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $vms = Get-VM -Name $name -ErrorAction SilentlyContinue |
               Where-Object { $_.PowerState -eq "PoweredOff" }

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

function Get-HomeyDevices {
    param (
        [hashtable]$Headers,
        [string]$HomeyIP
    )
    $url = "$HomeyIP/api/manager/devices/device/"
    return Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
}

function Set-HomeyDeviceOn {
    param (
        [string]$DeviceId,
        [hashtable]$Headers,
        [string]$HomeyIP
    )

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

function Set-HomeyDeviceOff {
    param (
        [string]$DeviceId,
        [hashtable]$Headers,
        [string]$HomeyIP
    )

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

function Show-HomeyDeviceNames {
    param ($devices)

    Write-Host "`n=== All Devices (Name only) in Homey Pro for reference ===" -ForegroundColor Cyan
    $devices.PSObject.Properties | ForEach-Object {
        $d = $_.Value
        if ($d.name) { Write-Host $d.name }
    }
}

# ===========================================================================
# Startup SEQUENCE
# ===========================================================================
if ($Action -eq 'Startup') {

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  VCF 9.1 Management Domain Startup" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green

    # --- Homey Pro: power on smart plugs ---
    if ($PowerOnSmartplugs) {
        $Headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
        }

        Write-Host "Fetching devices from Homey..." -ForegroundColor Cyan
        $devices = Get-HomeyDevices -Headers $Headers -HomeyIP $HomeyIP

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
                Set-HomeyDeviceOn -DeviceId $dev.id -Headers $Headers -HomeyIP $HomeyIP
            }
            else {
                Write-Host "⚠️  Device not found: $name" -ForegroundColor Magenta
            }
        }

        Show-HomeyDeviceNames -devices $devices

        # Wait until vCenter IP becomes reachable
        Write-Host "`nWaiting for $vcentersrv IP address to become available..." -ForegroundColor Cyan
        while (-not (Test-Connection -ComputerName $vcentersrv -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            Start-Sleep -Seconds 2
        }
    }
    else {
        Write-Host "`nSkipping Homey Pro Power-On (PowerOnSmartplugs is not enabled)." -ForegroundColor Yellow
    }

    # --- VCF Startup ---
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
                if ($global:DefaultVIServer) {
                    Disconnect-VIServer -Server $vcentersrv -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }

        $cluster = Get-Cluster -Name $clustername -ErrorAction Stop

        # Start the vSAN cluster
        Write-Host "Starting vSAN cluster '$clustername'..." -ForegroundColor Cyan
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

        # vSAN health check
        Write-Host "Running quick vSAN health check..." -ForegroundColor Cyan
        try {
            $health = Test-VsanClusterHealth -Cluster $cluster -ErrorAction Stop
            Write-Host "vSAN health check completed." -ForegroundColor Green
        }
        catch {
            Write-Host "vSAN health check reported issues (continuing anyway): $_" -ForegroundColor Yellow
        }

        Write-Host "`nProceeding to start management VMs..." -ForegroundColor Green
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

        $controlNodes = Get-Folder -Name "vcf-management-services" -ErrorAction SilentlyContinue |
                        Get-VM | Where-Object { $_.NumCpu -le 8 -and $_.PowerState -eq "PoweredOff" }

        if ($controlNodes) {
            Write-Host "Powering on control nodes: $($controlNodes.Name -join ', ')" -ForegroundColor Cyan
            $controlNodes | Start-VM -Confirm:$false
            Start-Sleep -Seconds 180   # wait for control plane
        }

        $workerNodes = Get-Folder -Name "vcf-management-services" -ErrorAction SilentlyContinue |
                       Get-VM | Where-Object { $_.NumCpu -gt 8 -and $_.PowerState -eq "PoweredOff" }

        if ($workerNodes) {
            Write-Host "Powering on worker nodes: $($workerNodes.Name -join ', ')" -ForegroundColor Cyan
            $workerNodes | Start-VM -Confirm:$false
            Start-Sleep -Seconds 300   # workers take longer
        }

        # Fallback if folder naming differs
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
        Write-Host "`nSkipping VCF Startup (StartUpVCF is not enabled)." -ForegroundColor Yellow
    }
}

# ===========================================================================
# SHUTDOWN SEQUENCE
# ===========================================================================
elseif ($Action -eq 'Shutdown') {

    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "  VCF 9.1 Management Domain SHUTDOWN" -ForegroundColor Red
    Write-Host "========================================`n" -ForegroundColor Red

    # --- VCF shutdown ---
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
        Write-Host "`nSkipping VCF Services shutdown (ShutdownVCF is not enabled)." -ForegroundColor Yellow
    }

    # --- Homey Pro: power off smart plugs ---
    if ($PowerOffSmartplugs) {
        Write-Host "`nRunning Homey Pro Power-Off script" -ForegroundColor Cyan

        $Headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
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

        Write-Host "Fetching devices from Homey..." -ForegroundColor Cyan
        $devices = Get-HomeyDevices -Headers $Headers -HomeyIP $HomeyIP

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
                Set-HomeyDeviceOff -DeviceId $dev.id -Headers $Headers -HomeyIP $HomeyIP
            }
            else {
                Write-Host "⚠️  Device not found: $name" -ForegroundColor Magenta
            }
        }

        Show-HomeyDeviceNames -devices $devices
    }
    else {
        Write-Host "`nSkipping Homey Pro Power-Off (PowerOffSmartplugs is not enabled)." -ForegroundColor Yellow
    }
}

Write-Host "`nScript finished (Action = $Action)." -ForegroundColor Cyan