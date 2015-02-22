<#
    .Synopsis
        Check TFS repository for new commits. If found sync the changes into
        the current SMA environment

    .Parameter RepositoryName
        Name of the project in TFS, the variables for TFSServer, Collection, Branch and RunbookFolder
        must be created in RepositoryInformation variable set in SMA
#>
Workflow Invoke-TFSRepositorySync
{
    Param([Parameter(Mandatory=$true)][String] $RepositoryName)
    
    Write-Verbose -Message "Starting [$WorkflowCommandName]"
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    $CIVariables = Get-BatchAutomationVariable -Name @('RepositoryInformation',
                                                       'SMACredName',
                                                       'WebserviceEndpoint'
                                                       'WebservicePort') `
                                               -Prefix 'SMAContinuousIntegration'
    $SMACred = Get-AutomationPSCredential -Name $CIVariables.SMACredName
    Try
    {
        $RepositoryInformation = (ConvertFrom-Json -InputObject $CIVariables.RepositoryInformation)."$RepositoryName"
        
		Write-Verbose -Message "`$RepositoryInformation [$(ConvertTo-JSON $RepositoryInformation)]"
		
		# Pass in Json version of RepositoryInformation 
        $TFSChange = ConvertFrom-JSON -InputObject (Find-TFSChange -RepositoryInformationJSON (ConvertTo-JSON -InputObject $RepositoryInformation -Compress) )
        
        Write-Debug -Message "Invoke-TFSRepositorySync: Return from Find-TFSChange with number of updates to process: $($TFSChange.NumberOfItemsUpdated)"
		
        if($TFSChange.NumberOfItemsUpdated -gt 0)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentChangesetID)..$($TFSChange.LatestChangesetId)]"
            
			$ReturnInformation = ConvertFrom-JSON (Group-RepositoryFile -Files $TFSChange.Files -RepositoryInformation $RepositoryInformation)
            
			# Priority over deletes. Sorts .ps1 files before .json files
            Foreach($RunbookFilePath in $ReturnInformation.ScriptFiles)
            {
                Write-Verbose -Message "[$($RunbookFilePath)] Starting Processing"
				Write-Debug -Message "ChangesetID of file: $($TFSChange.LatestChangesetId)"
				$TagLine = "ChangesetID:$($TFSChange.LatestChangesetId)"
				Write-Debug -Message "All Runbook files: $($TFSChange.RunbookFiles)"
				$Runbooks = $TFSChange.RunbookFiles
				Write-Debug -Message "Runbook file name: $($File.FullPath)"
				$FileToUpdate = $RunbookFilePath
				
				# NOTE: SMACred must have access to read files in local git folder
				# NOTE: To make processing faster add logic to save reference list generated calling Import-VCSRunbooks each time
				InlineScript {
					#Import-Module -Name 'SMARunbooksImportSDK'
					Import-VCSRunbooks -wfToUpdateList $Using:FileToUpdate `
									   -wfAllList $Using:Runbooks -Tag $Using:TagLine `
									   -WebServiceEndpoint $Using:WebServiceEndpoint `
									   -Port $Using:Port `
									   -ErrorAction Continue
									   
				} -PSCredential $SMACred -PSRequiredModules 'SMARunbooksImportSDK' -PSError $inlError -ErrorAction Continue
				If($inlError) {
					Write-Exception -Stream Error -Exception $inlError
					# Suspend workflow if error is detected
					Write-Error -Message "There where errors importing Runbooks: $inlError" -ErrorAction Stop
					$inlError = $Null
				}
			}	
            Foreach($SettingsFilePath in $ReturnInformation.SettingsFiles)
            {
                Write-Verbose -Message "[$($SettingsFilePath)] Starting Processing"
                Publish-SMATFSSettingsFileChange -FilePath $SettingsFilePath `
                                              -CurrentChangesetID $TFSChange.LatestChangesetId `
                                              -RepositoryName $RepositoryName
                Write-Verbose -Message "[$($SettingsFilePath)] Finished Processing"
            }
            Checkpoint-Workflow

            if($ReturnInformation.CleanRunbooks)
            {
                Remove-SmaOrphanRunbook -RepositoryName $RepositoryName
            }
            if($ReturnInformation.CleanAssets)
            {
                Remove-SmaOrphanAsset -RepositoryName $RepositoryName
            }
            if($ReturnInformation.UpdatePSModules)
            {
                # Implement a mini version of discover all local modules
            }
			
            $UpdatedRepositoryInformation = Set-SmaRepositoryInformationCommitVersion -RepositoryInformation $CIVariables.RepositoryInformation `
                                                                                      -Path $Path `
                                                                                      -Commit $TFSChange.LatestChangesetId
            Set-smavariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
                            -Value $UpdatedRepositoryInformation `
                            -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                            -Port $CIVariables.WebservicePort `
                            -Credential $SMACred

            Write-Verbose -Message "Finished Processing [$($RepositoryInformation.CurrentChangesetID)..$($TFSChange.LatestChangesetId)]"
        }
        Else {
                Write-Verbose -Message "No updates found in TFS"
        }
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "Finished [$WorkflowCommandName]"
}