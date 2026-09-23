<#
.SYNOPSIS
  Creates DNS A + PTR records for the LAB lab Kubernetes cluster in corp.example.

.DESCRIPTION
  Idempotent: records that already exist with the right value are skipped.
  Records that exist with a DIFFERENT value are reported and left alone unless
  -ReplaceExisting is given. Known conflicts it then fixes:
    - Borg A record 10.10.1.11 -> 10.10.1.23
    - PTR 10.10.1.11 "Borg.corp.example." + stray "Borg." -> bastion.corp.example

  Needs the DnsServer PowerShell module (RSAT DNS tools, present on the DCs) and
  rights to edit the zone (DnsAdmins / Domain Admins). Run from an elevated prompt.

.EXAMPLE
  .\Add-K8sDnsRecords.ps1 -WhatIf            # preview, changes nothing
  .\Add-K8sDnsRecords.ps1                    # create missing records
  .\Add-K8sDnsRecords.ps1 -ReplaceExisting   # also fix records that point elsewhere
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DnsServer   = 'dc01.corp.example',
    [string]$ZoneName    = 'corp.example',
    [string]$ReverseZone = '1.10.10.in-addr.arpa',
    [switch]$ReplaceExisting
)

$ErrorActionPreference = 'Stop'
Import-Module DnsServer

# Name, IP, create PTR?   (Kubernetes cluster - LAB lab)
$Records = @(
    @{ Name = 'bastion';     IP = '10.10.1.11';   Ptr = $true  }   # Bastion / jump host
    @{ Name = 'bastion-nat'; IP = '203.0.113.10'; Ptr = $false }   # Bastion NAT IP (other subnet)
    @{ Name = 'etcd-1';      IP = '10.10.1.12';   Ptr = $true  }   # external etcd
    @{ Name = 'etcd-2';      IP = '10.10.1.13';   Ptr = $true  }
    @{ Name = 'etcd-3';      IP = '10.10.1.19';   Ptr = $true  }
    @{ Name = 'k8s-api';     IP = '10.10.1.20';   Ptr = $true  }   # control-plane VIP (kube-vip)
    @{ Name = 'manager';     IP = '10.10.1.14';   Ptr = $true  }   # control plane
    @{ Name = 'manager-2';   IP = '10.10.1.21';   Ptr = $true  }
    @{ Name = 'manager-3';   IP = '10.10.1.22';   Ptr = $true  }
    @{ Name = 'worker-a';    IP = '10.10.1.15';   Ptr = $true  }   # workers
    @{ Name = 'worker-b';    IP = '10.10.1.16';   Ptr = $true  }
    @{ Name = 'worker-c';    IP = '10.10.1.17';   Ptr = $true  }
    @{ Name = 'worker-d';    IP = '10.10.1.18';   Ptr = $true  }
    # Other lab hosts on 10.10.1.x
    @{ Name = 'Borg';            IP = '10.10.1.23'; Ptr = $true }   # moved off 10.10.1.11 (now bastion)
    @{ Name = 'docker-practice'; IP = '10.10.1.24'; Ptr = $true }   # Docker practice VM
)

$results = foreach ($r in $Records) {
    $fqdn = "$($r.Name).$ZoneName"

    # ---- A record ----
    $existing = @(Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ZoneName `
                    -Name $r.Name -RRType A -ErrorAction SilentlyContinue)
    $ips = $existing | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString }

    if ($ips -contains $r.IP -and $ips.Count -eq 1) {
        $aStatus = 'OK (exists)'
    } elseif ($ips.Count -gt 0 -and -not $ReplaceExisting) {
        $aStatus = "CONFLICT: points to $($ips -join ',') - use -ReplaceExisting"
    } elseif ($PSCmdlet.ShouldProcess($fqdn, "A -> $($r.IP)")) {
        $existing | ForEach-Object {
            Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ZoneName -InputObject $_ -Force
        }
        Add-DnsServerResourceRecordA -ComputerName $DnsServer -ZoneName $ZoneName -Name $r.Name -IPv4Address $r.IP
        $aStatus = if ($ips.Count) { "REPLACED (was $($ips -join ','))" } else { 'CREATED' }
    } else { $aStatus = if ($ips.Count) { "would REPLACE (was $($ips -join ','))" } else { 'would create' } }

    # ---- PTR record ----
    $ptrStatus = '-'
    if ($r.Ptr) {
        $octet = $r.IP.Split('.')[-1]
        $existingPtr = @(Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ReverseZone `
                           -Name $octet -RRType Ptr -ErrorAction SilentlyContinue)
        $targets = $existingPtr | ForEach-Object { $_.RecordData.PtrDomainName.TrimEnd('.') }

        if ($targets -contains $fqdn -and $targets.Count -eq 1) {
            $ptrStatus = 'OK (exists)'
        } elseif ($targets.Count -gt 0 -and -not $ReplaceExisting) {
            $ptrStatus = "CONFLICT: points to $($targets -join ',') - use -ReplaceExisting"
        } elseif ($PSCmdlet.ShouldProcess("$($r.IP)", "PTR -> $fqdn")) {
            $existingPtr | ForEach-Object {
                Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ReverseZone -InputObject $_ -Force
            }
            Add-DnsServerResourceRecordPtr -ComputerName $DnsServer -ZoneName $ReverseZone -Name $octet -PtrDomainName "$fqdn."
            $ptrStatus = if ($targets.Count) { "REPLACED (was $($targets -join ','))" } else { 'CREATED' }
        } else { $ptrStatus = if ($targets.Count) { "would REPLACE (was $($targets -join ','))" } else { 'would create' } }
    }

    [pscustomobject]@{ Name = $fqdn; IP = $r.IP; A = $aStatus; PTR = $ptrStatus }
}

$results | Format-Table -AutoSize -Wrap

if (-not $WhatIfPreference) {
    Write-Host "`nVerification (querying $DnsServer):"
    foreach ($r in $Records) {
        $fqdn = "$($r.Name).$ZoneName"
        $fwd = (Resolve-DnsName $fqdn -Server $DnsServer -Type A -DnsOnly -ErrorAction SilentlyContinue |
                Where-Object Type -eq 'A').IPAddress -join ','
        $rev = if ($r.Ptr) {
            (Resolve-DnsName $r.IP -Server $DnsServer -Type PTR -DnsOnly -ErrorAction SilentlyContinue).NameHost -join ','
        } else { '-' }
        '{0,-28} -> {1,-15}  reverse: {2}' -f $fqdn, $fwd, $rev
    }
}
