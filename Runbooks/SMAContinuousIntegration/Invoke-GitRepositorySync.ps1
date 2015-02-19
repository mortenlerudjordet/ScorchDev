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

        $RunbookWorker = Get-SmaRunbookWorkerDeployment -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                        -Port $CIVariables.WebservicePort `
                                                        -Credential $SMACred
        
        # Update the repository on all SMA Workers
        InlineScript
        {
            $RepositoryInformation = $Using:RepositoryInformation
            Update-GitRepository -RepositoryInformation $RepositoryInformation
        } -PSComputerName $RunbookWorker -PSCredential $SMACred

        $RepositoryChange = ConvertFrom-JSON ( Find-GitRepositoryChange -RepositoryInformation (ConvertTo-JSON -InputObject $RepositoryInformation -Compress) )
		$RepositoryAllWFs = ConvertFrom-JSON ( Get-GitRepositoryWFs -RepositoryInformationJSON (ConvertTo-JSON -InputObject $RepositoryInformation -Compress) )
		
        if($RepositoryChange.CurrentCommit -ne $RepositoryInformation.CurrentCommit)
        {
            Write-Verbose -Message "Processing [$($RepositoryInformation.CurrentCommit)..$($RepositoryInformation.CurrentCommit)]"
            
            $ReturnInformation = ConvertFrom-JSON (Group-RepositoryFile -Files $RepositoryChange.Files -RepositoryInformation $RepositoryInformation)
            Foreach($RunbookFilePath in $ReturnInformation.ScriptFiles)
            {
                Write-Verbose -Message "[$($RunbookFilePath)] Starting Processing"
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
                Write-Verbose -Message "[$($RunbookFilePath)] Finished Processing"
            }
            Foreach($SettingsFilePath in $ReturnInformation.SettingsFiles)
            {
                Write-Verbose -Message "[$($SettingsFilePath)] Starting Processing"
                Publish-SMASettingsFileChange -FilePath $SettingsFilePath `
                                              -CurrentCommit $RepositoryChange.CurrentCommit `
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
                                                                                      -RepositoryName $RepositoryName `
                                                                                      -Commit $RepositoryChange.CurrentCommit
            Set-SmaVariable -Name 'SMAContinuousIntegration-RepositoryInformation' `
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