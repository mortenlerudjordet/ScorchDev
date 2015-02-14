<#
    .Synopsis
        Check TFS repository for new commits. If found sync the changes into
        the current SMA environment

    .Parameter CollectionName
#>
Workflow Invoke-TFSRepositorySync
{
    Param([Parameter(Mandatory=$true)][String] $CollectionName)
    
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
        $RepositoryInformation = (ConvertFrom-Json $CIVariables.RepositoryInformation)."$CollectionName"
        Write-Verbose -Message "`$RepositoryInformation [$(ConvertTo-JSON $RepositoryInformation)]"

        $TFSChangeJSON = Find-TFSChange -TFSserver $($RepositoryInformation.TFSserver) `
                                        -Collection $RepositoryInformation.Collection `
                                        -CurrentChangesetID $RepositoryInformation.CurrentChangesetID
										-Branch $RepositoryInformation.Branch
										-TFSSourcePath $RepositoryInformation.TFSSourcePath
										-RunBookFolder $RepositoryInformation.RunbookFolder
        
        $TFSChange = ConvertFrom-JSON -InputObject $TFSChangeJSON
        
		
        if($TFSChange.NumberOfItemsUpdated -gt 0)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentChangesetID)..$($TFSChange.ChangesetID)]"
            
            $ProcessedWorkflows = @()
            $ProcessedSettingsFiles = @()
            $ProcessedPowerShellModules = @()
            
            $CleanupOrphanRunbooks = $False
            $CleanupOrphanAssets = $False
            
            # Only Process the file 1 time per set. Sort by change type so Adds get
            # Priority over deletes. Sorts .ps1 files before .json files
            Foreach($File in ($TFSChange.UpdatedFiles | Sort-Object -Property FileExtension -Descending))
            {
                Write-Verbose -Message "[$($File.FileName)] Starting Processing"
                # Process files in the runbooks folder
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
                                        $TagLine = "ChangesetID:$($TFSChange.ChangesetID);"
                                        $Runbooks = $TFSChange.RunbookFiles
										$FileToUpdate = $File.FullPath
                                        # TODO : Better error handling
                                        # NOTE: SMACred must have access to read files in local git folder
                                        # NOTE: To make processing faster add logic to save referance list for Runbooks to SMA variabl
                                        InlineScript {
                                            Import-VCSRunbooks -wfToUpdateList $Using:FileToUpdate `
                                                               -wfAllList $Using:Runbooks -Tag $Using:TagLine `
                                                               -WebServiceEndpoint $Using:WebServiceEndpoint -Port $Using:Port
                                                               
                                        } -PSCredential $SMACred -PSRequiredModules "SMAContinuousIntegrationModule"
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
                                                                      -CurrentChangesetID $TFSChange.CurrentChangesetID `
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
                #Remove-OrphanRunbook
            }
            if($CleanupOrphanAssets)
            {
                #Remove-OrphanVariable
                #Remove-OrphanSchedule
            }
            
            $UpdatedRepositoryInformation = Set-SmaRepositoryInformationCommitVersion -RepositoryInformation $CIVariables.RepositoryInformation `
                                                                                      -Path $Path `
                                                                                      -Commit $TFSChange.CurrentChangesetID
            Set-SmaVariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
                            -Value $UpdatedRepositoryInformation `
                            -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                            -Port $CIVariables.WebservicePort `
                            -Credential $SMACred

            Write-Verbose -Message "Finished Processing [$($RepositoryInformation.CurrentChangesetID)..$($TFSChange.CurrentChangesetID)]"
        }
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "Finished [$WorkflowCommandName]"
}