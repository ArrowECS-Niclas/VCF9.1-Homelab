# Start up and shut down a VMware VCF 9.1 homelab

`Full-VCF-9-1-Start-Shutdown.ps1` uses PowerCLI to start or shut down a VMware Cloud Foundation (VCF) 9.1 management domain. It manages the vSAN cluster and configured management VMs. Optional Homey Pro integration switches power to devices such as ESXi hosts and network switches.

The script was written for a three-host Minisforum MS-A2 homelab with a UniFi XG16 switch and Homey Pro. The script follows the Broadcom management domain startup and shutdown procedures. [Startup procedure](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/sddc-startup/start-the-management-domain.html) · [Shutdown procedure](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html)

## Prerequisites

- PowerShell 7 or later and VMware PowerCLI. Install PowerCLI with `Install-Module VCF.PowerCLI`.
- A reachable vCenter for PowerCLI operations, credentials with permissions to manage the cluster and VMs, and VMware Tools in guests that need a graceful shutdown.
- For VCF shutdown, place `vcf_services_runtime_shutdown.ps1` beside the main script. The script needs a powered-on management services control node in the `vcf-management-services` VM folder with an IPv4 address reported through vCenter. [Companion script](https://github.com/WardVissers/VCF-Public/blob/main/vcf_services_runtime_shutdown.ps1)
- Shut down workload domains and unrelated VMs before running the VCF shutdown. The shutdown wait uses an unscoped `Get-VM` query, so unrelated running VMs visible to the PowerCLI session can hold up the sequence.
- To use Homey Pro, create a personal API key with Devices permission in **Settings → API Keys**. For automatic startup after the plugs switch on, configure the hosts to boot when AC power returns and arrange for vCenter to become available automatically.

## Run the script

Create or edit `sample-variables.ps1` with the settings below. The script dot-sources this file, so use a configuration file you trust and keep it private if it contains passwords or an API token.

Both parameters are required. `-EnvConfigFile` takes the path to the PowerShell configuration file. `-Action` accepts `Startup` or `Shutdown` and selects which pair of configuration switches applies.

```powershell
./Full-VCF-9-1-Start-Shutdown.ps1 -EnvConfigFile ./sample-variables.ps1 -Action Startup
./Full-VCF-9-1-Start-Shutdown.ps1 -EnvConfigFile ./sample-variables.ps1 -Action Shutdown
```

## Configuration variables

### Action switches

Set each switch explicitly to `$true` or `$false`. For PowerCLI-only operation, set both Homey switches to `$false` and enable the VCF switch for the action you want.

| Variable | Action | What it enables |
| --- | --- | --- |
| `$PowerOnSmartplugs` | `Startup` | Turns on the configured Homey devices, then waits for vCenter to answer a ping. |
| `$StartUpVCF` | `Startup` | Connects to vCenter, starts vSAN, and powers on the management VMs. |
| `$ShutdownVCF` | `Shutdown` | Shuts down the management services runtime, requests guest shutdowns, and initiates vSAN cluster shutdown. |
| `$PowerOffSmartplugs` | `Shutdown` | Turns off the configured Homey devices once all listed ESXi hosts stop answering pings. |

### vCenter and management VMs

Use VM display names for appliance settings. PowerCLI name lookups accept wildcard patterns such as `edge01*`. Use narrow patterns so the script targets the intended VMs.

| Variable | Example | Purpose |
| --- | --- | --- |
| `$vcentersrv` | `vc01.vcf.lab` | vCenter FQDN. During shutdown, the script uses its first label (`vc01` in this example) to identify the vCenter VM by display name. |
| `$clustername` | `VCF-Mgmt-Cluster` | vCenter inventory name of the management vSAN cluster. |
| `$Username` | `administrator@vsphere.local` | Account used to connect to vCenter. |
| `$DefaultPassword` | `<vCenter password>` | Password for the vCenter account. The script reads it as a string and converts it to a PowerShell credential. |
| `$VMSP_PASSWORD` | `<break-glass password>` | Password for `vmware-system-user`, passed to the runtime shutdown companion script. |
| `$SDDCManager` | `sddcm01` | SDDC Manager VM. |
| `$NSXManagerNodes` | `nsx01*` | NSX Manager VMs. |
| `$NSXEdges` | `edge01*` | NSX Edge VMs targeted during startup. |
| `$NSXEdge` | `edge01*` | NSX Edge VMs targeted during shutdown. Set this and `$NSXEdges` to the same selector when using the supplied script. |
| `$VNANodes` | `vna01*` | VNA VMs. |
| `$VCFOperations` | `vcf01` | VCF Operations VM. |
| `$VCFManagementServices` | `vcf-msr01*` | Management services VMs to shut down and fallback targets for startup. |
| `$LicenseServer` | `vcf-lic01` | License Server VM. |
| `$CloudProxy` | `vcf-proxy01` | Cloud Proxy VM. |
| `$VCFOperationsforNetworks` | `vcf-vrni01` | VCF Operations for Networks VM. |
| `$VCFAutomation` | `vcf-asr01*` | VCF Automation VMs. |

### Homey Pro and physical hosts

| Variable | Example | Purpose |
| --- | --- | --- |
| `$HomeyIP` | `http://192.168.1.20` | Homey Pro base URL, including the scheme and without a trailing slash. |
| `$Token` | `<Homey API key>` | Personal API key sent as a bearer token. |
| `$HomeyDeviceNames` | `@("Smart Power Strip 1 - ESX01")` | Array of Homey device display names to switch on or off. Devices are processed in list order. |
| `$VCFHosts` | `@("esx01.vcf.lab", "esx02.vcf.lab", "esx03.vcf.lab")` | ESXi hostnames or IP addresses to ping before switching off the plugs. Include every host whose power the configured devices control. |

## Startup sequence

1. If enabled, turn on the Homey devices and wait for vCenter to answer a ping. If VCF startup is enabled, retry the vCenter API connection until it responds, then wait 60 seconds.
2. Start vSAN, wait for the cluster to report that it is powered on, and run a health check. The script allows up to 10 minutes for vSAN to power on.
3. Start the VMs in order. SDDC Manager → NSX Manager → NSX Edge and VNA → VCF Operations → VCF Management Services → License Server → Cloud Proxy → VCF Operations for Networks → VCF Automation.
4. Check VCF Operations in its `/admin` UI and bring the cluster online if required. Verify the health of VCF Management Services in its UI.

For VCF Management Services, the script treats powered-off VMs in the `vcf-management-services` folder with up to 8 vCPUs as control nodes and starts them before workers, which it identifies by more than 8 vCPUs. It then starts any remaining powered-off VMs matching `$VCFManagementServices`. For other components, it waits for VMware Tools where configured and continues after a Tools timeout. The vCenter ping and API retry loops have no timeout.

## Shutdown sequence

1. Connect to vCenter and run the companion script against the first IPv4 address found on a powered-on management services control node.
2. Request graceful guest shutdowns in order. VCF Automation → VCF Operations for Networks → Cloud Proxy → License Server → VCF Management Services VMs → VCF Operations → NSX Edge and VNA → NSX Manager → SDDC Manager.
3. Wait 90 seconds, then poll every 15 seconds until the visible VMs are powered off, excluding the vCenter VM and `vCLS-*` VMs. Initiate vSAN cluster shutdown. The VM wait has no timeout and continues as long as a VM remains active.
4. If Homey power-off is enabled, wait until all entries in `$VCFHosts` stop answering pings, then switch off the configured devices. The script uses loss of ping as its only host shutdown check. Verify each host is actually down before relying on this step, since a network outage or a blocked ping can also make a running host appear offline. If using the Homey power-off step by itself, shut down the VCF environment and hosts first.

## Changelog

- **31 August 2026** — Combined the separate startup and shutdown scripts into `Full-VCF-9-1-Start-Shutdown.ps1` and added the `-Action` parameter.
- **27 August 2026** — Initial release.

## Disclaimer

This script is provided “as is,” without warranty of any kind, express or implied. Use is at your own risk. The author assumes no responsibility or liability for errors, data loss, outages, configuration changes, security issues, or other damages resulting from use or misuse. Review the code before running it, use it only in a non-production environment, and ensure appropriate backups and recovery procedures are in place.
