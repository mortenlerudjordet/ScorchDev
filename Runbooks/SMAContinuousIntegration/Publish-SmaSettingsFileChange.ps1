<#
    .Synopsis
        Takes a json file and publishes all schedules and variables from it into SMA
    
    .Parameter FilePath
        The path to the settings file to process

    .Parameter CurrentCommit
        The current commit to tag the variables and schedules with

    .Parameter RepositoryName
        The Repository Name that will 'own' the variables and schedules
#>
Workflow Publish-SMASettingsFileChange
{
    Param( [Parameter(Mandatory=$True)][String] $FilePath,
           [Parameter(Mandatory=$True)][String] $CurrentCommit,
           [Parameter(Mandatory=$True)][String] $RepositoryName)
    
    Write-Verbose -Message "[$FilePath] Starting [$WorkflowCommandName]"
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    $CIVariables = Get-BatchAutomationVariable -Name @('SMACredName',
                                                       'WebserviceEndpoint'
                                                       'WebservicePort') `
                                               -Prefix 'SMAContinuousIntegration'
    $SMACred = Get-AutomationPSCredential -Name $CIVariables.SMACredName

    Try
    {
        $VariablesJSON = Get-SmaGlobalFromFile -FilePath $FilePath -GlobalType Variables
        $Variables = ConvertFrom-PSCustomObject -InputObject (ConvertFrom-Json -InputObject $VariablesJSON)
        foreach($VariableName in $Variables.Keys)
        {
            Try
            {
                Write-Verbose -Message "[$VariableName] Updating"
                $Variable = $Variables."$VariableName"
                $ErrorActionPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
                $SmaVariable = Get-SmaVariable -Name $VariableName `
                                               -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                               -Port $CIVariables.WebservicePort `
                                               -Credential $SMACred
                $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
                if(Test-IsNullOrEmpty -String $SmaVariable.VariableId.Guid)
                {
                    Write-Verbose -Message "[$($VariableName)] is a New Variable"
                    $VariableDescription = "$($Variable.Description)`n`r__RepositoryName:$($RepositoryName);CurrentCommit:$($CurrentCommit);__"
                    $NewVersion = $True
                }
                else
                {
                    Write-Verbose -Message "[$($VariableName)] is an existing Variable"
                    $TagUpdateJSON = New-SmaChangesetTagLine -TagLine $SmaVariable.Description`
                                                             -CurrentCommit $CurrentCommit `
                                                             -RepositoryName $RepositoryName
                    $TagUpdate = ConvertFrom-Json -InputObject $TagUpdateJSON
                    $VariableDescription = "$($TagUpdate.TagLine)"
                    $NewVersion = $TagUpdate.NewVersion
                }
                if($NewVersion)
                {
                    $SmaVariableParameters = @{
                        'Name' = $VariableName ;
                        'Value' = $Variable.Value ;
                        'Description' = $VariableDescription ;
                        'WebServiceEndpoint' = $CIVariables.WebserviceEndpoint ;
                        'Port' = $CIVariables.WebservicePort ;
                        'Credential' = $SMACred ;
                        'Force' = $True ;
                    }
                    if(ConvertTo-Boolean -InputString $Variable.isEncrypted)
                    {
                        $CreateEncryptedVariable = Set-SmaVariable @SmaVariableParameters `
                                                                   -Encrypted
                    }
                    else
                    {
                        $CreateEncryptedVariable = Set-SmaVariable @SmaVariableParameters
                    }
                }
                else
                {
                    Write-Verbose -Message "[$($VariableName)] Is not a new version. Skipping"
                }
                Write-Verbose -Message "[$($VariableName)] Finished Updating"
            }
            Catch
            {
                $Exception = New-Exception -Type 'VariablePublishFailure' `
                                           -Message 'Failed to publish a variable to SMA' `
                                           -Property @{
                    'ErrorMessage' = Convert-ExceptionToString $_ ;
                    'VariableName' = $VariableName ;
                }
                Write-Warning -Message $Exception -WarningAction Continue
            }
        }
        $SchedulesJSON = Get-SmaGlobalFromFile -FilePath $FilePath -GlobalType Schedules
        $Schedules = ConvertFrom-PSCustomObject -InputObject (ConvertFrom-Json -InputObject $SchedulesJSON)
        foreach($ScheduleName in $Schedules.Keys)
        {
            Write-Verbose -Message "[$ScheduleName] Updating"
            try
            {
                $Schedule = $Schedules."$ScheduleName"
                $ErrorActionPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
                $SmaSchedule = Get-SmaSchedule -Name $ScheduleName `
                                               -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                               -Port $CIVariables.WebservicePort `
                                               -Credential $SMACred
                $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
                if(Test-IsNullOrEmpty -String $SmaSchedule.ScheduleId.Guid)
                {
                    Write-Verbose -Message "[$($ScheduleName)] is a New Schedule"
                    $ScheduleDescription = "$($Schedule.Description)`n`r__RepositoryName:$($RepositoryName);CurrentCommit:$($CurrentCommit);__"
                    $NewVersion = $True
                }
                else
                {
                    Write-Verbose -Message "[$($ScheduleName)] is an existing Schedule"
                    $TagUpdateJSON = New-SmaChangesetTagLine -TagLine $SmaVariable.Description`
                                                         -CurrentCommit $CurrentCommit `
                                                         -RepositoryName $RepositoryName
                    $TagUpdate = ConvertFrom-Json -InputObject $TagUpdateJSON
                    $ScheduleDescription = "$($TagUpdate.TagLine)"
                    $NewVersion = $TagUpdate.NewVersion
                }
                if($NewVersion)
                {
                    $CreateSchedule = Set-SmaSchedule -Name $ScheduleName `
                                                      -Description $ScheduleDescription `
                                                      -ScheduleType DailySchedule `
                                                      -DayInterval $Schedule.DayInterval `
                                                      -StartTime $Schedule.NextRun `
                                                      -ExpiryTime $Schedule.ExpirationTime `
                                                      -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                      -Port $CIVariables.WebservicePort `
                                                      -Credential $SMACred

                    if(Test-IsNullOrEmpty -String $CreateSchedule)
                    {
                        Throw-Exception -Type 'ScheduleFailedToCreate' `
                                        -Message 'Failed to create the schedule' `
                                        -Property @{
                            'ScheduleName'     = $ScheduleName
                            'Description'      = $ScheduleDescription
                            'ScheduleType'     = 'DailySchedule'
                            'DayInterval'      = $Schedule.DayInterval
                            'StartTime'        = $Schedule.NextRun
                            'ExpiryTime'       = $Schedule.ExpirationTime
                            'WebServiceEndpoint' = $CIVariables.WebserviceEndpoint
                            'Port'             = $CIVariables.WebservicePort
                            'Credential'       = $SMACred.UserName
                        }
                    }
                    try
                    {
                        $Parameters   = ConvertFrom-PSCustomObject -InputObject $Schedule.Parameter `
                                                                   -MemberType NoteProperty `
                        $RunbookStart = Start-SmaRunbook -Name $Schedule.RunbookName `
                                                         -ScheduleName $ScheduleName `
                                                         -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                         -Port $CIVariables.WebservicePort `
                                                         -Parameters $Parameters `
                                                         -Credential $SMACred
                        if(Test-IsNullOrEmpty -String $RunbookStart)
                        {
                            Throw-Exception -Type 'ScheduleFailedToSet' `
                                            -Message 'Failed to set the schedule on the target runbook' `
                                            -Property @{
                                'ScheduleName' = $ScheduleName
                                'RunbookName' = $Schedule.RunbookName
                                'Parameters' = $(ConvertTo-Json -InputObject $Parameters)
                            }
                        }
                    }
                    catch
                    {
                        Remove-SmaSchedule -Name $ScheduleName `
                                           -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                           -Port $CIVariables.WebservicePort `
                                           -Credential $SMACred `
                                           -Force
                        Write-Exception -Exception $_ -Stream Warning
                    }
                }
            }
            catch
            {
                Write-Exception -Exception $_ -Stream Warning
            }
            Write-Verbose -Message "[$($ScheduleName)] Finished Updating"
        }
		
		$ConnectionsJSON = Get-SmaGlobalFromFile -FilePath $FilePath -GlobalType Connections
        $Connections = ConvertFrom-PSCustomObject -InputObject (ConvertFrom-Json -InputObject $ConnectionsJSON)
		# Get all connection types in SMA
		$SMAConnectionTypes = Get-SmaConnectionType -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
													 -Port $CIVariables.WebservicePort `
													 -Credential $SMACred | Select-Object -ExpandProperty Name
		
		
		foreach($ConnectionName in $Connections.Keys)
		{
			# Get connection types to create
			try 
			{
				$Connection = $Connections."$ConnectionName"
				# Check if Connection Type template exists in SMA
				if($SMAConnectionTypes -contains $Connection.ConnectionTypeName) 
				{
					# ConnectionType template is in SMA
					if( Get-SmaConnection -Name $ConnectionName -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
										  -Port $CIVariables.WebservicePort -Credential $SMACred -ErrorAction SilentlyContinue ) 
					{
						# Connection object already exist in SMA
						$FieldValues = ConvertFrom-PSCustomObject -InputObject $Connection
						foreach($FieldValue in $FieldValues.Keys) 
						{
							# Updating values of the connection object
							if($FieldValue -ne "ConnectionTypeName" -and $FieldValue -ne "Description")
							{
								Write-Debug -Message "Adding ConnectionName: $ConnectionName,ConnectionFieldName: $FieldValue and Value: $($FieldValues."$FieldValue")"
								Set-SmaConnectionFieldValue -ConnectionName $ConnectionName -ConnectionFieldName $FieldValue `
															-Value $FieldValues."$FieldValue" `
															-WebServiceEndpoint $CIVariables.WebserviceEndpoint `
															-Port $CIVariables.WebservicePort -Credential $SMACred -Force	
							}
						}
					}
					else 
					{
						# No Connection object exist in SMA, create new one

						$FieldValues = ConvertFrom-PSCustomObject -InputObject $Connection
						$ConnectionFieldValues = New-Object -TypeName psobject
						foreach($FieldValue in $FieldValues.Keys) 
						{
							# Create custom object to hold connection values
							if($FieldValue -ne "ConnectionTypeName" -and $FieldValue -ne "Description")
							{
								Add-Member -InputObject $ConnectionFieldValues `
										   -NotePropertyName $FieldValue -NotePropertyValue $FieldValues."$FieldValue"
								Write-Debug -Message "Adding PropertyName: $FieldValue and PropertyValue: $($FieldValues."$FieldValue")"
							}
						}
						# Covert to hash table for passing to New-SmaConnection
						$CFVhashtable = ConvertFrom-PSCustomObject -InputObject $ConnectionFieldValues
						New-SmaConnection -Name $ConnectionName -ConnectionTypeName $Connection.ConnectionTypeName `
										  -ConnectionFieldValues $CFVhashtable -Description $Connection.Description `
										  -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
										  -Port $CIVariables.WebservicePort -Credential $SMACred
					}
				}
				else 
				{
					# ConnectionType template is not in SMA
					Write-Verbose -Message "[$($Connection.ConnectionType.Value)] has not been imported in a Integration Module yet. Skipping"
				}
			}
			catch
			{
				Write-Exception $_ -Stream Warning
			}
			Write-Verbose -Message "[$($ConnectionName)] Finished Updating"
		}

        $CredentialsJSON = Get-SmaGlobalFromFile -FilePath $FilePath -GlobalType Credentials
        $Credentials = ConvertFrom-PSCustomObject -InputObject (ConvertFrom-Json -InputObject $CredentialsJSON)	
		foreach($CredentialName in $Credentials.Keys)
		{
            Write-Verbose -Message "[$CredentialName] Updating"
            $Credential = $Credentials."$CredentialName"
            $ErrorActionPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
            $SmaCredential = Get-SmaCredential -Name $CredentialName `
                                           -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                           -Port $CIVariables.WebservicePort `
                                           -Credential $SMACred
            $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
            if(Test-IsNullOrEmpty -String $SmaCredential)
                {
                    Write-Verbose -Message "[$($CredentialName)] is a New Credential"
                    $CredentialDescription = "$($Credential.Description)`n`r__RepositoryName:$($RepositoryName);CurrentCommit:$($CurrentCommit);__"
                    $NewVersion = $True
                }
                else
                {
                    Write-Verbose -Message "[$($CredentialName)] is an existing Credential"
                    $TagUpdateJSON = New-SmaChangesetTagLine -TagLine $SmaCredential.Description`
                                                             -CurrentCommit $CurrentCommit `
                                                             -RepositoryName $RepositoryName
                    $TagUpdate = ConvertFrom-Json -InputObject $TagUpdateJSON
                    $CredentialDescription = "$($TagUpdate.TagLine)"
                    $NewVersion = $TagUpdate.NewVersion
                }
            if($NewVersion)
            {
                [System.Security.SecureString]$pwd = ConvertTo-SecureString $Credential.Password -AsPlainText -Force
                $Credential = new-object -typename System.Management.Automation.PSCredential -argumentlist @($Credential.UserName, $pwd)
                Set-SMACredential -Name $CredentialName -Value $Credential `
                                  -Description $CredentialDescription ` 
                                  -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                  -Port $CIVariables.WebservicePort `
                                  -Credential $SMACred
            }
            else
            {
               Write-Verbose -Message "[$($CredentialName)] is not a new version. Skipping"
            }
            Write-Verbose -Message "[$($CredentialName)] Finished Updating"
		}
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "[$FilePath] Finished [$WorkflowCommandName]"
}