<#
    .Synopsis
        Check TFS repository for new commits. If found sync the changes into
        the current SMA environment

    .Parameter ProjectName
        Name of the project in TFS, the variables for TFSServer, Collection, Branch and RunbookFolder
        must be created in RepositoryInformation variable set in SMA
#>
Workflow Invoke-TFSRepositorySync
{
    Param([Parameter(Mandatory=$true)][String] $ProjectName)
    
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
        $RepositoryInformation = (ConvertFrom-Json -InputObject $CIVariables.RepositoryInformation)."$ProjectName"
        
		Write-Verbose -Message "`$RepositoryInformation [$(ConvertTo-JSON $RepositoryInformation)]"
		
		# Pass in Json version of RepositoryInformation 
        $TFSChangeJSON = Find-TFSChange -RepositoryInformationJSON (ConvertTo-JSON -InputObject $RepositoryInformation -Compress)
        
        $TFSChange = ConvertFrom-JSON -InputObject $TFSChangeJSON 
        Write-Debug -Message "Invoke-TFSRepositorySync: Return from Find-TFSChange with number of updates to process: $($TFSChange.NumberOfItemsUpdated)"
		
        if($TFSChange.NumberOfItemsUpdated -gt 0)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentChangesetID)..$($TFSChange.LatestChangesetId)]"
            
            $ProcessedWorkflows = @()
            $ProcessedSettingsFiles = @()
            $ProcessedPowerShellModules = @()
            
            $CleanupOrphanRunbooks = $False
            $CleanupOrphanAssets = $False
            
            # Priority over deletes. Sorts .ps1 files before .json files
            Foreach($File in ($TFSChange.UpdatedFiles | Sort-Object -Property FileExtension -Descending))
            {
                Write-Verbose -Message "[$($File.FileName)] Starting Processing"
                # Process files in the runbooks folder
                Write-Debug -Message "Runbooks path: $($RepositoryInformation.Path)\$($RepositoryInformation.RunbookFolder)"
                if($File.FullPath -like "$($RepositoryInformation.Path)\$($RepositoryInformation.RunbookFolder)\*")
                {
                    Switch -CaseSensitive ($File.FileExtension)
                    {
                        'ps1'
                        {   
                            if($ProcessedWorkflows -notcontains $File.FileName)
                            {
                                $ProcessedWorkflows += $File.FileName
                                Switch -CaseSensitive ($File.FileExtension)
                                {
                                    "D"
                                    {
                                        $CleanupOrphanRunbooks = $True
                                    }
                                    Default
                                    {
                                        Write-Debug -Message "ChangesetID of file: $($File.ChangesetID)"
                                        $TagLine = "ChangesetID:$($File.ChangesetID)"
                                        Write-Debug -Message "All Runbook files: $($TFSChange.RunbookFiles)"
                                        $Runbooks = $TFSChange.RunbookFiles
										Write-Debug -Message "Runbook file name: $($File.FullPath)"
                                        $FileToUpdate = $File.FullPath
                                        
                                        # NOTE: SMACred must have access to read files in local git folder
                                        # NOTE: To make processing faster add logic to save referance list generated calling Import-VCSRunbooks each time
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
                                }
                            }
                            else
                            {
                                Write-Verbose -Message "Skipping [$(ConvertTo-Json $File)]. File already processed in changeset"
                            }
                        }
                        'json'
                        {
                            if($ProcessedSettingsFiles -notcontains $File.FileName)
                            {
                                $ProcessedSettingsFiles += $File.FileName
                                Switch -CaseSensitive ($File.FileExtension)
                                {
                                    "D"
                                    {
                                        $CleanupOrphanAssets = $true
                                    }
                                    Default
                                    {
                                        Publish-SMASettingsFileChange -FilePath $File.FullPath `
                                                                      -CurrentChangesetID $TFSChange.LatestChangesetId `
                                                                      -RepositoryName $RepositoryName
                                    }
                                }
                            }
                            else
                            {
                                Write-Verbose -Message "Skipping [$(ConvertTo-Json $File)]. File already processed in changeset"
                            }
                        }
                        default
                        {
                            Write-Verbose -Message "[$($File.FileName)] is not a supported file type for the runbooks folder (.json / .ps1). Skipping"
                        }
                    }
                }

                # Process files in the PowerShellModules folder
                elseif($File.FullPath -like "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)\*")
                {
                    Switch -CaseSensitive ($File.FileExtension)
                    {
                        'psd1'
                        {
                            if($ProcessedPowerShellModules -notcontains $File.FileName)
                            {
                                $ProcessedPowerShellModules += $File.FileName
                                Switch -CaseSensitive ($File.FileExtension)
                                {
                                    "D"
                                    {
                                        # Not implemented
                                    }
                                    Default
                                    {
                                    }
                                }
                            }
                            else
                            {
                                Write-Verbose -Message "Skipping [$(ConvertTo-Json $File)]. File already processed in changeset"
                            }
                        }
                        default
                        {
                            Write-Verbose -Message "[$($File.FileName)] is not a supported file type for the PowerShellModules folder (.psd1). Skipping"
                        }
                    }
                }
                Write-Verbose -Message "[$($File.FileName)] Finished Processing"
                Checkpoint-Workflow

            }

            if($CleanupOrphanRunbooks)
            {
                 Remove-SmaOrphanRunbook -RepositoryName $RepositoryName
            }
            if($CleanupOrphanAssets)
            {
                Remove-SmaOrphanAsset -RepositoryName $RepositoryName
            }
            
            $UpdatedRepositoryInformation = Set-SmaRepositoryInformationCommitVersion -RepositoryInformation $CIVariables.RepositoryInformation `
                                                                                      -Path $Path `
                                                                                      -Commit $TFSChange.LatestChangesetId
            Set-SmaVariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
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