# Manage your VCF 9.1 Homelab using PowerCLI
Automates your VMware VCF 9.1 Management domain from PowerCLI scripts.
Powers on or shuts down a VCF 9.1 Management Domain homelab based on the official shutdown order:

https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html

Manages the VCF Managment Services cluster, all VCF related VMs, vSAN and vCenter server including power on/off the VCF host.
Also powers on/off hosts from the grid using [Homey Pro](https://homey.app/) smart power plugs.

Assumes any workload domain and any non-VCF related VMs in the Management domain are already shut down before running this script.

## Inception of the script(s)
My homelab consists of 3 Minisforum MS-A2 hosts, Unifi XG16 switch and home automation is done using [Homey Pro](https://homey.app/) in my house.
So the purpose of the script(s) is to combine powering on/off hosts and switches, and manage (start/stop) VCF services and VMs using powershell/powercli
in a clean way - graceful shutdowns.

# Changelog
31/08/2026
* Combined the start up- and shut down-script into a single script (Full-VCF-9-1-Start-Shutdown.ps1) and added an -Action parameter to define whether to Startup or Shutdown the VCF environment instead.
  
27/08/2026
* Initial release

# The scripts
## Full VCF 9.1 Start up script (Full-VCF-9-1-Start-up.ps1)
The script uses a configuration file (sample-variables.ps1) to choose what the script should do:

`$PowerOnSmartplugs      = $true or $false` # Power on smart plugs in Homey Pro

`$StartUpVCF             = $true or $false` # Startup all VCF services (assumes hosts and vCenter is available)

To perform a power on and or start up of VCF:

`./Full-VCF-9-1-Start-Up.ps1 -EnvConfigFile ./sample-variables.ps1`

## Full VCF 9.1 Shutdown script (Full-VCF-9-1-Shut-down.ps1)
The script uses a configuration file (sample-variables.ps1) to choose what the script should do:

`$ShutdownVCF            = $true or $false` # Shut down all VCF services

`$PowerOffSmartplugs     = $true or $false` # Power off smart plugs in Homey Pro (assumes VCF hosts have been shutdown)

If both variables are **$true** then Homey Pro will power on the hosts (the hosts are configured to automatically start when power is detected), vCenter will automatically start once the host has 
finished booting and all VCF services will then be started by the script.

To perform a power off and or shut down of VCF:

`./Full-VCF-9-1-Shut-down.ps1 -EnvConfigFile ./sample-variables.ps1`

Companion script (**REQUIRED** to be available and stored in the same folder)

https://github.com/WardVissers/VCF-Public/blob/main/vcf_services_runtime_shutdown.ps1

## Configuration file (sample-variables.ps1)
Contains displaynames of all VCF VMs, user account to connect to vCenter as well as password for vmware-system-user to shut down the VCF Management services kubernetes cluster correctly.
This is also where you define settings for your Homey Pro environment: IP adress and access token as well as the name of the devices you want to manage in the script.

```
# Choice of what to be executed in the main scripts
$PowerOnSmartplugs      = $true # Power on smart plugs in Homey Pro
$StartUpVCF             = $true # Startup all VCF services
$ShutdownVCF            = $true # Shut down all VCF services
$PowerOffSmartplugs     = $true # Power off smart plugs in Homey Pro

# VCF 9.1 variables (VM displaynames, except vCenter where FQDN should be used)
$vcentersrv               = "vc01.vcf.lab"
$clustername              = "VCF-Mgmt-Cluster"
$VCFAutomation            = "vcf-asr01*"
$VCFOperationsforNetworks = "vcf-vrni01"
$CloudProxy               = "vcf-proxy01"
$LicenseServer            = "vcf-lic01"
$VCFManagementServices    = "vcf-msr01*"
$VCFOperations            = "vcf01"
$NSXEdges                 = "edge01*" 
$VNANodes                 = "vna01*"
$NSXManagerNodes          = "nsx01a"
$SDDCManager              = "sddcm01"
$Username                 = "administrator@vsphere.local"
$DefaultPassword          = "VMware1!VMware1!"
$VMSP_PASSWORD            = "VMware1!VMware1!" # Breakglass password for vmware-system-user

# Physical VMware ESX 9.1 hosts
$VCFHosts = @(
    "esx01.vcf.lab",
    "esx02.vcf.lab",
    "esx03.vcf.lab"
)

# Homey Pro variables
#   - Replace <HOMEY_IP_ADDRESS> below with the IP address to your Homey Pro controller.    
#   - Create a Personal API Key in Homey Web App > Settings > API Keys
#  (give it at least "Devices" permission).
#   - Replace <YOUR_API_KEY> below with the key you created.
#   - Replace target device names to power on 
$HomeyIP = "<HOMEY_IP_ADDRESS>" 
$Token    = "<YOUR_API_KEY>"
# Device names you want to turn on
$HomeyDeviceNames = @(
    "Smart Power Strip 1 - ESX01",
    "Smart Power Strip 2 - ESX02",
    "Smart Power Strip 3 - ESX03",
    "Smart Power Strip 4 - Unifi US XG16"
)
```

# **Disclaimer**

This script is provided "as is", without warranty of any kind, express or implied. Use of this script is entirely at your own risk.

The author assumes **no responsibility or liability** for any errors, data loss, system outages, configuration changes, security issues, or other damages that may result from the use or misuse of this script.

Always review and understand the code before running it, use it only in a **non-production environment**. Ensure that appropriate backups and recovery procedures are in place before using the script.

By using this script, you acknowledge that you are solely responsible for any consequences resulting from its execution.
