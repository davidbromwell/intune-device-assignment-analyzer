#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
function Connect-ToolkitGraph {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][string[]]$Scopes)
 if(-not(Get-Module -ListAvailable Microsoft.Graph.Authentication)){throw "Install Microsoft.Graph.Authentication with Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"}
 Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
 Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
 Write-Host "Opening the interactive browser sign-in experience..." -ForegroundColor Cyan
 Write-Host "Select the account that has the required delegated permissions." -ForegroundColor Cyan
 Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome
 $c=Get-MgContext
 if(-not $c.Account){throw "Authentication did not return an account."}
 Write-Host ("Connected as: {0}" -f $c.Account) -ForegroundColor Green
 return $c
}
function Invoke-ToolkitGraph {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Uri,[ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method='GET',[object]$Body,[int]$MaxRetries=6)
 for($i=0;$i -le $MaxRetries;$i++){
  try{
   if($PSBoundParameters.ContainsKey('Body')){return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body ($Body|ConvertTo-Json -Depth 100 -Compress) -ContentType 'application/json'}
   return Invoke-MgGraphRequest -Uri $Uri -Method $Method
  }catch{
   if($i -ge $MaxRetries -or $_.Exception.Message -notmatch '429|503|504|temporar|Too Many'){throw}
   $delay=[Math]::Min([Math]::Pow(2,$i+1),60); Write-Warning "Graph request delayed. Retrying in $delay seconds."; Start-Sleep $delay
  }
 }
}
function Get-ToolkitCollection {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Uri)
 $all=New-Object System.Collections.Generic.List[object]; $next=$Uri
 while($next){$r=Invoke-ToolkitGraph -Uri $next; if($r.PSObject.Properties.Name -contains 'value'){foreach($x in @($r.value)){$all.Add($x)}}else{$all.Add($r)}; $next=$null; if($r.PSObject.Properties.Name -contains '@odata.nextLink'){$next=[string]$r.'@odata.nextLink'}}
 return $all.ToArray()
}
function New-ToolkitFolder {
 param([string]$Name,[string]$Root=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneToolkitReports'))
 $p=Join-Path $Root ("{0}-{1}" -f $Name,(Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item $p -ItemType Directory -Force|Out-Null; return $p
}
function Resolve-ToolkitTarget {
 param([object]$Target,[hashtable]$GroupCache)
 $t=[string]$Target.'@odata.type'; $gid=[string]$Target.groupId
 $type=switch -Regex($t){'allDevicesAssignmentTarget'{'All devices';break};'allLicensedUsersAssignmentTarget'{'All users';break};'exclusionGroupAssignmentTarget'{'Excluded group';break};'groupAssignmentTarget'{'Included group';break};default{$t}}
 $gname=''
 if($gid){if($GroupCache.ContainsKey($gid)){$gname=$GroupCache[$gid]}else{try{$g=Invoke-ToolkitGraph -Uri ("https://graph.microsoft.com/v1.0/groups/{0}?`$select=id,displayName" -f $gid);$gname=[string]$g.displayName;$GroupCache[$gid]=$gname}catch{$gname='[Unable to resolve]'}}}
 [pscustomobject]@{TargetType=$type;GroupId=$gid;GroupName=$gname;FilterType=[string]$Target.deviceAndAppManagementAssignmentFilterType;FilterId=[string]$Target.deviceAndAppManagementAssignmentFilterId}
}
Export-ModuleMember -Function *
