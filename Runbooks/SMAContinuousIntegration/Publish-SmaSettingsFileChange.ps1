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
        $Variables = ConvertFrom-PSCustomObject (ConvertFrom-JSON (Get-SmaVariablesFromFile -FilePath $FilePath))
        foreach($VariableName in $Variables.Keys)
        {
            Write-Verbose -Message "[$VariableName] Updating"
            $Variable = $Variables."$VariableName"
            $ErrorActionPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
            $SmaVariable = Get-SmaVariable -Name $VariableName `
                                           -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                           -Port $CIVariables.WebservicePort `
                                           -Credential $SMACred
            $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
            if(Test-IsNullOrEmpty $SmaVariable.VariableId.Guid)
            {
                Write-Verbose -Message "[$($VariableName)] is a New Variable"
                $VariableDescription = "$($Variable.Description)`n`r__RepositoryName:$($RepositoryName);CurrentCommit:$($CurrentCommit);__"
                $NewVersion = $True
            }
            else
            {
                Write-Verbose -Message "[$($VariableName)] is an existing Variable"
                $TagUpdate = ConvertFrom-JSON( New-SmaChangesetTagLine -TagLine $SmaVariable.Description`
                                                         -CurrentCommit $CurrentCommit `
                                                         -RepositoryName $RepositoryName )
                $VariableDescription = "$($TagUpdate.TagLine)"
                $NewVersion = $TagUpdate.NewVersion
            }
            if($NewVersion)
            {
                if(ConvertTo-Boolean $Variable.isEncrypted)
                {
                    $CreateEncryptedVariable = Set-SmaVariable -Name $VariableName `
													           -Value $Variable.Value `
														       -Description $VariableDescription `
                                                               -Encrypted `
														       -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                               -Port $CIVariables.WebservicePort `
                                                               -Credential $SMACred `
                                                               -Force
                }
                else
                {
                    $CreateNonEncryptedVariable = Set-SmaVariable -Name $VariableName `
													              -Value $Variable.Value `
														          -Description $VariableDescription `
														          -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                                  -Port $CIVariables.WebservicePort `
                                                                  -Credential $SMACred
                }
            }
            else
            {
                Write-Verbose -Message "[$($VariableName)] Is not a new version. Skipping"
            }
            Write-Verbose -Message "[$($VariableName)] Finished Updating"
        }

        $Schedules = ConvertFrom-PSCustomObject ( ConvertFrom-JSON (Get-SmaSchedulesFromFile -FilePath $FilePath) )
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
                if(Test-IsNullOrEmpty $SmaSchedule.ScheduleId.Guid)
                {
                    Write-Verbose -Message "[$($ScheduleName)] is a New Schedule"
                    $ScheduleDescription = "$($Schedule.Description)`n`r__RepositoryName:$($RepositoryName);CurrentCommit:$($CurrentCommit);__"
                    $NewVersion = $True
                }
                else
                {
                    Write-Verbose -Message "[$($ScheduleName)] is an existing Schedule"
                    $TagUpdate = ConvertFrom-JSON( New-SmaChangesetTagLine -TagLine $SmaVariable.Description`
                                                             -CurrentCommit $CurrentCommit `
                                                             -RepositoryName $RepositoryName )
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

                    if(Test-IsNullOrEmpty $CreateSchedule)
                    {
                        Throw-Exception -Type 'ScheduleFailedToCreate' `
                                        -Message 'Failed to create the schedule' `
                                        -Property @{ 'ScheduleName' = $ScheduleName ;
                                                     'Description' = $ScheduleDescription;
                                                     'ScheduleType' = 'DailySchedule' ;
                                                     'DayInterval' = $Schedule.DayInterval ;
                                                     'StartTime' = $Schedule.NextRun ;
                                                     'ExpiryTime' = $Schedule.ExpirationTime ;
                                                     'WebServiceEndpoint' = $CIVariables.WebserviceEndpoint ;
                                                     'Port' = $CIVariables.WebservicePort ;
                                                     'Credential' = $SMACred.UserName }
                    }
                    try
                    {
                        $Parameters   = ConvertFrom-PSCustomObject -InputObject $Schedule.Parameter `
                                                                   -MemberType NoteProperty `

                        $RunbookStart = Start-SmaRunbook -Name $schedule.RunbookName `
                                                         -ScheduleName $ScheduleName `
                                                         -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                                         -Port $CIVariables.WebservicePort `
                                                         -Parameters $Parameters `
                                                         -Credential $SMACred
                        if(Test-IsNullOrEmpty $RunbookStart)
                        {
                            Throw-Exception -Type 'ScheduleFailedToSet' `
                                            -Message 'Failed to set the schedule on the target runbook' `
                                            -Property @{ 'ScheduleName' = $ScheduleName ;
                                                         'RunbookName' = $Schedule.RunbookName ; 
                                                         'Parameters' = $(ConvertTo-Json $Parameters) }
                        }
                    }
                    catch
                    {
                        Remove-SmaSchedule -Name $ScheduleName `
                                           -WebServiceEndpoint $CIVariables.WebserviceEndpoint `
                                           -Port $CIVariables.WebservicePort `
                                           -Credential $SMACred `
                                           -Force
                        Write-Exception $_ -Stream Warning
                    }
                                                  
                }
            }
            catch
            {
                Write-Exception $_ -Stream Warning
            }
            Write-Verbose -Message "[$($ScheduleName)] Finished Updating"
        }
		
		$Connections = ConvertFrom-PSCustomObject ( ConvertFrom-JSON (Get-SmaGlobalFromFile -FilePath $FilePath -GlobalType "Connections") )
        # initial before moving to functions
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
				if($SMAConnectionTypes -contains $Connection.ConnectionType.Value) 
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
							if($FieldValue -ne "ConnectionType")
							{
								Write-Debug -Message "Adding ConnectionName: $ConnectionName,ConnectionFieldName: $FieldValue and Value: $($FieldValues."$FieldValue".Value)"
								Set-SmaConnectionFieldValue -ConnectionName $ConnectionName -ConnectionFieldName $FieldValue `
															-Value $FieldValues."$FieldValue".Value `
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
							if($FieldValue -ne "ConnectionType")
							{
								Add-Member -InputObject $ConnectionFieldValues `
										   -NotePropertyName $FieldValue -NotePropertyValue $FieldValues."$FieldValue".Value
								Write-Debug -Message "Adding PropertyName: $FieldValue and PropertyValue: $($FieldValues."$FieldValue".Value)"
							}
						}
						# Covert to hash table for passing to New-SmaConnection
						$CFVhashtable = ConvertFrom-PSCustomObject -InputObject $ConnectionFieldValues
						New-SmaConnection -Name $ConnectionName -ConnectionTypeName $Connection.ConnectionType.Value `
										  -ConnectionFieldValues $CFVhashtable
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
			
		}
    }
    Catch
    {
        Write-Exception -Stream Warning -Exception $_
    }
    Write-Verbose -Message "[$FilePath] Finished [$WorkflowCommandName]"
}