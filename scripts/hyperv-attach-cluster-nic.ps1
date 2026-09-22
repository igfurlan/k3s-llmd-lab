<#
.SYNOPSIS
  Gives a Hyper-V VM a second network adapter on the cluster switch.

.DESCRIPTION
  Called by the Vagrantfile as an `after :up` / `after :reload` trigger — not
  normally by hand. It exists because Vagrant's Hyper-V provider manages exactly
  one adapter per VM and offers no way to ask for a second
  (plugins/providers/hyperv/action/configure.rb passes a single SwitchID).

  These boxes are generation 1, which cannot hot-add a network adapter, so a
  running VM is shut down, given the adapter, and started again. That costs one
  restart on the very first `vagrant up` and nothing afterwards: the script
  exits immediately once the adapter exists.

  The new adapter lands AFTER the Vagrant-managed one. That ordering is load
  bearing — Vagrant reads the guest's SSH address from adapter index 0
  (scripts/get_network_config.ps1), which must stay the DHCP one.

.PARAMETER VmName
  Hyper-V VM name, which the Vagrantfile keeps equal to the node's hostname.

.PARAMETER SwitchName
  The Internal switch created by scripts\hyperv-create-switch.ps1.

.PARAMETER AdapterName
  Name for the new adapter. Also how this script recognises its own work.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $VmName,
    [Parameter(Mandatory = $true)][string] $SwitchName,
    [string] $AdapterName = "cluster"
)

$ErrorActionPreference = "Stop"

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "No Hyper-V switch named '$SwitchName'. Run, elevated:`n" +
          "    powershell -ExecutionPolicy Bypass -File scripts\hyperv-create-switch.ps1"
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "No Hyper-V VM named '$VmName'."
}

if (Get-VMNetworkAdapter -VM $vm | Where-Object { $_.Name -eq $AdapterName }) {
    Write-Host "$VmName already has its '$AdapterName' adapter."
    exit 0
}

$wasRunning = $vm.State -eq "Running"

if ($wasRunning) {
    Write-Host "$VmName : generation $($vm.Generation) cannot hot-add a NIC — shutting down ..."
    # Graceful shutdown through the integration services. -Force only suppresses
    # the confirmation prompt; it does not pull the power.
    Stop-VM -VM $vm -Force
    # Fall back to a hard stop if the guest ignored the request. Nothing of
    # value has been written yet at this point in the build.
    $vm = Get-VM -Name $VmName
    if ($vm.State -ne "Off") {
        Write-Host "$VmName : did not shut down cleanly, turning it off."
        Stop-VM -VM $vm -TurnOff -Force
    }
}

Write-Host "$VmName : attaching '$AdapterName' to switch '$SwitchName' ..."
Add-VMNetworkAdapter -VMName $VmName -Name $AdapterName -SwitchName $SwitchName

if ($wasRunning) {
    Write-Host "$VmName : starting again ..."
    Start-VM -Name $VmName | Out-Null
}

Get-VMNetworkAdapter -VMName $VmName | Format-Table Name, SwitchName, MacAddress, Status -AutoSize
