<#
    .Synopsis
        Looks for the tag workflow in a file and returns the next string
    
    .Parameter FilePath
        The path to the file to search
#>
Function Get-SmaWorkflowNameFromFile
{
    Param([Parameter(Mandatory=$true)][string] $FilePath)

    $FileContent = Get-Content $FilePath
    if("$FileContent" -match '(?im)workflow\s+([^\s]+)')
    {
        return $Matches[1]
    }
    else
    {
        Throw-Exception -Type 'WorkflowNameNotFound' `
                        -Message 'Could not find the workflow tag and corresponding workflow name' `
                        -Property @{ 'FileContent' = "$FileContent" }
    }
}
<#
    .Synopsis
        Tags a current tag line and compares it to the passed
        commit and repository. If the commit is not the same
        update the tag line and return new version
    
    .Parameter TagLine
        The current tag string from an SMA runbook

    .Parameter CurrentCommit
        The current commit string

    .Parameter RepositoryName
        The name of the repository that is being processed
#>
Function New-SmaChangesetTagLine
{
    Param([Parameter(Mandatory=$false)][string] $TagLine,
          [Parameter(Mandatory=$true)][string]  $CurrentCommit,
          [Parameter(Mandatory=$true)][string]  $RepositoryName)

    $NewVersion = $False
    if($TagLine -match 'CurrentCommit:([^;]+);')
    {
        if($Matches[1] -ne $CurrentCommit)
        {
            $NewVersion = $True
            $TagLine = $TagLine.Replace($Matches[1],$CurrentCommit) 
        }
    }
    else
    {
        Write-Verbose -Message "[$TagLine] Did not have a current commit tag."
        $TagLine = "CurrentCommit:$($CurrentCommit);$($TagLine)"
        $NewVersion = $True
    }
    if($TagLine -match 'RepositoryName:([^;]+);')
    {
        if($Matches[1] -ne $RepositoryName)
        {
            $NewVersion = $True
            $TagLine = $TagLine.Replace($Matches[1],$RepositoryName) 
        }
    }
    else
    {
        Write-Verbose -Message "[$TagLine] Did not have a RepositoryName tag."
        $TagLine = "RepositoryName:$($RepositoryName);$($TagLine)"
        $NewVersion = $True
    }
    return (ConvertTo-JSON -InputObject @{'TagLine' = $TagLine ;
										  'NewVersion' = $NewVersion } -Compress)
}
<#
    .Synopsis
        Returns all variables in a JSON settings file

    .Parameter FilePath
        The path to the JSON file containing SMA settings
#>
Function Get-SmaVariablesFromFile
{
    Param([Parameter(Mandatory=$false)][string] $FilePath)

    $FileContent = Get-Content $FilePath
    $Variables = ConvertFrom-PSCustomObject ((ConvertFrom-Json ((Get-Content -Path $FilePath) -as [String])).Variables)

    if(Test-IsNullOrEmpty $Variables.Keys)
    {
        Write-Warning -Message "No variables root in folder"
    }

    return (ConvertTo-JSON -InputObject $Variables -Compress)
}
<#
    .Synopsis
        Returns all Schedules in a JSON settings file

    .Parameter FilePath
        The path to the JSON file containing SMA settings
#>
Function Get-SmaSchedulesFromFile
{
    Param([Parameter(Mandatory=$false)][string] $FilePath)

    $FileContent = Get-Content $FilePath
    $Variables = ConvertFrom-PSCustomObject ((ConvertFrom-Json ((Get-Content -Path $FilePath) -as [String])).Schedules)

    if(Test-IsNullOrEmpty $Variables.Keys)
    {
        Write-Warning -Message "No Schedules root in folder"
    }

    return (ConvertTo-JSON -InputObject $Variables -Compress)
}
<#
    .Synopsis
        Updates a Global RepositoryInformation string with the new commit version
        for the target repository

    .Parameter RepositoryInformation
        The JSON representation of a repository

    .Parameter RepositoryName
        The name of the repository to update

    .Paramter Commit
        The new commit to store
#>
Function Set-SmaRepositoryInformationCommitVersion
{
    Param([Parameter(Mandatory=$false)][string] $RepositoryInformation,
          [Parameter(Mandatory=$false)][string] $RepositoryName,
          [Parameter(Mandatory=$false)][string] $Commit)
    
    $_RepositoryInformation = (ConvertFrom-JSON $RepositoryInformation)
    $_RepositoryInformation."$RepositoryName".CurrentCommit = $Commit

    return (ConvertTo-Json -InputObject $_RepositoryInformation -Compress)
}
Function Get-GitRepositoryWorkflowName
{
    Param([Parameter(Mandatory=$false)][string] $Path)

    $RunbookNames = @()
    $RunbookFiles = Get-ChildItem -Path $Path `
                                  -Filter '*.ps1' `
                                  -Recurse `
                                  -File
    foreach($RunbookFile in $RunbookFiles)
    {
        $RunbookNames += Get-SmaWorkflowNameFromFile -FilePath $RunbookFile.FullName
    }
    $RunbookNames
}
Function Get-GitRepositoryVariableName
{
    Param([Parameter(Mandatory=$false)][string] $Path)

    $RunbookNames = @()
    $RunbookFiles = Get-ChildItem -Path $Path `
                                  -Filter '*.json' `
                                  -Recurse:$True `
                                  -File:$True `
								  -Exclude '*-automation.json'
    foreach($RunbookFile in $RunbookFiles)
    {
        $RunbookNames += Get-SmaWorkflowNameFromFile -FilePath $RunbookFile.FullName
    }
    Return $RunbookNames
}
Function Get-GitRepositoryAssetName
{
    Param([Parameter(Mandatory=$false)][string] $Path)

    $Assets = @{ 'Variable' = @() ;
                 'Schedule' = @() }
    $AssetFiles = Get-ChildItem -Path $Path `
                                  -Filter '*.json' `
                                  -Recurse:$True `
                                  -File:$True `
								  -Exclude '*-automation.json'
    
    foreach($AssetFile in $AssetFiles)
    {
        Foreach($VariableName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON (Get-SmaVariablesFromFile -FilePath $AssetFile.FullName))).Keys)
        {
            $Assets.Variable += $VariableName
        }
        Foreach($ScheduleName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON (Get-SmaSchedulesFromFile -FilePath $AssetFile.FullName))).Keys)
        {
            $Assets.Schedule += $ScheduleName
        }
    }
    Return $Assets
}
<#
    .Synopsis 
        Groups all files that will be processed.
        # TODO put logic for import order here
        # TODO Remove duplicates
    .Parameter Files
        The files to sort
    .Parameter RepositoryInformation
#>
Function Group-RepositoryFile
{
    Param([Parameter(Mandatory=$True)] $Files,
          [Parameter(Mandatory=$True)] $RepositoryInformation)

    $_Files = ConvertTo-Hashtable -InputObject $Files -KeyName FileExtension
    $ReturnObj = @{ 'ScriptFiles' = @() ;
                    'SettingsFiles' = @() ;
                    'ModuleFiles' = @() ;
					'AutomationJSONFiles' = @() ;
					'IntegrationModules' = @() ;
                    'CleanRunbooks' = $False ;
                    'CleanAssets' = $False ;
                    'ModulesUpdated' = $False }

    # Process PS1 Files
    $PowerShellScriptFiles = ConvertTo-HashTable $_Files.'.ps1' -KeyName 'FileName'
    foreach($ScriptName in $PowerShellScriptFiles.Keys)
    {
        if($PowerShellScriptFiles."$ScriptName".ChangeType -contains 'M' -or
           $PowerShellScriptFiles."$ScriptName".ChangeType -contains 'A')
        {
            foreach($Path in $PowerShellScriptFiles."$ScriptName".FullPath)
            {
                if($Path -like "$($RepositoryInformation.Path)\$($RepositoryInformation.RunbookFolder)\*")
                {
                    $ReturnObj.ScriptFiles += $Path
                    break
                }
            }            
        }
        else
        {
            $ReturnObj.CleanRunbooks = $True
        }
    }

    # Process Settings Files
    $SettingsFiles = ConvertTo-HashTable $_Files.'.json' -KeyName 'FileName'
    foreach($SettingsFileName in $SettingsFiles.Keys)
    {
        if($SettingsFiles."$SettingsFileName".ChangeType -contains 'M' -or
           $SettingsFiles."$SettingsFileName".ChangeType -contains 'A')
        {
            foreach($Path in $SettingsFiles."$SettingsFileName".FullPath)
            {
                if($Path -like "$($RepositoryInformation.Path)\$($RepositoryInformation.RunbookFolder)\*")
                {
                    $ReturnObj.CleanAssets = $True
                    $ReturnObj.SettingsFiles += $Path
                    break
                }
            }
        }
        else
        {
            $ReturnObj.CleanAssets = $True
        }
    }	
	# Process Settings Files again to find automation json files
    foreach($SettingsFileName in $SettingsFiles.Keys)
    {
        # Only process new json files
		if($SettingsFiles."$SettingsFileName".ChangeType -contains 'A')
        {
            foreach($Path in $SettingsFiles."$SettingsFileName".FullPath)
            {
                # Find Integration Module json files
				if($Path -like "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)\*")
                {
					if($Path.Split('\')[-1] -like "*-automation.json") 
					{
						Write-Debug -Message "Found automation json file: $($Path.Split('\')[-1])"
						$ReturnObj.AutomationJSONFiles += $Path
						break
					}
					else {
						Write-Debug -Message "No automation json file found"
					}
                }
            }
        }
    }
		
    $PSModuleFiles = ConvertTo-HashTable $_Files.'.psd1' -KeyName 'FileName'
    foreach($PSModuleName in $PSModuleFiles.Keys)
    {
        if($PSModuleFiles."$PSModuleName".ChangeType -contains 'M' -or
           $PSModuleFiles."$PSModuleName".ChangeType -contains 'A')
        {
            foreach($Path in $PSModuleFiles."$PSModuleName".FullPath)
            {
                if($Path -like "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)\*" )
				{
                    if( $ReturnObj.AutomationJSONFiles ) 
					{
						if( $ReturnObj.AutomationJSONFiles | Where-Object -FilterScript `
							{ 
								($_.Split('\')[-1]).Replace('-automation.json', "") -eq ($Path.Split('\')[-1]).Replace('.psd1', "")
							}
							Write-Debug -Message "Module is an Integration Module with an Automation JSON file"
							Write-Debug -Message "File: $($Path) will not be processed as a local PSmodule"
							$ReturnObj.IntegrationModules += $Path
							break
						)
						else 
						{
							Write-Debug -Message "Module is not an Integration Module with an Automation JSON file"
							$ReturnObj.ModulesUpdated = $True
							$ReturnObj.ModuleFiles += $Path
							break						
						}
					}
					else {
						$ReturnObj.ModulesUpdated = $True
						$ReturnObj.ModuleFiles += $Path
						break
					}
                }
            }
        }
        if($ReturnObj.UpdatePSModules) { break }
    }

    Return (ConvertTo-JSON -InputObject $ReturnObj -Compress)
}
Export-ModuleMember -Function * -Verbose:$false -Debug:$False