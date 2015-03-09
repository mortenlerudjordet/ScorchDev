<#
    .Synopsis
        Tests a runbook worker to see if it is above or below the target memory
        threshold

    .Parameter RunbookWorker
        The runbook worker to test

    .Parameter MinimumPercentFreeMemory
        The minimum % Free memory before going to a 'unhealthy' state

    .Parameter AccessCred
        The pscredential to use when connecting to the runbook worker
#>

Workflow Test-SmaRunbookWorker
{
    Param([Parameter(Mandatory=$True) ][string]       $RunbookWorker,
          [Parameter(Mandatory=$False)][int]          $MinimumPercentFreeMemory = 5,
          [Parameter(Mandatory=$True) ][pscredential] $AccessCred)

    $SmaRunbookWorkerVars = Get-BatchAutomationVariable -Name @('MinimumPercentFreeMemory') `
                                                        -Prefix 'SmaRunbookWorker'

    InlineScript
    {
        $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Continue
        & {
            $null = $(
                $DebugPreference       = [System.Management.Automation.ActionPreference]$Using:DebugPreference
                $VerbosePreference     = [System.Management.Automation.ActionPreference]$Using:VerbosePreference
                $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

                $SmaRunbookWorkerVars = $Using:SmaRunbookWorkerVars

                $Win32OperatingSystem = Get-WmiObject -Class win32_OperatingSystem
                $CurrentPercentFreeMemory = [int](($Win32OperatingSystem.FreePhysicalMemory / $Win32OperatingSystem.TotalVisibleMemorySize) * 100)

                Write-Verbose "[$($Env:ComputerName)] % Free Memory [$($CurrentPercentFreeMemory)%]"
                if($CurrentPercentFreeMemory -le $SmaRunbookWorkerVars.$MinimumPercentFreeMemory)
                {
                    Write-Warning -Message "[$($Env:ComputerName)] is below free memory threshold of [$($SmaRunbookWorkerVars.MinimumPercentFreeMemory)%]"
                    $ReturnStatus = 'Unhealthy'
                }
                else
                {
                    Write-Verbose -Message "[$($Env:ComputerName)] is above free memory threshold of [$($SmaRunbookWorkerVars.MinimumPercentFreeMemory)%]"
                    $ReturnStatus = 'Healthy'
                }
            )
            Return $ReturnStatus
        }
    } -PSComputerName $RunbookWorker -PSCredential $AccessCred
}