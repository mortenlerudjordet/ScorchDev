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
    Param(
        [Parameter(Mandatory=$true)]
        [String] 
        $RepositoryName
    )
    
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
		
		$RunbookWorker = Get-SMARunbookWorker
		
		# Update the repository on all SMA Workers
        InlineScript
        {
            $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Continue
            & {
                $null = $(
                    $DebugPreference       = [System.Management.Automation.ActionPreference]::SilentlyContinue
                    $VerbosePreference     = [System.Management.Automation.ActionPreference]::SilentlyContinue
                    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
                    
                    $RepositoryInformation = $Using:RepositoryInformation
                    # TODO: This will not work find another way of doing this
                    #Find-TFSChange -RepositoryInformation $RepositoryInformation
                )
            }
        } -PSComputerName $RunbookWorker -PSCredential $SMACred
		
        
		# SMACred must have contribute access to TFS project to fetch new files
        $TFSChangeJSON = Find-TFSChange -RepositoryInformation $RepositoryInformation
        $TFSChange = ConvertTo-JSON -InputObject $TFSChangeJSON
        Write-Debug -Message "Invoke-TFSRepositorySync: Return from Find-TFSChange with number of updates to process: $($TFSChange.NumberOfItemsUpdated)"
		
        if($TFSChange.NumberOfItemsUpdated -gt 0)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentCommit)..$($TFSChange.CurrentCommit)]"
            Write-Verbose -Message "RepositoryChange [$($TFSChange.UpdatedFiles)]"
            
			$ReturnInformationJSON = Group-RepositoryFile -Files $TFSChange.Files -RepositoryInformation $RepositoryInformation
            $ReturnInformation = ConvertTo-JSON -InputObject $ReturnInformationJSON
            
            # Integration Modules with automation json file must be imported before assets are added to SMA
            Foreach($ModulePath in $ReturnInformation.ModuleFiles)
            {
                Try
                {
                    $PowerShellModuleInformation = Test-ModuleManifest -Path $ModulePath
                    $ModuleName = $PowerShellModuleInformation.Name -as [string]
                    $ModuleVersion = $PowerShellModuleInformation.Version -as [string]
                    $PowerShellModuleInformation = Import-SmaPowerShellModule -ModulePath $ModulePath `
                                                                              -WebserviceEndpoint $CIVariables.WebserviceEndpoint `
                                                                              -WebservicePort $CIVariables.WebservicePort `
                                                                              -Credential $SMACred
                }
                Catch
                {
                    $Exception = New-Exception -Type 'ImportSmaPowerShellModuleFailure' `
                                               -Message 'Failed to import a PowerShell module into Sma' `
                                               -Property @{
                        'ErrorMessage' = (Convert-ExceptionToString $_) ;
                        'ModulePath' = $ModulePath ;
                        'ModuleName' = $ModuleName ;
                        'ModuleVersion' = $ModuleVersion ;
                        'PowerShellModuleInformation' = "$(ConvertTo-JSON $PowerShellModuleInformation)" ;
                        'WebserviceEnpoint' = $CIVariables.WebserviceEndpoint ;
                        'Port' = $CIVariables.WebservicePort ;
                        'Credential' = $SMACred.UserName ;
                    }
                    Write-Warning -Message $Exception -WarningAction Continue
                }
                
                Checkpoint-Workflow
            }
            
            Foreach($SettingsFilePath in $ReturnInformation.SettingsFiles)
            {
                Publish-SMASettingsFileChange -FilePath $SettingsFilePath `
                                         -CurrentCommit $TFSChange.CurrentCommit `
                                         -RepositoryName $RepositoryName
                Checkpoint-Workflow
            }

            $Runbooks = $TFSChange.RunbookFiles
            $FileToUpdate = $TFSChange.UpdatedFiles
            
            # NOTE: SMACred must have access to read files in local TFS folder
            InlineScript {
                #Import-Module -Name 'SMARunbooksImportSDK'
                Import-VCSRunbooks -WFsToUpdate $Using:FileToUpdate `
                                   -wfAllList $Using:Runbooks `
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
            Checkpoint-Workflow

            if($ReturnInformation.CleanRunbooks)
            {
                Remove-SmaOrphanRunbook -RepositoryName $RepositoryName
                Checkpoint-Workflow
            }
            if($ReturnInformation.CleanAssets)
            {
                Remove-SmaOrphanAsset -RepositoryName $RepositoryName
                Checkpoint-Workflow
            }
            if($ReturnInformation.CleanModules)
            {
                Remove-SmaOrphanModule
                Checkpoint-Workflow
            }
            if($ReturnInformation.ModuleFiles)
            {
                Try
                {
                    Write-Verbose -Message 'Validating Module Path on Runbook Wokers'
                    $RepositoryModulePath = "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)"
                    inlinescript
                    {
                        Add-PSEnvironmentPathLocation -Path $Using:RepositoryModulePath
                    } -PSComputerName $RunbookWorker -PSCredential $SMACred
                    Write-Verbose -Message 'Finished Validating Module Path on Runbook Wokers'
                }
                Catch
                {
                    $Exception = New-Exception -Type 'PowerShellModulePathValidationError' `
                                               -Message 'Failed to set PSModulePath' `
                                               -Property @{
                        'ErrorMessage' = (Convert-ExceptionToString $_) ;
                        'RepositoryModulePath' = $RepositoryModulePath ;
                        'RunbookWorker' = $RunbookWorker ;
                    }
                    Write-Warning -Message $Exception -WarningAction Continue
                }
                
                Checkpoint-Workflow
            }
            $UpdatedRepositoryInformation = (Set-SmaRepositoryInformationCommitVersion -RepositoryInformation $CIVariables.RepositoryInformation `
                                                                                       -RepositoryName $RepositoryName `
                                                                                       -Commit $TFSChange.CurrentCommit) -as [string]
            Set-smavariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
                            -Value $UpdatedRepositoryInformation `
                            -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                            -Port $CIVariables.WebservicePort `
                            -Credential $SMACred

            Write-Verbose -Message "Finished Processing [$($RepositoryInformation.CurrentCommit)..$($TFSChange.CurrentCommit)]"
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