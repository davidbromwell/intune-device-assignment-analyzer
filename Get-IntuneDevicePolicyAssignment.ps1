#requires -Version 5.1
<#
.SYNOPSIS Consolidates Intune policy and app assignments for one managed device.
.NOTES ScriptVersion 1.0.3. Read-only. Windows PowerShell 5.1. ASCII.
#>
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$DeviceName,[string]$OutputRoot=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneToolkitReports'))
Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot '..\Shared\IntuneToolkit.Common.psm1') -Force
Connect-ToolkitGraph -Scopes @('DeviceManagementManagedDevices.Read.All','DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','Group.Read.All','Directory.Read.All','User.Read.All')|Out-Null
$out=New-ToolkitFolder 'DeviceAssignmentAnalyzer' $OutputRoot;$safe=$DeviceName.Replace("'","''")
# Get-ToolkitCollection returns raw Hashtables (from JSON), including nested objects/arrays as
# Hashtables too. Under this script's Set-StrictMode -Version 2.0, dot-notation on a Hashtable
# throws PropertyNotFoundException even when the key exists, and this also breaks helper
# functions in the shared module (e.g. Resolve-ToolkitTarget) that expect ordinary parsed-JSON
# objects. ConvertTo-ToolkitObjectDeep below walks the ENTIRE object graph -- top level and every
# nested object/array -- and converts every Hashtable to a PSCustomObject, so normal dot notation
# is safe everywhere, including inside shared-module functions we call with these objects.
function ConvertTo-ToolkitObjectDeep{param($InputObject)
 if($null -eq $InputObject){return $null}
 if($InputObject -is [System.Collections.IDictionary]){
  $h=[ordered]@{}
  foreach($k in $InputObject.Keys){$h[$k]=ConvertTo-ToolkitObjectDeep $InputObject[$k]}
  return [pscustomobject]$h
 }
 if(($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])){
  $list=New-Object System.Collections.Generic.List[object]
  foreach($item in $InputObject){$list.Add((ConvertTo-ToolkitObjectDeep $item))}
  return ,$list.ToArray()
 }
 return $InputObject
}
function Get-ToolkitValue{param($InputObject,[string]$Name)if($null -eq $InputObject){return $null};if($InputObject.PSObject.Properties.Name -contains $Name){return $InputObject.$Name};return $null}
# Graph's deviceAndAppManagementAssignmentTarget has several subtypes (groupAssignmentTarget,
# exclusionGroupAssignmentTarget, allDevicesAssignmentTarget, allLicensedUsersAssignmentTarget,
# configurationManagerCollectionAssignmentTarget), and each JSON payload only includes the fields
# relevant to its own subtype -- omitting the rest entirely rather than sending them as null.
# Resolve-ToolkitTarget in the shared module reads several of these fields unconditionally, so
# backfill every optional field across all subtypes with its documented default before calling it.
function Repair-ToolkitAssignmentTarget{param($Target)
 if($null -eq $Target){return $Target}
 $defaults=@{'deviceAndAppManagementAssignmentFilterType'='none';'deviceAndAppManagementAssignmentFilterId'=$null;'groupId'=$null;'collectionId'=$null}
 foreach($name in $defaults.Keys){if(-not ($Target.PSObject.Properties.Name -contains $name)){$Target|Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] -Force}}
 return $Target
}
function Get-ToolkitCollectionSafe{param([string]$Uri)
 $items=New-Object System.Collections.Generic.List[object];$next=$Uri
 while($next){
  $resp=ConvertTo-ToolkitObjectDeep (Get-ToolkitCollection $next)
  if($null -eq $resp){break}
  if($resp.PSObject.Properties.Name -contains 'value'){
   foreach($it in @($resp.value)){$items.Add($it)}
   $next=Get-ToolkitValue $resp '@odata.nextLink'
  }else{
   foreach($it in @($resp)){$items.Add($it)}
   $next=$null
  }
 }
 return ,@($items.ToArray())
}
# Fetches a collection with assignments expanded inline ($expand=assignments), avoiding one Graph
# call per object. If a given endpoint rejects $expand (not all resource types support it), falls
# back to plain collection retrieval; Add-Rows then falls back further to per-object assignment
# calls only for the specific items that came back without an 'assignments' property.
function Get-ToolkitCollectionExpanded{param([string]$BaseUri)
 try{return Get-ToolkitCollectionSafe "$BaseUri`?`$expand=assignments"}
 catch{Write-Warning "`$expand=assignments not supported for $BaseUri, falling back to per-item assignment calls."; return Get-ToolkitCollectionSafe $BaseUri}
}
$devices=Get-ToolkitCollectionSafe "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$safe'"
if(!$devices){throw "No exact managed-device match was found for $DeviceName."}
$d=$devices|Sort-Object -Property @{Expression={$v=Get-ToolkitValue $_ 'lastSyncDateTime';if($v){[datetime]$v}else{[datetime]::MinValue}}} -Descending|Select-Object -First 1
$users=@();try{$users=Get-ToolkitCollectionSafe "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($d.id)/users"}catch{Write-Warning $_}
$ed=$null;try{$ed=ConvertTo-ToolkitObjectDeep (Invoke-ToolkitGraph "https://graph.microsoft.com/v1.0/devices(deviceId='$($d.azureADDeviceId)')?`$select=id,deviceId,displayName")}catch{Write-Warning $_}
$dg=@();if($ed){try{$dg=Get-ToolkitCollectionSafe "https://graph.microsoft.com/v1.0/devices/$($ed.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName"}catch{Write-Warning $_}}
$ug=@();foreach($u in $users){try{$ug+=Get-ToolkitCollectionSafe "https://graph.microsoft.com/v1.0/users/$($u.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName"}catch{Write-Warning $_}}
$dc=@($dg.id);$uc=@($ug.id);$cache=@{};foreach($g in @($dg+$ug)){$cache[[string]$g.id]=[string]$g.displayName};$rows=New-Object System.Collections.Generic.List[object]
function Add-Rows{param($Category,$Objects,$NameProperty,$UriTemplate)
 $all=@($Objects);$total=$all.Count;$i=0
 Write-Host "  $Category`: $total item(s) to check" -ForegroundColor DarkCyan
 foreach($o in $all){
  $i++
  $displayName=[string](Get-ToolkitValue $o $NameProperty)
  Write-Progress -Activity "Retrieving assignments: $Category" -Status "$i of $total - $displayName" -PercentComplete ([int](100*$i/[math]::Max($total,1)))
  $a=Get-ToolkitValue $o 'assignments'
  if($null -eq $a){
   try{$a=Get-ToolkitCollectionSafe ($UriTemplate -f $o.id)}catch{continue}
  }else{
   $a=@($a)
  }
  foreach($x in $a){$r=Resolve-ToolkitTarget (Repair-ToolkitAssignmentTarget $x.target) $cache;$m='No direct match identified';if($r.TargetType -eq 'All devices'){$m='All devices'}elseif($r.TargetType -eq 'All users' -and $users){$m='All users'}elseif($r.TargetType -eq 'Included group' -and $dc -contains $r.GroupId){$m='Device group membership'}elseif($r.TargetType -eq 'Included group' -and $uc -contains $r.GroupId){$m='Primary-user group membership'}elseif($r.TargetType -eq 'Excluded group' -and (($dc -contains $r.GroupId)-or($uc -contains $r.GroupId))){$m='Matching exclusion'};$intent=Get-ToolkitValue $x 'intent';if($null -eq $intent){$intent=''};$rows.Add([pscustomobject]@{Category=$Category;ObjectName=[string]$o.$NameProperty;ObjectId=$o.id;Intent=[string]$intent;TargetType=$r.TargetType;GroupName=$r.GroupName;GroupId=$r.GroupId;MatchBasis=$m;FilterType=$r.FilterType;FilterId=$r.FilterId;Notes='Inferred result. Review filters, exclusions, and user/device context.'})}
 }
 Write-Progress -Activity "Retrieving assignments: $Category" -Completed
}
Write-Host 'Retrieving assignments...' -ForegroundColor Cyan
Write-Host 'Fetching device configurations (assignments included inline)...' -ForegroundColor DarkCyan
$deviceConfigs=Get-ToolkitCollectionExpanded 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations'
Add-Rows 'Classic configuration / Update ring' $deviceConfigs 'displayName' 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/{0}/assignments'
Write-Host 'Fetching Settings Catalog / endpoint security policies (assignments included inline)...' -ForegroundColor DarkCyan
$configPolicies=Get-ToolkitCollectionExpanded 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'
Add-Rows 'Settings Catalog / Endpoint security' $configPolicies 'name' 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assignments'
Write-Host 'Fetching compliance policies (assignments included inline)...' -ForegroundColor DarkCyan
$compliancePolicies=Get-ToolkitCollectionExpanded 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
Add-Rows 'Compliance policy' $compliancePolicies 'displayName' 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/{0}/assignments'
Write-Host 'Fetching apps (assignments included inline where supported)...' -ForegroundColor DarkCyan
$mobileApps=Get-ToolkitCollectionExpanded 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
Add-Rows 'Application' $mobileApps 'displayName' 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}/assignments'
[pscustomobject]@{DeviceName=Get-ToolkitValue $d 'deviceName';IntuneDeviceId=Get-ToolkitValue $d 'id';EntraDeviceId=Get-ToolkitValue $d 'azureADDeviceId';OS=Get-ToolkitValue $d 'operatingSystem';OSVersion=Get-ToolkitValue $d 'osVersion';Compliance=Get-ToolkitValue $d 'complianceState';LastSync=Get-ToolkitValue $d 'lastSyncDateTime';PrimaryUsers=($users.userPrincipalName -join '; ')}|Export-Csv "$out\DeviceSummary.csv" -NoTypeInformation -Encoding ASCII
$dg|Select id,displayName|Export-Csv "$out\DeviceGroups.csv" -NoTypeInformation -Encoding ASCII;$ug|Select -Unique id,displayName|Export-Csv "$out\PrimaryUserGroups.csv" -NoTypeInformation -Encoding ASCII;$rows|Sort Category,ObjectName|Export-Csv "$out\Assignments.csv" -NoTypeInformation -Encoding ASCII
Write-Host "Analysis complete. Assignment rows: $($rows.Count)" -ForegroundColor Green;Write-Host "Output: $out"
