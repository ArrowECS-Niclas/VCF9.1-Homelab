#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestrates a safe, ordered shutdown of the VCF Services Runtime system.

.DESCRIPTION
    vcf_services_runtime_shutdown.ps1

    Orchestrates a safe, ordered shutdown of the VCF Services Runtime
    system via the management REST API, then powers off the underlying
    VMs via vSphere. No kubectl access is required.

    Shutdown order:
        The system shutdown API is invoked, which handles scaling down all
        tenant workloads and platform controllers, and creates the global
        power-off-marker for automatic recovery on boot.

    Copyright (c) 2026 Broadcom. All Rights Reserved.
    Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
    and/or its subsidiaries.

    https://knowledge.broadcom.com/external/article/440874/how-to-safely-shutdown-all-nodes-within.html
    https://knowledge.broadcom.com/external/article/440862/vcf-management-services-cluster-or-the-v.html

.PARAMETER NodeIp
    IP address of any reachable cluster node (API server listens on port 5480).

.PARAMETER NodePort
    Node HTTPS port to host management APIs (default: 5480).

.PARAMETER Password
    Breakglass password for vmware-system-user. Omit to be prompted interactively.

.PARAMETER DryRun
    Log planned actions without executing any shutdown or power-off operations.

.PARAMETER SkipPoweroff
    Shut down components but leave VMs running.

.PARAMETER SkipSnapshotCheck
    Bypass the VM snapshot pre-flight check.

.NOTES
    Environment variables (override defaults / used if parameters are omitted):
        NODE_IP                 IP address of any reachable cluster node.
        NODE_PORT               Node HTTPS port to host management APIs (default: 5480).
        VMSP_PASSWORD           Breakglass password (avoids interactive prompt).
        VCENTER_SERVER          vCenter server FQDN/IP. Auto-discovered from the vsp
                                 component config if not set.
        VCENTER_USERNAME        vCenter username. If unset, automated VM power-off
                                 is skipped and the VM list is printed for manual action.
        VCENTER_PASSWORD        vCenter password. If unset, automated VM power-off
                                 is skipped and the VM list is printed for manual action.
        VCENTER_INSECURE        Set to "true" to skip TLS certificate validation (default: true).
        TASK_POLL_INTERVAL      Seconds between task status polls (default: 15).
        TASK_TIMEOUT_SECONDS    Seconds to wait for a component shutdown task (default: 600).
        POWEROFF_WAIT_SECONDS   Seconds to wait between VM power-off calls (default: 5).

    Requires PowerShell 7+ (for -SkipCertificateCheck support on Invoke-RestMethod).
    Requires the vcf.powercli module for automated VM power-off:
        Install-Module -Name vcf.powercli -Scope CurrentUser

.EXAMPLE
    .\vcf_services_runtime_shutdown.ps1 -NodeIp 10.0.0.10

.EXAMPLE
    .\vcf_services_runtime_shutdown.ps1 -NodeIp 10.0.0.10 -DryRun

.EXAMPLE
    .\vcf_services_runtime_shutdown.ps1 -NodeIp 10.0.0.10 -SkipPoweroff -SkipSnapshotCheck
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "IP address of any reachable cluster node.")]
    [string]$NodeIp = $env:NODE_IP,

    [Parameter(HelpMessage = "Node HTTPS port to host management APIs (default: 5480).")]
    [int]$NodePort = $(if ($env:NODE_PORT) { [int]$env:NODE_PORT } else { 5480 }),

    [Parameter(HelpMessage = "Breakglass password for vmware-system-user.")]
    [string]$Password = $env:VMSP_PASSWORD,

    [Parameter(HelpMessage = "vCenter Credentials.")]
    [PSCredential]$Credential,

    [switch]$DryRun,
    [switch]$SkipPoweroff,
    [switch]$SkipSnapshotCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants / global state
# ---------------------------------------------------------------------------
$Script:ScriptVersion = "1.0.0"
$Script:ApiUser       = "vmware-system-user"
$Script:LoginPath      = "/api/v1/auth/login"
$Script:ComponentsPath = "/api/v1/components"
$Script:TasksPath      = "/api/v1/tasks"
$Script:NodesPath      = "/api/v1/system/inventory/nodes"

$Script:NodeIp             = $NodeIp
$Script:NodePort            = $NodePort
$Script:Password            = $Password
$Script:DryRun              = $DryRun.IsPresent
$Script:SkipPoweroff        = $SkipPoweroff.IsPresent
$Script:SkipSnapshotCheck   = $SkipSnapshotCheck.IsPresent

$Script:TaskPollInterval = if ($env:TASK_POLL_INTERVAL)   { [int]$env:TASK_POLL_INTERVAL }   else { 15 }
$Script:TaskTimeout      = if ($env:TASK_TIMEOUT_SECONDS) { [int]$env:TASK_TIMEOUT_SECONDS } else { 600 }
$Script:PoweroffWait     = if ($env:POWEROFF_WAIT_SECONDS) { [int]$env:POWEROFF_WAIT_SECONDS } else { 5 }

$Script:VCenterUsername = $Credential.username
$Script:VCenterPassword = $Credential.GetNetworkCredential().Password
$Script:VCenterServer   = $env:VCENTER_SERVER
$Script:VCenterInsecure = if ($env:VCENTER_INSECURE) { $env:VCENTER_INSECURE -eq "true" } else { $true }
$Script:VIConnection    = $null

$Script:ApiBase   = ""
$Script:AuthToken = ""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Get-LogTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-LogTimestamp)] [INFO]  $Message"
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host "[$(Get-LogTimestamp)] [WARN]  $Message" -ForegroundColor Yellow
}

function Write-LogError {
    param([string]$Message)
    Write-Host "[$(Get-LogTimestamp)] [ERROR] $Message" -ForegroundColor Red
}

function Write-LogStep {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 58)
    Write-Host "[$(Get-LogTimestamp)] [STEP]  $Message"
    Write-Host ("=" * 58)
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
function Test-VCenterCredentialsAvailable {
    return (-not [string]::IsNullOrEmpty($Script:VCenterUsername)) -and
           (-not [string]::IsNullOrEmpty($Script:VCenterPassword))
}

function Test-Prerequisites {
    Write-LogStep "Checking prerequisites"

    if (-not $Script:SkipPoweroff -and (Test-VCenterCredentialsAvailable)) {
        $powerCli = Get-Module -ListAvailable -Name vcf.powercli |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $powerCli) {
            Write-LogError "Required module not found: vcf.powercli"
            Write-LogError "Install it with: Install-Module -Name vcf.powercli -Scope CurrentUser"
            Write-LogError "...or re-run with -SkipPoweroff."
            exit 1
        }
        Write-Log "Found: vcf.powercli (v$($powerCli.Version))"
        Import-Module vcf.powercli -ErrorAction Stop | Out-Null

        # Suppress CEIP prompt and allow untrusted/self-signed vCenter certs
        # without an interactive confirmation prompt.
        $invalidCertAction = if ($Script:VCenterInsecure) { "Ignore" } else { "Warn" }
        Set-PowerCLIConfiguration -InvalidCertificateAction $invalidCertAction `
            -ParticipateInCeip $false -Confirm:$false -Scope Session | Out-Null
    }

    if ([string]::IsNullOrEmpty($Script:NodeIp)) {
        Write-LogError "Node IP is required. Use -NodeIp or set the NODE_IP environment variable."
        exit 1
    }

    $Script:ApiBase = "https://$($Script:NodeIp):$($Script:NodePort)"
    Write-Log "Management API base: $($Script:ApiBase)"
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
function Get-PasswordIfNeeded {
    if (-not [string]::IsNullOrEmpty($Script:Password)) {
        return
    }
    $secure = Read-Host -Prompt "Enter the breakglass password for '$($Script:ApiUser)'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $Script:Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrEmpty($Script:Password)) {
        Write-LogError "Password cannot be empty."
        exit 1
    }
}

function Invoke-ApiLogin {
    Write-LogStep "Authenticating with API server"

    Get-PasswordIfNeeded

    $payload = @{ username = $Script:ApiUser; password = $Script:Password } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$($Script:ApiBase)$($Script:LoginPath)" `
            -ContentType "application/json" `
            -Body $payload `
            -SkipCertificateCheck `
            -ErrorAction Stop
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if (-not $statusCode) {
            Write-LogError "Failed to reach API server at $($Script:ApiBase). Check -NodeIp and network connectivity."
        }
        else {
            $errBody = $_.ErrorDetails.Message
            Write-LogError "Authentication failed (HTTP $statusCode): $errBody"
        }
        exit 1
    }

    if (-not $response.token) {
        Write-LogError "No token in login response: $($response | ConvertTo-Json -Compress)"
        exit 1
    }

    $Script:AuthToken = $response.token
    Write-Log "Authentication successful."
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory)][ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body = $null,
        [switch]$IsRetry
    )

    $uri = "$($Script:ApiBase)$Path"
    $headers = @{
        Authorization = "Bearer $($Script:AuthToken)"
        Accept        = "application/json"
    }

    $requestParams = @{
        Method                = $Method
        Uri                   = $uri
        Headers               = $headers
        SkipCertificateCheck  = $true
        ErrorAction           = "Stop"
    }
    if ($Method -eq "Post") {
        $requestParams["ContentType"] = "application/json"
        if ($null -ne $Body) {
            $requestParams["Body"] = ($Body | ConvertTo-Json -Depth 10)
        }
    }

    try {
        return Invoke-RestMethod @requestParams
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

        if (-not $statusCode) {
            Write-LogError "$Method $Path — connection failed."
            exit 1
        }

        if ($statusCode -eq 401 -and -not $IsRetry) {
            Write-Log "Token expired — re-authenticating..."
            Invoke-ApiLogin
            return Invoke-ApiRequest -Method $Method -Path $Path -Body $Body -IsRetry
        }

        $errBody = $_.ErrorDetails.Message
        Write-LogError "$Method $Path failed (HTTP $statusCode): $errBody"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Snapshot pre-check
# ---------------------------------------------------------------------------
function Test-NoSnapshots {
    Write-LogStep "Checking for VM snapshots on VCF Services Runtime nodes"

    if ($Script:SkipSnapshotCheck) {
        Write-LogWarn "Snapshot check skipped (-SkipSnapshotCheck). Ensure no snapshots exist on cluster node VMs before proceeding."
        return
    }

    if ($Script:DryRun) {
        Write-Log "[DRY-RUN] Would check for VM snapshots via API."
        return
    }

    # The actual snapshot check is enforced by the component shutdown precheck
    # workflow triggered by the API. This step is informational only.
    Write-Log "Snapshot pre-check is enforced by the component shutdown precheck workflow."
    Write-Log "Use -SkipSnapshotCheck only if you have manually confirmed no snapshots exist."
    Write-Log "Proceeding — snapshots will be detected during component shutdown prechecks."
}

# ---------------------------------------------------------------------------
# Wait for a task to reach a terminal state
# ---------------------------------------------------------------------------
function Wait-ForTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$TargetName
    )

    Write-Log "  Waiting for task $TaskId ($TargetName)...."
    $elapsed = 0

    while ($true) {
        $taskBody = Invoke-ApiRequest -Method Get -Path "$($Script:TasksPath)/$TaskId"
        $status = if ($taskBody.PSObject.Properties.Name -contains "status" -and $taskBody.status) {
            $taskBody.status
        } elseif ($taskBody.PSObject.Properties.Name -contains "phase" -and $taskBody.phase) {
            $taskBody.phase
        } else {
            "Unknown"
        }

        Write-Log "  Task $TaskId status: $status"

        switch ($status) {
            "Succeeded" {
                Write-Log "  '$TargetName' shutdown succeeded."
                return $true
            }
            "Failed" {
                Write-LogError "  '$TargetName' shutdown task failed."
                $messages = @()
                if ($taskBody.messages) {
                    $messages = @($taskBody.messages | ForEach-Object { $_.default })
                }
                Write-LogError "  Task details: $($messages -join '; ')"
                return $false
            }
        }

        if ($elapsed -ge $Script:TaskTimeout) {
            Write-LogError "  Timed out waiting for task $TaskId ($TargetName) after $($Script:TaskTimeout)s."
            return $false
        }

        Start-Sleep -Seconds $Script:TaskPollInterval
        $elapsed += $Script:TaskPollInterval
    }
}

# ---------------------------------------------------------------------------
# Shut down the system
# ---------------------------------------------------------------------------
function Stop-VcfSystem {
    Write-LogStep "Shutting down VCF Services Runtime system"

    if ($Script:DryRun) {
        Write-Log "  [DRY-RUN] Would POST /api/v1/system?action=shutdown"
        return
    }

    $response = Invoke-ApiRequest -Method Post -Path "/api/v1/system?action=shutdown"
    $taskId = $response.id

    if ([string]::IsNullOrEmpty($taskId)) {
        Write-LogError "  No task ID returned for system shutdown: $($response | ConvertTo-Json -Compress)"
        exit 1
    }

    Write-Log "  System shutdown task created: $taskId"
    if (-not (Wait-ForTask -TaskId $taskId -TargetName "system")) {
        Write-LogError "System shutdown failed. Resolve the failures above before powering off VMs."
        exit 1
    }

    Write-Log "System shut down successfully."
}

# ---------------------------------------------------------------------------
# Retrieve cluster nodes
# ---------------------------------------------------------------------------
function Get-ClusterNodes {
    try {
        $response = Invoke-ApiRequest -Method Get -Path $Script:NodesPath
    }
    catch {
        Write-LogError "Failed to retrieve cluster nodes from $($Script:NodesPath)."
        return @()
    }

    $nodes = @($response.nodes)
    Write-Log "Returned $($nodes.Count) node(s)."
    return $nodes
}

# ---------------------------------------------------------------------------
# Auto-discover vCenter URL from the vsp component configuration
# ---------------------------------------------------------------------------
function Find-VCenterUrl {
    Write-Log "Auto-discovering vCenter URL from vsp component configuration..."

    $response = Invoke-ApiRequest -Method Get -Path "$($Script:ComponentsPath)?type=vsp"

    # The vCenter server is exposed in two possible shapes depending on whether
    # the alias ConfigMap is active:
    #   - nested:  .spec.configuration.infrastructure.vsphere.server  (aliased)
    #   - flat:    .spec.configuration["provider.vsphere.server"]      (canonical)
    $vcenterUrl = $null
    $components = @($response.components)
    if ($components.Count -gt 0) {
        $config = $components[0].spec.configuration
        if ($config) {
            if ($config.infrastructure -and $config.infrastructure.vsphere -and $config.infrastructure.vsphere.server) {
                $vcenterUrl = $config.infrastructure.vsphere.server
            }
            elseif ($config.PSObject.Properties.Name -contains "provider.vsphere.server") {
                $vcenterUrl = $config.'provider.vsphere.server'
            }
        }
    }

    if ([string]::IsNullOrEmpty($vcenterUrl)) {
        Write-LogWarn "Could not determine vCenter URL from vsp component config."
        return $null
    }

    Write-Log "Discovered vCenter server: $vcenterUrl"
    $Script:VCenterServer = $vcenterUrl
    return $Script:VCenterServer
}

# ---------------------------------------------------------------------------
# vCenter connection (vcf.powercli)
# ---------------------------------------------------------------------------
function Initialize-VCenterConnection {
    Write-LogStep "Setting up vCenter connection"

    if ([string]::IsNullOrEmpty($Script:VCenterServer)) {
        $Script:VCenterServer = Find-VCenterUrl
        if ([string]::IsNullOrEmpty($Script:VCenterServer)) {
            Write-LogError "vCenter server could not be determined. Set the VCENTER_SERVER environment variable manually and re-run."
            return $false
        }
    }

    Write-Log "Connecting to vCenter at $($Script:VCenterServer)..."
    try {
        $Script:VIConnection = Connect-VIServer -Server $Script:VCenterServer -Credential $credential -ErrorAction Stop
    }
    catch {
        Write-LogError "Failed to connect to vCenter at $($Script:VCenterServer): $($_.Exception.Message)"
        return $false
    }

    Write-Log "vCenter connection established."
    return $true
}

# ---------------------------------------------------------------------------
# Power off VMs
# ---------------------------------------------------------------------------
function Stop-Vms {
    Write-LogStep "VM Power-Off"

    if ($Script:SkipPoweroff) {
        Write-Log "Skipping VM power-off (-SkipPoweroff)."
        return
    }

    # Get-ClusterNodes logs the node count; failure is non-fatal here —
    # we fall through to the manual-poweroff warning path.
    $nodes = Get-ClusterNodes

    # The API returns vm.moRef (e.g. "vm-1234") for each node. PowerCLI's
    # Get-VM -Id parameter expects the "Kind-value" form: "VirtualMachine-vm-1234".
    $vmRefs = @()      # display form, e.g. "VirtualMachine:vm-1234"
    $vmMorefs = @()    # raw MoRef, e.g. "vm-1234"
    $nodeNames = @()

    if ($nodes.Count -gt 0) {
        foreach ($node in $nodes) {
            $nodeName = $node.name
            $vmMoref = $node.vm.moRef

            if ([string]::IsNullOrEmpty($vmMoref)) {
                Write-LogWarn "  Node '$nodeName' has no VM MoRef — skipping."
                continue
            }

            $vmRef = "VirtualMachine:$vmMoref"
            Write-Log "  Node '$nodeName' -> VM MoRef: $vmRef"
            $vmRefs += $vmRef
            $vmMorefs += $vmMoref
            $nodeNames += $nodeName
        }
    }
    else {
        Write-LogWarn "No nodes returned by API. Cannot determine VMs to power off."
    }

    if (-not (Test-VCenterCredentialsAvailable)) {
        Write-LogWarn "VCENTER_USERNAME and VCENTER_PASSWORD are not set — skipping automated VM power-off."
        Write-LogWarn "Power off the following VMs manually in vCenter before considering the shutdown complete:"
        if ($vmRefs.Count -eq 0) {
            Write-LogWarn "  (no VM MoRefs could be determined from the API)"
        }
        else {
            for ($i = 0; $i -lt $vmRefs.Count; $i++) {
                $name = if ($nodeNames[$i]) { $nodeNames[$i] } else { "unknown" }
                Write-LogWarn "  $name  ->  $($vmRefs[$i])"
            }
        }
        return
    }

    if ($vmRefs.Count -eq 0) {
        Write-LogWarn "No VM MoRefs found. Skipping power-off."
        return
    }

    if (-not (Initialize-VCenterConnection)) {
        Write-LogError "vCenter connection could not be established. Power off VMs manually:"
        for ($i = 0; $i -lt $vmRefs.Count; $i++) {
            $name = if ($nodeNames[$i]) { $nodeNames[$i] } else { "unknown" }
            Write-LogError "  $name  ->  $($vmRefs[$i])"
        }
        exit 1
    }

    try {
        for ($i = 0; $i -lt $vmRefs.Count; $i++) {
            # PowerCLI's -Id parameter takes the vSphere MoRef in "Kind-value"
            # form, e.g. "VirtualMachine-vm-1234".
            $vmId = "VirtualMachine-$($vmMorefs[$i])"
            $name = if ($nodeNames[$i]) { $nodeNames[$i] } else { "unknown" }

            $vm = $null
            try {
                $vm = Get-VM -Id $vmId -Server $Script:VIConnection -ErrorAction Stop
            }
            catch {
                Write-LogWarn "  Could not resolve VM '$vmId' ($name) in vCenter — skipping: $($_.Exception.Message)"
                continue
            }

            if ($vm.PowerState -eq "PoweredOff") {
                Write-Log "  VM '$($vm.Name)' ($vmId) is already powered off — skipping."
                continue
            }

            if ($Script:DryRun) {
                Write-Log "  [DRY-RUN] Would power off VM: $($vm.Name) ($vmId)"
                continue
            }

            Write-Log "  Powering off VM: $($vm.Name) ($vmId, node '$name')"
            try {
                # Stop-VM performs a hard power-off equivalent to pulling the
                # plug (no graceful guest shutdown), matching the original
                # 'govc vm.power -off -force' behavior.
                $null = Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
                Write-Log "  VM '$($vm.Name)' powered off."
            }
            catch {
                Write-LogWarn "  Failed to power off VM '$($vm.Name)' ($vmId) — it may already be off or inaccessible: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds $Script:PoweroffWait
        }

        Write-Log "VM power-off sequence complete."
    }
    finally {
        if ($Script:VIConnection) {
            Disconnect-VIServer -Server $Script:VIConnection -Confirm:$false -ErrorAction SilentlyContinue
            $Script:VIConnection = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Main {
    Write-Log ""
    Write-Log "VCF Services Runtime Shutdown Script v$($Script:ScriptVersion)"
    Write-Log "Mode: $(if ($Script:DryRun) { 'DRY-RUN' } else { 'LIVE' })"
    Write-Log ""

    Test-Prerequisites
    Invoke-ApiLogin
    Test-NoSnapshots
    Stop-VcfSystem
    Stop-Vms

    Write-Log ""
    Write-Log "VCF Services Runtimes shutdown completed successfully."
}

try {
    Invoke-Main
    exit 0
}
catch {
    Write-LogError "Script exited unexpectedly: $($_.Exception.Message)"
    Write-LogError "Review the output above and consult the KB article for recovery steps."
    exit 1
}