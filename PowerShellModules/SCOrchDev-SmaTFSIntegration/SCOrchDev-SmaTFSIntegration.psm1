<#
    .Synopsis
        Looks for the tag workflow in a file and returns the next string
    
    .Parameter FilePath
        The path to the file to search
#>
Function Get-SmaWorkflowNameFromFile
{
    Param([Parameter(Mandatory=$true)][string] $FilePath)

    $DeclaredCommands = Find-DeclaredCommand -Path $FilePath
    Foreach($Command in $DeclaredCommands.Keys)
    {
        if($DeclaredCommands.$Command.Type -eq 'Workflow') 
        { 
            return $Command -as [string]
        }
    }
    $FileContent = Get-Content $FilePath
    Throw-Exception -Type 'WorkflowNameNotFound' `
                        -Message 'Could not find the workflow tag and corresponding workflow name' `
                        -Property @{ 'FileContent' = "$FileContent" }
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
    if($TagLine -match 'ChangeSetID:([^;]+);')
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
        $TagLine = "ChangeSetID:$($CurrentCommit);$($TagLine)"
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
                                          'NewVersion' = $NewVersion } `
                           -Compress)
}
<#
    .Synopsis
        Returns all variables in a JSON settings file

    .Parameter FilePath
        The path to the JSON file containing SMA settings
#>
Function Get-SmaGlobalFromFile
{
    Param([Parameter(Mandatory=$false)]
          [string] 
          $FilePath,
          [ValidateSet('Variables','Schedules','Connections','Credentials')]
          [Parameter(Mandatory=$false)]
          [string] 
          $GlobalType )

    $ReturnInformation = @{}
    try
    {
        $SettingsJSON = (Get-Content $FilePath) -as [string]
        $SettingsObject = ConvertFrom-Json -InputObject $SettingsJSON
        $SettingsHashTable = ConvertFrom-PSCustomObject $SettingsObject
        
        if(-not ($SettingsHashTable.ContainsKey($GlobalType)))
        {
            Throw-Exception -Type 'GlobalTypeNotFound' `
                            -Message 'Global Type not found in settings file.' `
                            -Property @{ 'FilePath' = $FilePath ;
                                         'GlobalType' = $GlobalType ;
                                         'SettingsJSON' = $SettingsJSON }
        }

        $GlobalTypeObject = $SettingsHashTable."$GlobalType"
        $GlobalTypeHashTable = ConvertFrom-PSCustomObject $GlobalTypeObject -ErrorAction SilentlyContinue

        if(-not $GlobalTypeHashTable)
        {
            Throw-Exception -Type 'SettingsNotFound' `
                            -Message 'Settings of specified type not found in file' `
                            -Property @{ 'FilePath' = $FilePath ;
                                         'GlobalType' = $GlobalType ;
                                         'SettingsJSON' = $SettingsJSON }
        }

        foreach($Key in $GlobalTypeHashTable.Keys)
        {
            $ReturnInformation.Add($key, $GlobalTypeHashTable."$Key") | Out-Null
        }
                
    }
    catch
    {
        Write-Exception -Exception $_ -Stream Warning
    }

    return (ConvertTo-JSON $ReturnInformation -Compress)
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

    return (ConvertTo-Json $_RepositoryInformation -Compress)
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
                                  -Recurse `
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
                 'Schedule' = @() ;
				 'Connection' = @();
                 'Credential' = @()
				}
    $AssetFiles = Get-ChildItem -Path $Path `
                                  -Filter '*.json' `
                                  -Recurse:$True `
                                  -File:$True `
								  -Exclude '*-automation.json'
    
    foreach($AssetFile in $AssetFiles)
    {
        $VariableJSON = Get-SmaGlobalFromFile -FilePath $AssetFile.FullName -GlobalType Variables
        $ScheduleJSON = Get-SmaGlobalFromFile -FilePath $AssetFile.FullName -GlobalType Schedules
		$ConnectionJSON = Get-SmaGlobalFromFile -FilePath $AssetFile.FullName -GlobalType Connections
        $CredentialJSON = Get-SmaGlobalFromFile -FilePath $AssetFile.FullName -GlobalType Credentials
        if($VariableJSON)
        {
            Foreach($VariableName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON $VariableJSON)).Keys)
            {
                $Assets.Variable += $VariableName
            }
        }
        if($ScheduleJSON)
        {
            Foreach($ScheduleName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON $ScheduleJSON)).Keys)
            {
                $Assets.Schedule += $ScheduleName
            }
        }
		if($CredentialJSON)
        {
            Foreach($CredentialName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON $CredentialJSON)).Keys)
            {
                $Assets.Credential += $CredentialName
            }
        }
        if($ConnectionJSON)
        {
            Foreach($CredentialName in (ConvertFrom-PSCustomObject(ConvertFrom-JSON $CredentialJSON)).Keys)
            {
                $Assets.Credential += $CredentialName
            }
        }
    }
    Return $Assets
}
<#
    .Synopsis 
        Groups all files that will be processed.
        # TODO put logic for import order here
    .Parameter Files
        The files to sort
    .Parameter RepositoryInformation
#>
Function Group-RepositoryFile
{
    Param([Parameter(Mandatory=$True)] $Files,
          [Parameter(Mandatory=$True)] $RepositoryInformation)
    Write-Verbose -Message "Starting [Group-RepositoryFile]"
    $_Files = ConvertTo-Hashtable -InputObject $Files -KeyName FileExtension
    $ReturnObj = @{ 'ScriptFiles' = @() ;
                    'SettingsFiles' = @() ;
                    'ModuleFiles' = @() ;
					'AutomationJSONFiles' = @() ;
					'IntegrationModuleFiles' = @() ;
                    'CleanRunbooks' = $False ;
                    'CleanAssets' = $False ;
                    'CleanModules' = $False ;
                    'ModulesUpdated' = $False }

    # Process PS1 Files
    try
    {
        $PowerShellScriptFiles = ConvertTo-HashTable $_Files.'.ps1' -KeyName 'FileName'
        Write-Verbose -Message "Found Powershell Files"
        foreach($ScriptName in $PowerShellScriptFiles.Keys)
        {
            if($SettingsFiles."$SettingsFileName".ChangeType -eq 'A')
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
    }
    catch
    {
        Write-Verbose -Message "No Powershell Files found"
    }
    try
    {
        # Process Settings Files
        $SettingsFiles = ConvertTo-HashTable $_Files.'.json' -KeyName 'FileName'
        Write-Verbose -Message "Found Settings Files"
        foreach($SettingsFileName in $SettingsFiles.Keys)
        {
            if($SettingsFiles."$SettingsFileName".ChangeType -eq 'A')
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
    }	
	# Process Settings Files again to find automation json files
    foreach($SettingsFileName in $SettingsFiles.Keys)
    {
        # Only process new json files
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
    catch
    {
        Write-Verbose -Message "No Settings Files found"
    }
try
    {
        $PSModuleFiles = ConvertTo-HashTable $_Files.'.psd1' -KeyName 'FileName'
        Write-Verbose -Message 'Found Powershell Module Files'
        foreach($PSModuleName in $PSModuleFiles.Keys)
        {
            if($PSModuleFiles."$PSModuleName".ChangeType -eq 'A')
            {
                foreach($Path in $PSModuleFiles."$PSModuleName".FullPath)
                {
                    if($Path -like "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)\*")
                    {
                        if( $ReturnObj.AutomationJSONFiles ) 
                        {
                            # TODO: Test that multiple automation files can be compared in one go
                            if( $ReturnObj.AutomationJSONFiles | Where-Object -FilterScript `
                                { 
                                    ($_.Split('\')[-1]).Replace('-automation.json', "") -eq ($Path.Split('\')[-1]).Replace('.psd1', "")
                                }
                            )
                                Write-Debug -Message "Module is an Integration Module with an Automation JSON file"
                                Write-Debug -Message "File: $($Path) will not be processed as a standard PSmodule"
                                $ReturnObj.ModulesUpdated = $True
                                $ReturnObj.IntegrationModuleFiles += $Path
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
            else
            {
                $ReturnObj.CleanModules = $True
            }
        }
    }
    catch
    {
        Write-Verbose -Message "No Powershell Module Files found"
    }
    Write-Verbose -Message "Finished [Group-RepositoryFile]"
    Return (ConvertTo-JSON $ReturnObj -Compress)
}
<#
    .Synopsis
        Groups a list of SmaRunbooks by the RepositoryName from the
        tag line
#>
Function Group-SmaRunbooksByRepository
{
    Param([Parameter(Mandatory=$True)] $InputObject)
    ConvertTo-Hashtable -InputObject $InputObject `
                        -KeyName 'Tags' `
                        -KeyFilterScript { 
                            Param($KeyName)
                            if($KeyName -match 'RepositoryName:([^;]+);')
                            {
                                $Matches[1]
                            }
                        }
}
<#
    .Synopsis
        Groups a list of SmaRunbooks by the RepositoryName from the
        tag line
#>
Function Group-SmaAssetsByRepository
{
    Param(
    [Parameter(Mandatory=$True)] $InputObject
    )
    ConvertTo-Hashtable -InputObject $InputObject `
                        -KeyName 'Description' `
                        -KeyFilterScript { 
                            Param($KeyName)
                            if($KeyName -match 'RepositoryName:([^;]+);')
                            {
                                $Matches[1]
                            }
                        }
}
<#
    .Synopsis
        Check the target TFS Branch for any updated files. 
    
    .Parameter RepositoryInformation
        JSON string containing repository information
#>
Function Find-TFSChange
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

		# Build the TFS Location (server and collection)
        
        $TFSServerCollection = $RepositoryInformation.RepositoryPath
        Write-Verbose -Message "Updating TFS Workspace $TFSServerCollection"

        $TFSRoot   = [System.String]::Empty
		# To keep code changes to minimum in rest of code CurrentCommit is used instead of LatestChangesetId
        $ReturnObj = @{
						'NumberOfItemsUpdated' = 0;
						'CurrentCommit' = 0;
                        'RunbookFiles' = @();
                        'Files' = @()
					}
		
        Try
        {
            # Load the necessary assemblies for interacting with TFS, VS Team Explorer or similar must be installed on SMA server for this to work
            $VClient  = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.VersionControl.Client")
            $TFClient = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")
    
            # Connect to TFS
            $regProjCollection     = [Microsoft.TeamFoundation.Client.RegisteredTfsConnections]::GetProjectCollection($TFSServerCollection)
            $tfsTeamProjCollection = [Microsoft.TeamFoundation.Client.TfsTeamProjectCollectionFactory]::GetTeamProjectCollection($regProjCollection)
            $vcs                   = $tfsTeamProjCollection.GetService([Type]"Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer")

            # Get the latest changeset ID from TFS
            
            $ReturnObj.CurrentCommit = [int]($vcs.GetLatestChangesetId())

            # Setting up your workspace and source path you are managing
            $vcsWorkspace = $vcs.GetWorkspace($RepositoryInformation.TFSSourcePath)

            # Update the local workspace
            $changes = $vcsWorkspace.Get()

            # If changes are found update runbooks in SMA
            If($changes.NumUpdated -gt 0)
            {
                Write-Verbose -Message "Changes Found, Processing"
                Write-Verbose -Message "Number of changes to process: $($changes.NumUpdated)"
                $allItems = $vcs.GetItems($RepositoryInformation.TFSSourcePath,
                                        [Microsoft.TeamFoundation.VersionControl.Client.VersionSpec]::Latest,
                                        [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::Full,
                                        [Microsoft.TeamFoundation.VersionControl.Client.DeletedState]::Any,
                                        [Microsoft.TeamFoundation.VersionControl.Client.ItemType]::File )
                $TFSRoot  = ($allItems.QueryPath).ToLower()
                Write-Debug -Message "TFS Item Count: $($allItems.Items.Count)"
				Write-Debug -Message "TFS Root Path: $($TFSRoot)"
                foreach($item in $allItems.Items)
                {
					$BranchFolder = ($item.ServerItem).ToLower()
					$BranchFolder = ($BranchFolder.Split('/'))[-2]
                    Write-Debug -Message "Processing item: $($item.ServerItem)"
					Write-Debug -Message "Processing Branchfolder: $($BranchFolder)"
                    Write-Debug -Message "Filtering non branch folders not containing name: $($RepositoryInformation.Branch)"
                    
                    If($BranchFolder -eq (($RepositoryInformation.Branch).ToLower()))
                    {
                        Write-Debug -Message  "Match found for branch folder: $($BranchFolder)"
                        # This is redundant as we only get files from TFS
                        If($item.ItemType -eq "File")
                        {
                            Write-Debug -Message  "Changeset ID: $($item.ChangesetID)"
                            $ServerItem  = $item.ServerItem
                            Write-Debug -Message "Processing item: $($ServerItem)"
                            $ServerPath = ((($ServerItem.ToLower()).Replace($TFSRoot.ToLower(), ($RepositoryInformation.TFSSourcePath).ToLower())).Replace('/','\'))
							Write-Debug -Message "Processing path: $($ServerPath)"
                            # Get file extension of item
                            $FileExtension = $ServerItem.Split('.')
                            $FileExtension = ($FileExtension[-1]).ToLower()
							
                            # Build list of all ps1 files in TFS folder filtered to include non deleted runbooks only
                            If( $FileExtension -eq "ps1" -and $ServerPath -like $RepositoryInformation.RunBookFolder -and $item.DeletionId -eq 0) {
                                # Create file list of all ps1 files in TFS folder Runbooks (filtered for branch)
                                $ReturnObj.RunbookFiles += $ServerPath
                            }
                            If( $item.ChangesetID -gt $RepositoryInformation.CurrentCommit)
                            {
                                $ReturnObj.Files
                                Write-Debug -Message  "Found item with higher changeset ID, old: $($RepositoryInformation.CurrentCommit) new: $($item.ChangesetID)"
								
								# check that the same file is not already added, if so keep the one with highest changesetID
                                If( $ReturnObj.Files | Where-Object -FilterScript {$_.FileName -eq $ServerPath.Split('\')[-1]} ) {
                                    $ReturnObj.Files | Where-Object -FilterScript {
                                        If($_.FileName -eq $ServerPath.Split('\')[-1]) {
                                          # Check which of the duplicate files have the highest changeset number, keep the highest one
                                          If( $_.ChangesetID -lt $item.ChangesetID) {
                                            Write-Debug -Message "Last duplicate file has the highest changeset number, updating to new value"
                                            $_.ChangesetID = $item.ChangesetID
                                          }
                                          Else {
                                            Write-Debug -Message "First duplicate file has the highest changeset number, keeping the value"
                                          }
                                          If($item.DeletionId -eq 0) {
                                            Write-Debug -Message "Last duplicate file has the highest changeset number, updating changetype value to new"
                                            $_.ChangeType = "A"
                                          }
                                          Else {
                                            Write-Debug -Message "Last duplicate file has the highest changeset number, updating changetype value to deleted"
                                            $_.ChangeType = "D"
                                          }
                                        }
                                        Else {
                                            Write-Debug -Message "No duplicate file found"
                                        }
                                    }
                                }
                                # Check that processed file is not deleted
                                ElseIf($item.DeletionId -eq 0) {
                                    $ReturnObj.NumberOfItemsUpdated += 1
                                    # ChangeType is set to A so can use same code as original (Git)
                                    $ReturnObj.Files += @{ 	
                                                                    'FullPath' 		= 	$ServerPath;
                                                                    'FileName' 		=	$ServerPath.Split('\')[-1];
                                                                    'FileExtension' = 	$FileExtension;
                                                                    'ChangesetID'	= 	$item.ChangesetID;
                                                                    'ChangeType'    =   "A"
                                                                }
                                }
                                # If deletionId is other than 0 we assume the file is deleted
                                Else {
                                     
                                     $ReturnObj.Files += @{ 	
                                            'FullPath' 		= 	$ServerPath;
                                            'FileName' 		=	$ServerPath.Split('\')[-1];
                                            'FileExtension' = 	$FileExtension;
                                            'ChangesetID'	= 	$ChangesetID;
                                            'ChangeType'    =   "D"
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Else {
                Write-Verbose -Message "No updates found in TFS"
            }
        }
        Catch {
                Write-Exception -Stream Error -Exception $_
        }
        Write-Verbose -Message "Number of files in TFS altered: $($ReturnObj.NumberOfItemsUpdated)"      
        # Use compress to handle higher content volume, in some instances errors are thrown when converting back from JSON
        Return (ConvertTo-Json -InputObject $ReturnObj -Compress)
}
Export-ModuleMember -Function * -Verbose:$false -Debug:$False