<#
.SYNOPSIS
  vSphere VM Cost Showback Tool

.DESCRIPTION
  Enumerates all VMs and calculates their cost which is then added to each VMs notes field in vCenter.
  All VMs are then also output to a timestamped CSV file as well for trending reporting and history.
  This allows you to estimate your per workload/VM costs in a cloud-like manner even when you capitalize
  your infrastructure costs over a period of time. Even when you operationalize (lease) or a mix of both
  this tool should work as well assuming you can get all of your individual costs down to a monthly amount.

.PREREQUISITES
  Requires VMware PowerCLI to be installed on the host running the script. See: www.vmware.com/go/powercli

.PARAMETERS
  Requires a vCenter Credentials file "vCenter.cred" created using the VICredentialStoreItem tool.
  (eg. New-VICredentialStoreItem -host vcenter-host.domain.com -user username -password ****** -file)

.INPUTS
  Enter all costs in USD, monthly (eg. 3 year cost (divided by 36 months) is a typical use case)

  *Fixed costs
    These don't change based on VM configuration but need to be calculated
     based on some assumptions around maximum number of VMs per host.
    $fixedInfra - costs such as server hardware and support, and infrastructure
      software and support such as vSphere licensing, backup software, anti-virus
      divided by the total number of VMs your environment supports
      (eg. 60 max VMs per host estimated * 12 hosts total in infrastructure = 720)
      You also need to consider all of your network gear (firewalls, routers, etc.)
      here as well, again divided by total number of VMs in a per-month basis
    $fixedHosting - costs for colo facilities, power, cooling and internet services.
      You can also consider monitoring and/or managed services if needed in here too.

  *Software licensing costs
    These are also fixed costs, and need to rely on the same environment assumptions
     as the infrastructure and hosting costs above
    $fixedWin - cost of Windows Datacenter virtual host licensing rights
      (eg. per socket / 2) divided then by the total max. number of VMs
    $fixedRHEL - cost of Red Hat Enterprise subscription, one per host, then
      divided by the total max. number of VMs

  *Variable costs
    $varStoragePerGB - Hardware and support costs for primary storage, per GB per month.
      You may also want to include some assumptions around primary dedupe rate here too
    $varBackupPerGB - Hardware and support costs for backup storage, per GB per month.
      Again dedupe rates are usually important here.  Do not include backup software costs
      for products licensed by core (eg. Veeam) as those would be included above.  You
      can include them however if they are licensed by front-end or back-end capacity (eg. Commvault)
    $varCPUPerProc - This one typically requires some thought, but can basically be
      your sever host costs (hardware and support) per month, divided by the total cores of the
      infrastructure (eg. 12 hosts with 28 cores per host = total of 336 cores).  You
      then need to include an assumption of vCPU:pCPU ratio (eg. 4:1) as well.
    $varMemPerGB - This one is tricky too because you need to know how much you pay for the
      RAM in a host vs. total server cost (be sure to NOT include this memory cost in $varCPUPerProc too)

 .LIMITATIONS
  - Does not handle costing of operating system licensing other than Windows Server or Red Hat Enterprise.
  - This script will OVERWRITE anything already in the vCenter Notes field so BE VERY CAREFUL!
  - The script can handle the notes field having Veeam backup data in it already (the only use case)
    In this scenario it will append the Veeam data to the cost data ONLY when you run the cost script after
    your Veeam backups are completed.  If the VM doesnt have Veeam data it simply overwrites as usual.

 .USAGE
   Schedule nightly (or less frequently) using Windows Task Scheduler or similar.
   eg. C:\Windows\system32\WindowsPowerShell\v1.0\powershell.exe -PSConsoleFile "C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\vim.psc1" "& "C:\ScriptPath\vsphere-showback.ps1" >logfile.log

 .NOTES
    Version:        1.0
    Author:         Anthony Siano
    Creation Date:  17-FEB-2017
    Purpose/Change: Initial script development
#>

#----------------------------------------------------------[Declarations]----------------------------------------------------------
$fixedInfra=11.227
$fixedHosting=9.028
$fixedWin=9.028
$fixedRHEL=3.472
$varStoragePerGB=0.055
$varBackupPerGB=0.0334
$varCPUPerProc=2.108
$varMemPerGB=0.339

#-----------------------------------------------------------[Execution]------------------------------------------------------------
Add-PSSnapIn VMware.VimAutomation.Core
$creds = Get-VICredentialStoreItem -file "vCenter.cred"
Connect-VIServer -Server vcenter-host.domain.com -User $creds.User -Password $creds.Password
$CurrentDate = Get-Date
$CurrentDate = $CurrentDate.ToString('MM-dd-yyyy_hh-mm-ss')

$resultsarray = @()
$isRedHat=0
$isWindows=0

foreach($vm in Get-VM){
$resultsObject = new-object PSObject
Write-Output "VM Name: $vm"

#Determine fixed cost based on OS
if(Get-VMguest -VM $vm.Name | Where-Object {$_.OSFullName -like "Red*"}) {$isRedHat=1}
if(Get-VMguest -VM $vm.Name | Where-Object {$_.OSFullName -like "Windows Server*"}) {$isWindows=1}

#Determine total VM storage in GB
$vmStorage = [math]::Round(((get-vm -Name $vm.Name | Where-object{$_.PowerState -eq "PoweredOn" }).UsedSpaceGB | measure-Object -Sum).Sum)
$vmdata = Get-VM -Name $vm.Name
$vmMemory = $vmdata.MemoryGB
$vmProcs = $vmdata.NumCPU

#Calculate Costs
$costForInfra=$fixedInfra
$costForHosting=$fixedHosting
$costForOS=($fixedWin * $isWindows) + ($fixedRHEL * $isRedHat)
$costForStorage=$vmStorage * $varStoragePerGB
$costForBackup=$vmStorage * $varBackupPerGB
$costForMemory=$vmMemory * $varMemPerGB
$costForProcessor=$vmProcs * $varCPUPerProc
$totalCostMonthly=$costForInfra+$costForHosting+$costForOS+$costForStorage+$costForBackup+$costForMemory+$costForProcessor
$totalCostYearly=$totalCostMonthly * 12
Write-Output "  Fixed: $costForInfra + $costForHosting"
Write-Output "OS Flag: RedHat:$isRedHat, Windows:$isWindows - $costForOS"
Write-Output "Storage: $vmStorage GB total used - $costForStorage + $costForBackup"
Write-Output " Memory: $vmMemory GB total assigned - $costForMemory"
Write-Output "  vCPUs: $vmProcs total assigned - $costForProcessor"
Write-Output "Total Costs: $totalCostMonthly/mo OR $totalCostYearly/yr"

$resultsObject | add-member -membertype NoteProperty -name "VM" -Value $vm
$resultsObject | add-member -membertype NoteProperty -name "Infra" -Value $costForInfra
$resultsObject | add-member -membertype NoteProperty -name "Hosting" -Value $costForHosting
$resultsObject | add-member -membertype NoteProperty -name "OS" -Value $costForOS
$resultsObject | add-member -membertype NoteProperty -name "Storage" -Value $costForStorage
$resultsObject | add-member -membertype NoteProperty -name "Memory" -Value $costForMemory
$resultsObject | add-member -membertype NoteProperty -name "CPU" -Value $costForProcessor
$resultsObject | add-member -membertype NoteProperty -name "TotalMonthly" -Value $totalCostMonthly
$resultsObject | add-member -membertype NoteProperty -name "TotalYearly" -Value $totalCostYearly
$resultsarray += $resultsObject

#Build string for the vCenter notes field
$costStringForNote = [string]"{0:c2}" -f $totalCostYearly
$vmToNote = Get-VM -Name $vm.Name
$add_note = "Yearly VM Cost Estimate: $costStringForNote"
$new_note = ($add_note + "`n" + $vmToNote.Notes)

#Since Veeam resets the notes overnight and we want to keep that data, if there is an existing
#Veeam note we keep it and append to it.  If Veeam doesn't have a note OVERWRITE existing note
if($vmToNote.Notes -like "*Veeam*") {
    Write-Output "[NOTE] Found existing Veeam notes, appending them to cost note"
    get-vm $vm.Name | set-vm -Notes $new_note -Confirm:$false
}
else
{
     Write-Output "[NOTE] No Veeam data found in note, overwriting"
     get-vm $vm.Name | set-vm -Notes $add_note -Confirm:$false

}

#cleanup/reset variables
Write-Output "----------------------------------`n"
$isRedHat=0
$isWindows=0

}
$resultsarray| Export-csv vmcosts-$CurrentDate.csv
