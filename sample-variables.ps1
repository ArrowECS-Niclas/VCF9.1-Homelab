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