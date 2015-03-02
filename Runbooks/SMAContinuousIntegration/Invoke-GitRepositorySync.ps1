﻿<#
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
                    Update-GitRepository -RepositoryInformation $RepositoryInformation
                )
            }
        } -PSComputerName $RunbookWorker -PSCredential $SMACred

        $RepositoryChangeJSON = Find-GitRepositoryChange -RepositoryInformation $RepositoryInformation
        $RepositoryChange = ConvertFrom-JSON $RepositoryChangeJSON
        if("$($RepositoryChange.CurrentCommit)" -ne "$($RepositoryInformation.CurrentCommit)")
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentCommit)..$($RepositoryChange.CurrentCommit)]"
            Write-Verbose -Message "RepositoryChange [$RepositoryChangeJSON]"
            $ReturnInformationJSON = Group-RepositoryFile -Files $RepositoryChange.Files `
                                                          -RepositoryInformation $RepositoryInformation
            $ReturnInformation = ConvertFrom-JSON -InputObject $ReturnInformationJSON
            Write-Verbose -Message "ReturnInformation [$ReturnInformationJSON]"

            Foreach($RunbookFilePath in $ReturnInformation.ScriptFiles)
            {
                Write-Verbose -Message "[$($RunbookFilePath)] Starting Processing"
                $TagLine = "RepositoryName:$RepositoryName;CurrentCommit:$($RepoChange.CurrentCommit)"
				$RunbookFile = $File.FullPath
				$AllRunbooksFiles = $RepositoryChange.AllRunbookFiles
				# NOTE: SMACred must have access to read files in local git folder
				# NOTE: To make processing faster add logic to save reference list for Runbooks to SMA variable
				InlineScript {
					#Import-Module -Name 'SMARunbooksImportSDK'
					Import-VCSRunbooks -wfToUpdateList $Using:RunbookFile `
									   -wfAllList $Using:AllRunbooksFiles -Tag $Using:TagLine `
									   -WebServiceEndpoint $Using:WebServiceEndpoint -Port $Using:Port
									   
				} -PSCredential $SMACred -PSRequiredModules 'SMARunbooksImportSDK' -PSError $inlError -ErrorAction Continue
				If($inlError) {
					Write-Exception -Stream Error -Exception $inlError
					# Using ErrorAction stop will suspend Runbook on first call to write-error, this error will not be written to history log in SMA
					Write-Error -Message "There where errors importing Runbooks: $inlError" 
					$inlError = $Null
				}
                Write-Verbose -Message "[$($RunbookFilePath)] Finished Processing"

				Checkpoint-Workflow

            }
            Foreach($SettingsFilePath in $ReturnInformation.SettingsFiles)
            {
                Publish-SMASettingsFileChange -FilePath $SettingsFilePath `
                                              -CurrentCommit $RepositoryChange.CurrentCommit `
                                              -RepositoryName $RepositoryName
                Checkpoint-Workflow
            }
            foreach($Module in $ReturnInformation.ModuleFiles)
            {
                Update-LocalModuleMetadata -ModuleName $Module
                Checkpoint-Workflow
            }
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
            if($ReturnInformation.ModuleFiles)
            {
                $RepositoryModulePath = "$($RepositoryInformation.Path)\$($RepositoryInformation.PowerShellModuleFolder)"
                inlinescript
                {
                    Add-PSEnvironmentPathLocation -Path $Using:RepositoryModulePath
                } -PSComputerName $RunbookWorker -PSCredential $SMACred
                Checkpoint-Workflow
            }
            $UpdatedRepositoryInformation = (Set-SmaRepositoryInformationCommitVersion -RepositoryInformation $CIVariables.RepositoryInformation `
                                                                                      -RepositoryName $RepositoryName `
                                                                                      -Commit $RepositoryChange.CurrentCommit) -as [string]
            $VariableUpdate = Set-SmaVariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
                                              -Value $UpdatedRepositoryInformation `
                                              -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                              -Port $CIVariables.WebservicePort `
                                              -Credential $SMACred
            
            Write-Verbose -Message "Finished Processing [$($RepositoryInformation.CurrentCommit)..$($RepositoryChange.CurrentCommit)]"
        }
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "Finished [$WorkflowCommandName]"
}