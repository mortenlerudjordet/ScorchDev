<#
    .Synopsis
        Check GIT repository for new commits. If found sync the changes into
        the current SMA environment

    .Parameter RepositoryName
#>
Workflow Invoke-GitRepositorySync
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
        $RepositoryInformation = (ConvertFrom-Json $CIVariables.RepositoryInformation)."$RepositoryName"
        Write-Verbose -Message "`$RepositoryInformation [$(ConvertTo-JSON $RepositoryInformation)]"

        $RepoChangeJSON = Find-GitRepoChange -RepositoryInformationJSON (ConvertTo-JSON -InputObject $RepositoryInformation -Compress)
        # Get all workflows in current repo set
        $RepoAllWFsJSON = Get-GitRepoWFs -RepositoryInformationJSON (ConvertTo-JSON -InputObject $RepositoryInformation -Compress)
        
        $RepoChange = ConvertFrom-JSON -InputObject $RepoChangeJSON
        $RepoAllWFs = ConvertFrom-JSON -InputObject $RepoAllWFsJSON

        if($RepoChange.CurrentCommit -ne $RepositoryInformation.CurrentCommit)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentCommit)..$($RepoChange.CurrentCommit)]"
            
            $ProcessedWorkflows = @()
            $ProcessedSettingsFiles = @()
            $ProcessedPowerShellModules = @()
            
            $CleanupOrphanRunbooks = $False
            $CleanupOrphanAssets = $False

            # Only Process the file 1 time per set. Sort .ps1 files before .json files

            Foreach($File in ($RepoChange.Files | Sort-Object ChangeType |Sort-Object FileExtension -Descending))
            {
                Write-Verbose -Message "[$($File.FileName)] Starting Processing"
                # Process files in the runbooks folder
                if($File.FullPath -like "$($RepositoryInformation.Path)\$($RepositoryInformation.RunbookFolder)\*")
                {
                    Switch -CaseSensitive ($File.FileExtension)
                    {
                        '.ps1'
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
                                        $TagLine = "RepositoryName:$RepositoryName;CurrentCommit:$($RepoChange.CurrentCommit)"
                                        $RunbookPath = $File.FullPath
                                        # NOTE: SMACred must have access to read files in local git folder
                                        # NOTE: To make processing faster add logic to save reference list for Runbooks to SMA variable
                                        InlineScript {
                                            #Import-Module -Name 'SMARunbooksImportSDK'
											Import-VCSRunbooks -wfToUpdateList $Using:RunbookPath `
                                                               -wfAllList $Using:RepoAllWFs -Tag $Using:TagLine `
                                                               -WebServiceEndpoint $Using:WebServiceEndpoint -Port $Using:Port
                                                               
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
                        '.json'
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
                                                                      -CurrentCommit $RepoChange.CurrentCommit `
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
                        '.psd1'
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
                                        Publish-SmaPowerShellModule -ModuleDefinitionFilePath $File.FullName `
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
                                                                                      -Commit $RepoChange.CurrentCommit
            Set-SmaVariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
                            -Value $UpdatedRepositoryInformation `
                            -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                            -Port $CIVariables.WebservicePort `
                            -Credential $SMACred

            Write-Verbose -Message "Finished Processing [$($RepositoryInformation.CurrentCommit)..$($RepoChange.CurrentCommit)]"
        }
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "Finished [$WorkflowCommandName]"
}