﻿<#
    .Synopsis
        Check the target Git Repo / Branch for any updated files. 
        Ingores files in the root
    
    .Parameter RepositoryInformation
         JSON string containing repository information
#>
Function Find-GitRepositoryChange
{
	[CmdletBinding()]
	Param (
        [Parameter(ParameterSetName='RepositoryInformation',Mandatory=$true,HelpMessage='Please specify RepositoryInformation as an object')][Alias('Information','ri')]
        [ValidateNotNullOrEmpty()]
        [Object]$RepositoryInformation,
        [Parameter(ParameterSetName='RepositoryInformationJSON',Mandatory=$true,HelpMessage='Please specify RepositoryInformation as an JSON string')][Alias('InformationJSON','rij')]
        [ValidateNotNullOrEmpty()]
        [String]$RepositoryInformationJSON
	)
	# IF JSON is used convert to object
	If($RepositoryInformationJSON) {
		$RepositoryInformation = ConvertFrom-Json -InputObject $RepositoryInformationJSON
	} 
	
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    
    # Set current directory to the git repo location

    Set-Location $RepositoryInformation.Path
      
    $ReturnObj = @{ 'CurrentCommit' = $RepositoryInformation.CurrentCommit;
                    'Files' = @() }
    
    $NewCommit = (git rev-parse --short HEAD)
    $ModifiedFiles = git diff --name-status (Select-FirstValid -Value $RepositoryInformation.CurrentCommit, $null -FilterScript { $_ -ne -1 }) $NewCommit
    $ReturnObj = @{ 'CurrentCommit' = $NewCommit ; 'Files' = @() ; AllRunbookFiles = @()}
    Foreach($File in $ModifiedFiles)
    {
        if("$($File)" -Match '([a-zA-Z])\s+(.+\/([^\./]+(\..+)))$')
        {
            $ReturnObj.Files += @{ 'FullPath' = "$($RepositoryInformation.Path)\$($Matches[2].Replace('/','\'))" ;
                                   'FileName' = $Matches[3] ;
                                   'FileExtension' = $Matches[4].ToLower()
                                   'ChangeType' = $Matches[1] }
        }
    }
	
	# Assumption : Only workflows in the Runbooks folder matter for hindering nesting breakage in SMA
    $ReturnObj.AllRunbookFiles = Get-ChildItem -Path $RepositoryInformation.Path -Filter "*.ps1" -Recurse:$True -File:$True | 
    Where-Object -FilterScript {$_.Directory -match $RepositoryInformation.RunBookFolder} | 
    Select-Object -ExpandProperty FullName
    
    return (ConvertTo-Json $ReturnObj -Compress)
}
<#
    .Synopsis
        Updates a git repository to the latest version
    
    .Parameter RepositoryInformation
        The PSCustomObject containing repository information
#>
Function Update-GitRepository
{
    [CmdletBinding()]
	Param (
        [Parameter(ParameterSetName='RepositoryInformation',Mandatory=$true,HelpMessage='Please specify RepositoryInformation as an object')][Alias('Information','ri')]
        [ValidateNotNullOrEmpty()]
        [Object]$RepositoryInformation,
        [Parameter(ParameterSetName='RepositoryInformationJSON',Mandatory=$true,HelpMessage='Please specify RepositoryInformation as an JSON string')][Alias('InformationJSON','rij')]
        [ValidateNotNullOrEmpty()]
        [String]$RepositoryInformationJSON
	)
    
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    
    # Set current directory to the git repo location
    Set-Location $RepositoryInformation.Path
      
    if(-not ("$(git branch)" -match '\*\s(\w+)'))
    {
        Throw-Exception -Type 'GitTargetBranchNotFound' `
                        -Message 'git could not find any current branch' `
                        -Property @{ 'result' = $(git branch);
                                     'match'  = "$(git branch)" -match '\*\s(\w+)'}
    }
    if($Matches[1] -ne $RepositoryInformation.Branch)
    {
        Write-Verbose -Message "Setting current branch to [$($RepositoryInformation.Branch)]"
        try
        {
            git checkout $RepositoryInformation.Branch | Out-Null
        }
        catch
        {
            if($LASTEXITCODE -ne 0)
            {
                Write-Exception -Stream Error -Exception $_
            }
            else
            {
                Write-Exception -Stream Verbose -Exception $_
            }
        }
    }

    try
    {
        $initialization = git pull
    }
    catch
    {
        if($LASTEXITCODE -ne -1)
        {
            Write-Exception -Stream Error -Exception $_
        }
        else
        {
            Write-Exception -Stream Verbose -Exception $_
        }
    }
    $NewCommit = (git rev-parse --short HEAD)

    $ModifiedFiles = git diff --name-status (Select-FirstValid -Value $RepositoryInformation.CurrentCommit, $null -FilterScript { $_ -ne -1 }) $NewCommit
    $ReturnObj = @{ 'CurrentCommit' = $NewCommit ; 'Files' = @() }
	
    Foreach($File in $ModifiedFiles)
    {
        if("$($File)" -Match '([a-zA-Z])\s+(.+\/([^\./]+(\..+)))$')
        {
            $ReturnObj.Files += @{ 'FullPath' = "$($Path)\$($Matches[2].Replace('/','\'))";
                                   'FileName' = $Matches[3];
                                   'FileExtension' = $Matches[4].ToLower();
                                   'ChangeType' = $Matches[1] 
								}
        }
    }
    
    return (ConvertTo-Json -InputObject $ReturnObj -Compress)
}
Export-ModuleMember -Function * -Verbose:$false