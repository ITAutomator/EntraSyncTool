#####
## To enable scrips, Run powershell 'as admin' then type
## Set-ExecutionPolicy Unrestricted
#####
# Transcript Open
$Transcript = [System.IO.Path]::GetTempFileName()               
Start-Transcript -path $Transcript | Out-Null
# Main function header - Put ITAutomator.psm1 in same folder as script
$scriptFullname = $PSCommandPath ; if (!($scriptFullname)) {$scriptFullname =$MyInvocation.InvocationName }
$scriptXML      = $scriptFullname.Substring(0, $scriptFullname.LastIndexOf('.'))+ ".xml"  ### replace .ps1 with .xml
$scriptCSV      = $scriptFullname.Substring(0, $scriptFullname.LastIndexOf('.'))+ ".csv"  ### replace .ps1 with .csv
$scriptDir      = Split-Path -Path $scriptFullname -Parent
$scriptName     = Split-Path -Path $scriptFullname -Leaf
$scriptBase     = $scriptName.Substring(0, $scriptName.LastIndexOf('.'))
$psm1="$($scriptDir)\ITAutomator.psm1";if ((Test-Path $psm1)) {Import-Module $psm1 -Force} else {write-output "Err 99: Couldn't find '$(Split-Path $psm1 -Leaf)'";Start-Sleep -Seconds 10;Exit(99)}
$psm1="$($scriptDir)\ITAutomator M365.psm1";if ((Test-Path $psm1)) {Import-Module $psm1 -Force} else {write-output "Err 99: Couldn't find '$(Split-Path $psm1 -Leaf)'";Start-Sleep -Seconds 10;Exit(99)}
if (!(Test-Path $scriptCSV))
{
    ######### Template
    "EmailsToExclude" | Add-Content $scriptCSV
    "myuser@contoso.com" | Add-Content $scriptCSV
    ######### 
	$ErrOut=201; Write-Host "Err $ErrOut : Couldn't find '$(Split-Path $scriptCSV -leaf)'. Template CSV created. Edit CSV and run again.";Pause; Exit($ErrOut)
}
# ----------Fill $entries with contents of file or something
$entries=@(import-csv $scriptCSV)
$entriescount = $entries.count
Write-Host "-----------------------------------------------------------------------------"
Write-Host ("$scriptName        Computer:$env:computername User:$env:username PSver:"+($PSVersionTable.PSVersion.Major))
Write-Host ""
Write-Host "This will sync AD acounts with Entra users, mostly for LDAP purposes."
Write-Host "This program considers Entra accounts to be the read-only source on which AD depends."
Write-Host "All changes will be made in AD only."
Write-Host ""
Write-Host "- Missing Entra users will be added to AD"
Write-Host "- Extra AD users will be deleted"
Write-Host "- Use the CSV to provide a list of users to exclude from this process"
Write-Host ""
Write-Host "CSV: $(Split-Path $scriptCSV -leaf) ($($entriescount) entries with emails to exclude)"
#$entries | Format-Table
Write-Host "-----------------------------------------------------------------------------"
PressEnterToContinue
if (-not (Get-Command Get-ADUser -ErrorAction ignore))
{
    Write-Host "ERR: Get-ADUser failed. Run this script on a machine that has AD Users and Groups.";Start-sleep  3; Return $false
}
$no_errors = $true
$error_txt = ""
$results = @()
#region modules
<#
(prereqs: as admin run these powershell commands)
Install-Module Microsoft.Graph.Authentication
Install-Module Microsoft.Graph.Identity.DirectoryManagement
Install-Module Microsoft.Graph.Users
#>
$modules=@()
$modules+="Microsoft.Graph.Users"
ForEach ($module in $modules)
{ 
    Write-Host "Loadmodule $($module)..." -NoNewline ; $lm_result=LoadModule $module -checkver $false; Write-Host $lm_result
    if ($lm_result.startswith("ERR")) {
        Write-Host "ERR: Load-Module $($module) failed. Suggestion: Open PowerShell $($PSVersionTable.PSVersion.Major) as admin and run: Install-Module $($module)";Start-sleep  3; Return $false
    }
}
#endregion modules
# Connect
$myscopes=@()
$myscopes+="User.ReadWrite.All"
$connected_ok = ConnectMgGraph $myscopes
if (-not ($connected_ok))
{
    Write-Host "Connection failed."
}
else
{ # Connected
    $mg_properties = @(
        'id'
        ,'UserPrincipalName'
        ,'DisplayName'
        ,'mail'
        ,'AccountEnabled'
        ,'userType'
    )

    ###### Retrieve Azure AD User list
    Write-Host "-------------------- Entra"
    $mgusers = Get-MGuser -All -Property $mg_properties
    Write-Host "User Count: $($mgusers.count) [All users]"
    $mgusers = $mgusers | Where-Object UserType -EQ Member
    Write-Host "User Count: $($mgusers.count) [UserType=Members (vs Guests)]"
    $mgusers = $mgusers | Where-Object AccountEnabled -eq $true
    Write-Host "User Count: $($mgusers.count) [AccountEnabled=True]"
    $mgusers = $mgusers | where-object Mail -ne $null
    Write-Host "User Count: $($mgusers.count) [Mail ne null]"
    $mgusers = $mgusers | where-object {$_.Mail -notin $entries.EmailsToExclude}
    Write-Host "User Count: $($mgusers.count) [Mail notin Entries.EmailsToExclude]"
    $mgusers = $mgusers | Sort-Object DisplayName | Select-Object DisplayName,Mail,@{Name = 'Account'; Expression = {($_.Mail -split "@")[0]}}

    ###### Get AD list
    Write-Host "-------------------- AD"
    $adusers = Get-ADUser -Filter * -Property SamAccountName,Mail
    Write-Host "User Count: $($adusers.count) [All users]"
    $adusers = $adusers | Where-Object Enabled -eq $true
    Write-Host "User Count: $($mgusers.count) [Enabled=True]"
    $adusers = $adusers | where-object Mail -ne $null
    Write-Host "User Count: $($adusers.count) [Mail ne null]"
    $adusers = $adusers | where-object {$_.Mail -notin $entries.EmailsToExclude}
    Write-Host "User Count: $($adusers.count) [Mail notin Entries.EmailsToExclude]"
    $adusers = $adusers | Sort-Object DisplayName | Select-Object @{Name = 'DisplayName'; Expression = {$_.Name}},Mail,@{Name = 'Account'; Expression = {$_.SamAccountName}}

    # Find users to add/del in AD
    Write-Host "--------------------"
    $entries=@()
    $entries += $mgusers | Where-Object { $_.Mail -notin $adusers.Mail } | Select-Object @{Name = 'Action'; Expression = {'Add'}},*
    $entries += $adusers | Where-Object { $_.Mail -notin $mgusers.Mail } | Select-Object @{Name = 'Action'; Expression = {'Del'}},*
    $entries | Format-Table 

    # Process
    $processed=0
    $choiceLoop=0
    $entriescount = $entries.count
    $i=0        
    foreach ($x in $entries)
    { # each entry
        $i++
        write-host "-----" $i of $entriescount $x
        if ($choiceLoop -ne 1)
        { # Process all not selected yet, Ask
            $choices = @("&Yes","Yes to &All","&No","No and E&xit") 
            $choiceLoop = AskforChoice -Message "Process entry $($i)?" -Choices $choices -DefaultChoice 1
        } # Process all not selected yet, Ask
        if (($choiceLoop -eq 0) -or ($choiceLoop -eq 1))
        { # Process
            $processed++
            #######
            ####### Start code for object $x
            #region Object X
            if ($x.Action -eq "Add")
            { # Add
                New-ADUser -SamAccountName $x.Account -Name $x.DisplayName -DisplayName $x.DisplayName -UserPrincipalName $x.Mail -EmailAddress $x.Mail -AccountPassword (ConvertTo-SecureString "DefaultPassword123!" -AsPlainText -Force) -Enabled $true
            } # Add
            else
            { # Del
                Remove-ADUser -Identity $x.Account -Confirm:$false
            } # Del
            Write-Host "[$($x.Action)]: $($x.DisplayName) <$($x.Mail)>"
            #endregion Object X
            ####### End code for object $x
            #######
        } # Process
        if ($choiceLoop -eq 2)
        {
            write-host ("Entry "+$i+" skipped.")
        }
        if ($choiceLoop -eq 3)
        {
            write-host "Aborting."
            break
        }
    } # each entry
    WriteText "------------------------------------------------------------------------------------"
    $message ="Done. " +$processed+" of "+$entriescount+" entries processed. Press [Enter] to exit."
    WriteText $message
    WriteText "------------------------------------------------------------------------------------"
	# Transcript Save
    Stop-Transcript | Out-Null
    $date = get-date -format "yyyy-MM-dd_HH-mm-ss"
    New-Item -Path (Join-Path (Split-Path $scriptFullname -Parent) ("\Logs")) -ItemType Directory -Force | Out-Null #Make Logs folder
    $TranscriptTarget = Join-Path (Split-Path $scriptFullname -Parent) ("Logs\"+[System.IO.Path]::GetFileNameWithoutExtension($scriptFullname)+"_"+$date+"_log.txt")
    If (Test-Path $TranscriptTarget) {Remove-Item $TranscriptTarget -Force}
    Move-Item $Transcript $TranscriptTarget -Force
    # Transcript Save
} # M365 Connected
PressEnterToContinue