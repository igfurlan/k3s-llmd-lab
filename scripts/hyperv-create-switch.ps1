<#
.SYNOPSIS
  Creates the Internal Hyper-V switch the k3s nodes use to talk to each other.

.DESCRIPTION
  Run once per host, from an ELEVATED PowerShell, before the first `vagrant up`:

      powershell -ExecutionPolicy Bypass -File scripts\hyperv-create-switch.ps1

  It creates an Internal switch and gives the host's side of it a static
  address, so the host can reach the nodes at 192.168.58.11-13 (kubectl, curl,
  a browser pointed at the gateway).

  Internal, not External: an External switch would rebind the physical NIC and
  briefly drop the host's own network. Internal touches nothing that already
  exists. The nodes still reach the internet, over their other adapter on the
  Default Switch.

  There is no DHCP on an Internal switch - that is why the guests' addresses
  are set by a provisioner in the Vagrantfile rather than leased.

  Idempotent: safe to re-run, does nothing if the switch is already correct.

.NOTES
  To undo everything this script did:
      Remove-VMSwitch -Name k3s-lab -Force

  Keep this file ASCII-only. Windows PowerShell 5.1 reads a UTF-8 file with no
  BOM as Windows-1252, so a UTF-8 em dash decodes to a curly closing quote,
  which PowerShell accepts as a string delimiter - unbalancing every quote after
  it. Harmless inside a comment, fatal inside code.
#>

[CmdletBinding()]
param(
    [string] $SwitchName   = "k3s-lab",
    [string] $HostAddress  = "192.168.58.1",
    [int]    $PrefixLength = 24
)

$ErrorActionPreference = "Stop"

# Hyper-V's API refuses non-administrators, and the error it returns does not
# say so clearly once Vagrant has wrapped it.
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script needs an elevated PowerShell (Run as administrator)."
}

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch) {
    if ($switch.SwitchType -ne "Internal") {
        throw "A switch named '$SwitchName' already exists but is of type " +
              "$($switch.SwitchType). Remove it, or pick another name with -SwitchName."
    }
    Write-Host "Switch '$SwitchName' already exists."
} else {
    Write-Host "Creating Internal switch '$SwitchName' ..."
    $switch = New-VMSwitch -Name $SwitchName -SwitchType Internal
}

# Creating an Internal switch also creates a host network adapter for it.
$ifAlias = "vEthernet ($SwitchName)"

# Refuse to duplicate an address that already lives on another interface.
# VirtualBox's host-only adapter holds 192.168.56.1 on this host, which is why
# the lab moved to 192.168.58.0/24 - the same mistake in the other direction
# produces intermittent, hard-to-read unreachability.
$clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostAddress -and $_.InterfaceAlias -ne $ifAlias }
if ($clash) {
    throw "$HostAddress is already assigned to '$($clash.InterfaceAlias)'. " +
          "Pick a free subnet with -HostAddress, and update CLUSTER addresses in the Vagrantfile to match."
}

$existing = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostAddress }

if ($existing) {
    Write-Host "Host address $HostAddress/$PrefixLength already set on '$ifAlias'."
} else {
    Write-Host "Assigning $HostAddress/$PrefixLength to '$ifAlias' ..."
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostAddress -PrefixLength $PrefixLength | Out-Null
}

Write-Host ""
Write-Host "Ready:"
Get-VMSwitch -Name $SwitchName | Format-Table Name, SwitchType, Id -AutoSize
Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 |
    Format-Table IPAddress, PrefixLength, InterfaceAlias -AutoSize
