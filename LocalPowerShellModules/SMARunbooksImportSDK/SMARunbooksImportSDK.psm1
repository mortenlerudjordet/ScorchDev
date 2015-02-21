Function Import-VCSRunbooks
{
<#
        .SYNOPSIS
            Update multiple runbooks and all dependencies in SMA when changed in source control
			Use New-EventLog -LogName 'Windows PowerShell' -Source 'Workflows'  to register source before running function for the first time
			
		.Parameter wfToUpdateList
			Path of Runbooks to update or import
		.Parameter wfAllList
			Full name path of all workflow ps1 files in source control or in a file folder
		.Parameter Tag
			Text to update Tags field of Runbok with
		.Parameter WebServiceEndpoint
			URL of SMA
		.Parameter Port
			Port of SMA 
			
		.Examples
			Import-VCSRunbooks -wfToUpdateList @("c:\source\folder\workflow1.ps1","c:\source\folder\workflow2.ps1") -wfAllList @("c:\source\folder\workflow1.ps1","c:\source\folder\workflow2.ps1", "c:\source\folder\workflow3.ps1","c:\source\folder\workflow4.ps1")
			-Tag "Changeset: 1111" -WebServiceEndpoint "https://localhost"  -Port "9090"
#>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,HelpMessage='String array of ps1 files updated in local source control mapping')]
        [ValidateNotNullOrEmpty()]
        [string[]]$wfToUpdateList,
        [Parameter(Mandatory=$true,HelpMessage='String array of all ps1 files in local source control mapping')]
        [ValidateNotNullOrEmpty()]
        [string[]]$wfAllList,
        [Parameter(Mandatory=$false,HelpMessage='Set Tag for Runbooks to be updated with')]
        [string]$Tag,
        [Parameter()]
		[string]$WebServiceEndpoint = "https://localhost",
        [Parameter()]
		[string]$Port = "9090"
    )
	# List of ps1 files that has been updated in source control, stop if error detected
	# if ErrorAction Stop is used
    $wfs = Get-Childitem -Path $wfToUpdateList -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
        # Dont run more code if error is detected, if ErrorAction Stop is used directly on function call SMA vil not record the error in the history tab
        # Write Error to powershell eventlog, use New-EventLog -LogName 'Windows PowerShell' -Source 'Workflows'  to register source before running
		#Write-EventLog -EventId 1 -LogName 'Windows PowerShell' -Source 'Workflows' -EntryType Error -Message "Function Import-VCSRunbooks: Error detected reading file from disk: $($oErr), Suspending execution"
        # If errorAction Stop is used in calling workflow execution will suspend executing next line
        Write-Error -Message "Error in Import-VCSRunbooks: $oErr"
        $oErr = $Null
		#Return
    } 

	
	Write-Debug -Message "Import-VCSRunbooks Files to process: $($wfs.BaseName)"
	Write-Debug -Message "Import-VCSRunbooks FullName of files to process: $($wfs.FullName)"
	# List of all ps1 files in source control
	Write-Debug -Message "Import-VCSRunbooks all Runbook files input: $($wfAllList)"
    
    If($wfs.GetType().isArray) {
        [System.Collections.ArrayList]$ToProcessList = ($wfs | Select-Object -Property FullName,BaseName)
    }
    Else {
        [System.Object]$ToProcessList = ($wfs | Select-Object -Property FullName,BaseName)
    }
    $Global:wfReferenceList = New-Object  -TypeName System.Collections.ArrayList
	$Global:DoneProcessList = New-Object  -TypeName System.Collections.ArrayList
	$Global:wfDependancyList = New-Object -TypeName System.Collections.ArrayList
	$AllwfDependancyList = New-Object     -TypeName System.Collections.ArrayList
    
    # Build reference tree for all workflows in soruce control
	Write-Debug -Message "Import-VCSRunbooks: Starting building reference list"
    foreach ($wf in $wfAllList)
    {
        $wfName = (($wf.Split('\')).Split('.')[-2])
        Write-Verbose -Message "Retrieving references for: $($wfName)"
        Write-Debug -Message "Import-VCSRunbooks: Calling Get-RunbookReferences with: $($wf) as input" 
        Get-RunbookReferences -Path $wf -BasePath $wfAllList -ErrorAction Continue -ErrorVariable oErr
        If($oErr) {
		    # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
            # Using Continue and ErrorVariable the Error is written in history tab
		    Write-Error -Message "Error in Import-VCSRunbooks: $oErr"
		    $oErr = $Null
		    #Return
	    }
        $wfName = $Null
    }
	# Build dependencies tree for updated workflows
	Write-Debug -Message "Import-VCSRunbooks: Starting building dependency list"
    foreach ($wf in $ToProcessList)
    {
			
		$RunbookDep = New-Object -TypeName PSObject -Property (@{
        'RunbookName' = "";
		'FullName' = "";
        'RunbookDependencies' = @()
		})
		$Global:wfDependancyList = $Null
        Write-Debug -Message "Import-VCSRunbooks: wfDependancyList: $($Global:wfDependancyList)"
		$Global:wfDependancyList = New-Object -TypeName System.Collections.ArrayList
		Write-Debug -Message "Import-VCSRunbooks: Runbook FullName: $($wf.FullName)"
		$RunbookDep.FullName = $wf.FullName
		Write-Debug -Message "Import-VCSRunbooks: Runbook BaseName: $($wf.BaseName)"
		$RunbookDep.RunbookName = $wf.BaseName
		# Build dependency tree for updated workflow
		Write-Verbose -Message "Retrieving all dependencies for: $($wf.BaseName)"
		Write-Debug -Message "Import-VCSRunbooks: calling Get-RunbookDependencies with $($wf.Fullname)"
		Get-RunbookDependencies -Path $wf.FullName -ErrorAction Continue -ErrorVariable oErr
        If($oErr) {
		    # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
            # Using Continue and ErrorVariable the Error is written in history tab
		    Write-Error -Message "Error in Import-VCSRunbooks: $oErr"
		    $oErr = $Null
		    #Return
	    } 
		Write-Debug -Message "Import-VCSRunbooks: Adding retrieved dependencies to Global:wfDependancyList"
		$RunbookDep.RunbookDependencies = $Global:wfDependancyList
		Write-Debug -Message "Import-VCSRunbooks: Adding retrieved dependencies to $Global:wfDependancyList"
		Write-Debug -Message "Import-VCSRunbooks: Dependencies Object: $($RunbookDep)"
        Write-Debug -Message "Import-VCSRunbooks: Dependencies content: $($RunbookDep.RunbookDependencies)"
        $AllwfDependancyList += $RunbookDep
        $RunbookDep = $Null
    }
	
	ForEach($wf in $AllwfDependancyList) {
        $DoneProcessList = $null
        $DoneProcessList = New-Object -TypeName System.Collections.ArrayList
        Write-Verbose -Message "Publishing Runbook --> $($wf.RunbookName)"
        Write-Debug -Message "Import-VCSRunbooks: Processing $($wf.RunbookName)"
        # Publish original updated workflow if not already published
		If($DoneProcessList -notcontains $wf.FullName) {
            Write-Debug -Message "Import-VCSRunbooks: Publishing Runbook: $($wf.RunbookName)"
		    Publish-Runbook -Path $wf.FullName -WebServiceEndpoint $WebServiceEndpoint -Tag $Tag -Port $Port -ErrorAction Continue -ErrorVariable oErr
            If($oErr) {
		        # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
                # Using Continue and ErrorVariable the Error is written in history tab
		        Write-Error -Message "Error in Import-VCSRunbooks: $oErr"
		        $oErr = $Null
		        #Return
	        }
            $DoneProcessList += $wf.RunbookName
        }
        Else {
                Write-Verbose -Message "SKIPPING: $($wf.FullName) because it has been published already"
        }
        # Updating dependencies of Runbook
        ForEach($wfDep in $wf.RunbookDependencies) {
            $DepName = (($wfDep.Split('\')).Split('.')[-2])
            If($DoneProcessList -notcontains $DepName) {   
                Write-Verbose -Message "Publishing dependency: $($DepName) for $($wf.RunbookName)"
                $DoneProcessList += $DepName
                
                Write-Debug -Message "Import-VCSRunbooks: Processing dependency: $($DepName)"
			    # Publish dependencies before updated workbook
			    # Add better tag handling
			    Write-Debug -Message "Import-VCSRunbooks: Publishing dependency: $($wfDep)"
                # Dont change tag for dependency runbooks
			    Publish-Runbook -Path $wfDep -WebServiceEndpoint $WebServiceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
                If($oErr) {
		            # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
                    # Using Continue and ErrorVariable the Error is written in history tab
		            Write-Error -Message "Error in Import-VCSRunbooks: $oErr"
		            $oErr = $Null
		            #Return
	            }
                $DepName = $Null
            }
            Else {
                Write-Verbose -Message "SKIPPING: $($DepName) because it has been published already"
            }
		}
	}
	# Clean it up
	$Global:DoneProcessList = $null
	$Global:wfDependancyList = $null
    $Global:wfReferenceList = $null
    $AllwfDependancyList = $null
    $ToProcessList = $null
	
}
Function Get-RunbookDependencies
{
<#
        .SYNOPSIS
            Gets the dependencies of input Runbook from all source controled Runbooks 
#>
    [CmdletBinding()]
    Param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )
    Write-Debug -Message "Get-RunbookDependencies Path: $Path"
    Write-Debug -Message "Type: $($Path.GEtType())"
    # Workflow name
	$wfName = (($Path.Split('\')).Split('.')[-2])
	# Add origin runbook to processed list
    $Global:DoneProcessList += $wfName
	
	# Process potential references in workflow 
	ForEach ($wf in $Global:wfReferenceList)
    {
		Write-Debug -Message "Get-RunbookDependencies: Processing $wf"
		ForEach ($Ref in $wf.ReferencedRunbooks) {
			Write-Debug -Message "Get-RunbookDependencies: Processing $Ref"
			If($Ref -eq $wfName) {
			    
                Write-Debug -Message "Get-RunbookDependencies: Matched with $Ref"
				If($Global:DoneProcessList -notcontains $wf.RunbookName) {
					Write-Debug -Message "Get-RunbookDependencies: $wf.RunbookName not in global DoneProcessList"
					$Global:DoneProcessList += $wf.RunbookName
					# Add dependency to list
					Write-Verbose -Message "DEPENDENCY FOUND: $($Ref) --> $($wf.RunbookName)"
					# Call recurs to find next dependencies
					$Global:wfDependancyList += $wf.FullName
                    Get-RunbookDependencies -Path $wf.FullName -ErrorAction Continue -ErrorVariable oErr
                    If($oErr) {
					    # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
                        # Using Continue and ErrorVariable the Error is written in history tab
					    Write-Error -Message "Error in Get-RunbookDependencies: $oErr"
					    $oErr = $Null
					    #Return
				    } 
                    
				}
			}
		}
    }
    # Legacy code
	#Write-Debug -Message "Get-RunbookDependencies: Reversing order of Global:wfDependancyList"
    #[array]::Reverse($Global:wfDependancyList)
}
Function Get-RunbookReferences
{
<#
        .SYNOPSIS
            Gets the References from all source controlled Runbooks
#>
    [CmdletBinding()]
    Param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $BasePath
    )
    Write-Debug -Message "Get-RunbookReferences Path: $Path"
    Write-Debug -Message "Type: $($Path.GetType())"
    Write-Debug -Message "Get-RunbookReferences BasePath: $BasePath"
    Write-Debug -Message "Type: $($BasePath.GetType())"
    # Workflow name
	$wfName = (($Path.Split('\')).Split('.')[-2])
    Write-Debug -Message "Get-RunbookReferences Workflow Name: $wfName"
	$ThisWf = Get-Content -Path $Path -Raw -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
		# If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
        # Using Continue and ErrorVariable the Error is written in history tab
		Write-Error -Message "Error in Get-RunbookReferences: $oErr"
		$oErr = $Null
		#Return
	}
    
    $ThisWfSB = [scriptblock]::Create($ThisWf)
    $TokenizedWF = [System.Management.Automation.PSParser]::Tokenize($ThisWfSB,[ref]$null)
    $referencedCommands = $TokenizedWF | where {$_.Type -eq "Command"} | Select-Object -ExpandProperty "Content"
    
	$RbRefs = New-Object -TypeName PSObject -Property (@{
        'RunbookName' = "";
		'FullName' = "";
        'ReferencedRunbooks' = @();
    })
    $RbRefs.RunbookName = $wfName
	$RbRefs.Fullname  = $Path
	
    # Retrieve name of all workflows in source control
	$AllWFs = Get-ChildItem -Path $BasePath -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
		# If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
        # Using Continue and ErrorVariable the Error is written in history tab
		Write-Error -Message "Error in Get-RunbookReferences: $oErr"
		$oErr = $Null
		#Return
	}  
    
	Write-Debug -Message "Get-RunbookReferences: Files in basepath: $($AllWFs)"
    # Process potential references in workflow 
	ForEach ($referencedCommand in $referencedCommands)
    {
        Write-Debug -Message "Get-RunbookReferences: Checking BasePath for workflow match on command: $($referencedCommand)"
 
        $RunbookMatch = ( $AllWFs | Where-Object {$_.BaseName -eq $referencedCommand})
        
        if ($RunbookMatch)
        {
            Write-Verbose -Message "REFERENCE FOUND: $($wfName) --> $($referencedCommand)"
			Write-Debug -Message "Get-RunbookReferences: Processing workflow: $($wfName)"
			Write-Debug -Message "Get-RunbookReferences: File Name: $($RunbookMatch.FullName)"
			Write-Debug -Message "Get-RunbookReferences: Match for processed command: $($referencedCommand) found in: $($RunbookMatch.FullName)"
		
			Write-Debug -Message "Get-RunbookReferences: Adding to workflow referance list: $($referencedCommand)"
			# More than one referance in Runbook
			$RbRefs.ReferencedRunbooks += $referencedCommand
        }
        Else {
            Write-Debug -Message "Get-RunbookReferences: No match found in source control path for command: $($referencedCommand)"
        }
    }

    Write-Debug -Message "Get-RunbookReferences: Adding workflow reference for $($wfName) object to global wfReferenceList"
    Write-Debug -Message "Get-RunbookReferences: Reference Object: $($RbRefs)"
    Write-Debug -Message "Get-RunbookReferences: Reference content: $($RbRefs.ReferencedRunbooks)"
    $Global:wfReferenceList += $RbRefs
    
    # Clean up
    $RbRefs = $null
    $ThisWf = $Null
    $ThisWfSB = $Null
    $TokenizedWF = $Null
    $referencedCommands = $Null
	$wfName = $Null
	$AllWFs = $Null
}
Function Publish-Runbook
{
<#
        .SYNOPSIS
			Publishes or updates Runbook in SMA
#>
    [CmdletBinding()]
    Param (
        [Parameter()]
		[ValidateNotNullOrEmpty()]
        [string]
		$Path,
		[Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
		$WebServiceEndpoint,
		[Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
		$Port,
		[Parameter()]
        [string]
		$Tag
    )
    Write-Debug -Message "Publish-Runbook Path: $Path"
    Write-Debug -Message "Type: $($Path.GEtType())"
    # Name of Runbook
    $wfName = (($Path.Split('\')).Split('.')[-2])

    $SmaRb = Get-SmaRunbook -WebServiceEndpoint $WebServiceEndpoint -Port $Port -Name $wfName -ErrorAction SilentlyContinue
    if (!($SmaRb))
    {
        Write-Debug -Message "Importing Runbook: $($wfName)"
        $SmaRb = Import-SmaRunbook -Path $Path -WebServiceEndpoint $WebServiceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
        If($oErr) {
		    # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
            # Using Continue and ErrorVariable the Error is written in history tab
		    Write-Error -Message "Error in Publish-Runbook: $oErr"
		    $oErr = $Null
		    #Return
	    }  

        Write-Debug -Message "Writing tag for runbook ID: $($SmaRb.RunbookID )"
        If($Tag) {
			Write-Debug -Message "Setting tag"
			Set-SmaRunbookTags -RunbookID $SmaRb.RunbookID -Tags $Tag -WebserviceEndpoint $WebServiceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
            If($oErr) {
		        # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
                # Using Continue and ErrorVariable the Error is written in history tab
		        Write-Error -Message "Error in Publish-Runbook: $oErr"
		        $oErr = $Null
		        #Return
	        }  
        }
        Else {
			Write-Debug -Message "No tag set"
        }
    }
    Else
    {
        Write-Debug -Message "Editing Runbook: $($wfName)"
        Edit-SmaRunbook -Path $Path -WebServiceEndpoint $WebServiceEndpoint -Port $Port -Name $wfName -Overwrite -ErrorAction Continue -ErrorVariable oErr
        If($oErr) {
		    # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
            # Using Continue and ErrorVariable the Error is written in history tab
		    Write-Error -Message "Error in Publish-Runbook: $oErr"
		    $oErr = $Null
		    #Return
	    }  

        Write-Debug -Message "Writing tag for runbook ID: $($SmaRb.RunbookID)"
        If($Tag) {
			Write-Debug -Message "Updating tags"
			If($SmaRb.Tags) {
				If($Tag.EndsWith(';')) {
					$Tag = $Tag + $SmaRb.Tags
				}
				Else {
					$Tag = $Tag + ";" + $SmaRb.Tags
				}
			}
			Set-SmaRunbookTags -RunbookID $SmaRb.RunbookID -Tags $Tag -WebserviceEndpoint $WebServiceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
            If($oErr) {
		        # If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
                # Using Continue and ErrorVariable the Error is written in history tab
		        Write-Error -Message "Error in Publish-Runbook: $oErr"
		        $oErr = $Null
		        #Return
	        }  

        }
        Else {
			Write-Debug -Message "No tag updated"
        } 
    }
    Write-Debug -Message "Publishing Runbook ID: $($SmaRb.RunbookID)"
    $publishedId = Publish-SmaRunbook -Id $SmaRb.RunbookID -WebServiceEndpoint $WebServiceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
		# If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
        # Using Continue and ErrorVariable the Error is written in history tab
		Write-Error -Message "Error in Publish-Runbook: $oErr"
		$oErr = $Null
		#Return
	}  
}
Function Set-SmaRunbookTags
{
<#
    .SYNOPSIS
		Updates Tag of Runbook in SMA
#>
[CmdletBinding()]
Param
(
        [Parameter()]
		[ValidateNotNullOrEmpty()]
        [string]$RunbookID,
        [Parameter()]
		[ValidateNotNullOrEmpty()]		
        [string]$Tags,
        [Parameter()]
		[ValidateNotNullOrEmpty()]		
        [string]$WebserviceEndpoint,
        [Parameter()]
		[ValidateNotNullOrEmpty()]        
		[string]
		$Port
)
	Write-Verbose -Message "Publishing runbook tags: $($Tags)"
	Write-Debug -Message "Starting Set-SmaRunbookTags for [$RunbookID] Tags [$Tags]" 
	$RunbookURI = "${WebserviceEndpoint}:${Port}/00000000-0000-0000-0000-000000000000/Runbooks(guid'${RunbookID}')"
	Write-Debug -Message  "Runbook URI: $($RunbookURI)"
	$runbook = Get-SmaRunbook -Id $RunbookID -WebServiceEndpoint $WebserviceEndpoint -Port $Port -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
		# If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
        # Using Continue and ErrorVariable the Error is written in history tab
		Write-Error -Message "Error in Publish-Runbook: $oErr"
		$oErr = $Null
		#Return
	}  
 
	[xml]$baseXML = @'
<?xml version="1.0" encoding="utf-8"?>
<entry xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">
    <id></id>
    <category term="Orchestrator.ResourceModel.Runbook" scheme="http://schemas.microsoft.com/ado/2007/08/dataservices/scheme" />
    <title />
    <updated></updated>
    <author>
        <name />
    </author>
    <content type="application/xml">
        <m:properties>
            <d:Tags></d:Tags>
        </m:properties>
    </content>
</entry>
'@
	$baseXML.Entry.id = $RunbookURI
	$baseXML.Entry.Content.Properties.Tags = [string]$Tags

	$output = Invoke-RestMethod -Method Merge -Uri $RunbookURI -Body $baseXML -UseDefaultCredentials -ContentType 'application/atom+xml' -Verbose:$False -ErrorAction Continue -ErrorVariable oErr
    If($oErr) {
		# If errorAction Stop is used in calling workflow inside of SMA execution will suspend directly without writing error in history tab
        # Using Continue and ErrorVariable the Error is written in history tab
		Write-Error -Message "Error in Publish-Runbook: $oErr"
		$oErr = $Null
		#Return
	}  

	Write-Debug -Message "Finished Set-SmaRunbookTags for $RunbookID"
}
